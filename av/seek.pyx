from libc.stdint cimport uint8_t, uint16_t, uint32_t, uint64_t, int64_t
cimport libav as lib

cimport av.format

from .utils cimport err_check


FIRST_FRAME_INDEX = 0

class SeekError(ValueError):
    pass

class SeekEnd(SeekError):
    pass
    
cdef class SeekContext(object):
    def __init__(self,av.format.Context ctx, 
                      av.format.Stream stream):
        
        self.ctx = ctx
        self.stream = stream
        self.codec = stream.codec
        
        self.frame = None
        self.nb_frames = 0
        
        self.frame_available =True
        
        self.pts_seen = False
        self.seeking = False
        
        self.current_frame_index = FIRST_FRAME_INDEX -1
        self.current_dts = lib.AV_NOPTS_VALUE
        self.previous_dts = lib.AV_NOPTS_VALUE

    def __repr__(self):
        return '<%s.%s curr_frame: %i curr_dts: %i prev_dts: %i key_dts: %i first_dts: %i at 0x%x>' % (
            self.__class__.__module__,
            self.__class__.__name__,
            self.current_frame_index,
            self.current_dts,
            self.previous_dts,
            self.keyframe_packet_dts,
            self.first_dts,
            id(self),
        )
        
    cdef flush_buffers(self):
        lib.avcodec_flush_buffers(self.codec.ctx)
        
    cdef seek(self, int64_t timestamp, int flags):
        self.flush_buffers()
        err_check(lib.av_seek_frame(self.ctx.proxy.ptr, self.stream.ptr.index, timestamp,flags))
        
    def reset(self):
        self.seek(0,0)
        self.frame =None
        self.current_frame_index = FIRST_FRAME_INDEX -1
        
    cpdef forward(self):
        cdef av.codec.Packet packet
                
        cdef av.codec.VideoFrame video_frame
        
        if not self.frame_available:
            raise SeekEnd("No more frames")
        
        self.current_frame_index += 1
        
        #check last frame sync
        if self.frame and not self.seeking:
            pts = self.frame.pts

            if pts != lib.AV_NOPTS_VALUE:
                pts_frame_num = self.pts_to_frame(pts)
                
                if self.current_frame_index -1 < pts_frame_num:
                    #print  "dup frame",self.current_frame_index, "!=",self.pts_to_frame(pts)
                    video_frame = self.frame
                    video_frame.frame_index = self.current_frame_index
                    return video_frame

        while True:

            packet = next(self.ctx.demux([self.stream]))
            
            if packet.struct.pts != lib.AV_NOPTS_VALUE:
                self.pts_seen = True
            
            frame = self.stream.decode(packet)
            if frame:
                
                #check sync to see if we need to drop the frame
                if not self.seeking:
                    pts = frame.pts
                    
                    if pts != lib.AV_NOPTS_VALUE:
                        
                        pts_frame_num = self.pts_to_frame(pts)
                        #print self.current_frame_index,pts_frame_num
                        #allow one frame error mkv off by pts ?!!! 
                        if self.current_frame_index > pts_frame_num + 1:
                            print "need drop frame out of sync", self.current_frame_index, ">",self.pts_to_frame(pts)
                            continue
                            #raise Exception()

                video_frame = frame
                video_frame.frame_index = self.current_frame_index
                    
                self.frame = video_frame
                return video_frame
            else:
                if packet.is_null:
                    self.frame_available = False
                    raise SeekEnd("No more frames")
            
    
    def __getitem__(self,x):

        return self.to_frame(x)
    
    def __len__(self):
        if not self.nb_frames:
            
            if self.stream.frames:
                self.nb_frames = self.stream.frames
            else:
                self.nb_frames = self.get_length_seek()
            
        return self.nb_frames
    
    
    def get_length_seek(self):
        """Get the last frame by seeking to the end of the stream
        """
        
        cur_frame = self.current_frame_index
        if cur_frame <0:
            cur_frame = 0
        
        #seek ot a very large frame
        self.to_nearest_keyframe(2<<29)

        #keep stepping forward until we hit the end
        
        while True:
            try:
                self.forward()
            except SeekEnd as e:
                break
            
        length =  self.current_frame_index
        
        #seek back to where we originally where

        self.to_frame(cur_frame)

        return length


    def to_frame(self, int target_frame):
        
        # seek to the nearet keyframe
        
        self.to_nearest_keyframe(target_frame)
        
        if target_frame == self.current_frame_index:
            return self.frame

        # something went wrong 
        if self.current_frame_index > target_frame:
            self.to_nearest_keyframe(target_frame-1)
            #raise IndexError("error advancing to key frame before seek (index isn't right)")
        
        frame = self.frame
        
        # step forward from current frame until we get to the frame
        while self.current_frame_index < target_frame:
            frame = self.forward()

        return self.frame
    

    def to_nearest_keyframe(self,int target_frame):
        
        #optimizations
        if not self.seeking:
            if target_frame == self.current_frame_index:
                return self.frame
            
            if target_frame == self.current_frame_index + 1:
                return self.forward()
        
        cdef int flags = 0
        cdef int64_t target_pts = lib.AV_NOPTS_VALUE
        cdef int64_t current_pts = lib.AV_NOPTS_VALUE
        
        self.seeking = True
        self.frame_available = True
        self.current_frame_index = -2
        
        target_pts  = self.frame_to_pts(target_frame)
        
        flags = lib.AVSEEK_FLAG_BACKWARD 
        
        self.seek(target_pts,flags)
        
        retry = 10
        while current_pts == lib.AV_NOPTS_VALUE:
            frame  = self.forward()
            
            if frame.key_frame:
                current_pts = frame.pts
                
            retry -= 1
            if retry < 0:
                raise Exception("Connnot find keyframe %i %i" % (target_pts, target_frame) )

            
        if current_pts > target_pts:
            print "went to far seeking backwards", current_pts,target_pts, target_frame
            if target_pts < self.stream.start_time:
                raise Exception("cannot seek before first frame")
            
            return self.to_nearest_keyframe(target_frame-1)
            
        self.current_frame_index = self.pts_to_frame(current_pts)
        
        cdef av.codec.VideoFrame video_frame
        
        video_frame = self.frame
        video_frame.frame_index = self.current_frame_index

        self.seeking = False
        return video_frame
    

    cpdef frame_to_pts(self, int frame):
        fps = self.stream.base_frame_rate
        time_base = self.stream.time_base
        cdef int64_t pts
        
        pts = self.stream.start_time + ((frame * fps.denominator * time_base.denominator) \
                                 / (fps.numerator *time_base.numerator))
        return pts
    
    cpdef pts_to_frame(self, int64_t timestamp):
        
        if timestamp == lib.AV_NOPTS_VALUE:
            raise Exception("time stamp AV_NOPTS_VALUE")
        
        fps = self.stream.base_frame_rate
        time_base = self.stream.time_base
        
        cdef int64_t frame
        
        frame = ((timestamp - self.stream.start_time) * time_base.numerator * fps.numerator) \
                                      / (time_base.denominator * fps.denominator)
                                      
        return frame