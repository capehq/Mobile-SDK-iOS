//
//  VideoPreviewer.m
//
//  Copyright (c) 2013 DJI. All rights reserved.
//
//#import "DJILogCenter.h"
//#import "DJIVideoStuckTester.h"
#import "VideoPreviewerQueue.h"
#import "VideoPreviewer.h"
//#import "DJIDispatch.h"
#import <sys/time.h>
#include <OpenGLES/ES2/gl.h>
#import "LB2AUDHackParser.h"
#import "VideoPreviewerMacros.h"
#include <libavutil/log.h>

//#import "DJIDataDumper.h"
//#import "DJIH264FrameRawLayerDumper.h"

#define __TEST_VIDEO_DELAY__  (0)
#define __PERFROMANCE_COUNT__ (0) //显示性能计数
#define __TEST_QUEUE_PULL__   (0) //从264码流文件拉取调试
#define __TEST_FRAME_PULL__   (0) //从帧文件拉取调试
#define __TEST_PACK_PULL__    (0) //从分包文件拉取调试

#define __TEST_PACK_DUMP__    (0) //保存分包文件
#define __TEST_FRAME_DUMP__   (0) //保存分帧文件
#define __LB2_PARSER_DUMP__   (0) //保存lb2hack输出

#define FRAME_DROP_THRESHOLD  (70)
#define RENDER_DROP_THRESHOLD (5)

#if __TEST_VIDEO_DELAY__
#import "DJITestDelayLogic.h"
#endif

@interface VideoPreviewer () <
H264DecoderOutput,
MovieGLViewDelegate,
LB2AUDHackParserDelegate>{
    
    NSThread *_decodeThread;    //decode thread
    MovieGLView *_glView;   //OpenGL render
    
    BOOL videoDecoderCanReset;
    int videoDecoderFailedCount;
    int glViewRenderFrameCount; //GLView render input frame count
    int safe_resume_skip_count; //hardware decode under the safe_resume should skip frame count
    
    DJIVideoStreamBasicInfo _stream_basic_info;
    pthread_mutex_t _processor_mutex;
    pthread_mutex_t _render_mutex; //mutex for rendering protection against conducted openGL calls in the background
    
    long long _lastDataInputTime; //Last received time data
    long long _lastFrameDecodedTime; //Last time available to decode
    
    dispatch_queue_t _dispatchQueue;
#if __TEST_FRAME_DUMP__ || __LB2_PARSER_DUMP__
    /**
     *  dumper for frame
     */
    DJIH264FrameRawLayerDumper* frameLayerDumper;
    DJIDataDumper* lb2Dumper;
#endif
    
#if __TEST_PACK_DUMP__
    DJIDataDumper* packLayerDumper;
#endif
}

/**
 *  YES if this is the first instance
 */
@property (nonatomic, assign) BOOL isDefaultPreviewer;

/**
 *  frame buffer queue
 */
@property(nonatomic, strong) VideoPreviewerQueue *dataQueue;
//gl view
@property (nonatomic, strong) MovieGLView* internalGLView;
//basic status
@property (assign, nonatomic) VideoPreviewerStatus status;
//ffmpeg warpper
@property (strong, nonatomic) VideoFrameExtractor *videoExtractor;
//hardware decode use videotool box on ios8
@property (strong, nonatomic) H264VTDecode *hw_decoder;
//software decoder use ffmpeg
@property (strong, nonatomic) SoftwareDecodeProcessor* soft_decoder;
//decoder current state
@property (assign, nonatomic) VideoDecoderStatus decoderStatus;
//frame output type
@property (assign, nonatomic) VPFrameType frameOutputType;
//stream processor list
@property (assign, nonatomic) DJIVideoStreamBasicInfo currentStreamInfo;
@property (strong, nonatomic) NSMutableArray* stream_processor_list;
@property (strong, nonatomic) NSMutableArray* frame_processor_list;
@property (assign, nonatomic) BOOL grayOutPause;
@property (assign, nonatomic) CGRect frame;

//remove the redundant aud in LB2's stream
@property (strong, nonatomic) LB2AUDHackParser* lb2Hack;
@end

@implementation VideoPreviewer

-(id)init
{
    self= [super init];
    
    _dispatchQueue = dispatch_queue_create("video_previewer_async_queue", DISPATCH_QUEUE_SERIAL);

    _decodeThread          = nil;
    _glView                = nil;
    _type                  = VideoPreviewerTypeAutoAdapt;
    _decoderStatus         = VideoDecoderStatus_Normal;
    _dataQueue             = [[VideoPreviewerQueue alloc] initWithSize:100];
    _stream_processor_list = [[NSMutableArray alloc] init];
    _frame_processor_list  = [[NSMutableArray alloc] init];
    _luminanceScale        = 1.0;
    _enableFastUpload      = YES; //default use fast upload
    safe_resume_skip_count = 0;
    
    _videoExtractor = [[VideoFrameExtractor alloc] initExtractor];
    [_videoExtractor setShouldVerifyVideoStream:YES];
    pthread_mutex_init(&_processor_mutex, nil);
    pthread_mutex_init(&_render_mutex, nil);
    
    memset(&_status, 0, sizeof(VideoPreviewerStatus));
    _status.isInit    = YES;
    _status.isRunning = NO;
    
    memset(&_stream_basic_info, 0, sizeof(_stream_basic_info));
    //default is inspire frame rate
    _stream_basic_info.frameRate   = 30;
    _stream_basic_info.encoderType = H264EncoderType_DM368_inspire;
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appWillEnterForeGround:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];

    
    //soft decoder
    _soft_decoder = [[SoftwareDecodeProcessor alloc] initWithExtractor:_videoExtractor];
    _soft_decoder.frameProcessor = self;
    
    
    //Simulator hardware decoding will be stuck in callback
#if !TARGET_IPHONE_SIMULATOR
    
    if ((NSFoundationVersionNumber > NSFoundationVersionNumber_iOS_7_1)) {
        //use hardware decode on ios8
        _hw_decoder = [[H264VTDecode alloc] init];
        _hw_decoder.delegate = self;
    }
#endif
    
    [self registStreamProcessor:_soft_decoder];
    [self registStreamProcessor:_hw_decoder];
    
    //default is inspire
    self.encoderType = H264EncoderType_DM368_inspire;
    
    //lb2 hack
    self.lb2Hack = [[LB2AUDHackParser alloc] init];
    self.lb2Hack.delegate = self;

    av_log_set_level(AV_LOG_FATAL);

    return self;
}

-(void) dealloc
{
    if (_videoExtractor) {
        _videoExtractor.delegate = nil;
    }
    
    [_videoExtractor freeExtractor];
    [_glView releaseResourece];
    [self privateClose];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

-(void) appDidEnterBackground:(NSNotification*)notify
{
    [self enterBackground];
}

-(void) appWillEnterForeGround:(NSNotification *)notify
{
    [self enterForegournd];
}

#pragma mark - public

+(VideoPreviewer*) instance
{
    static VideoPreviewer* previewer = nil;
    if(previewer == nil)
    {
        @synchronized (self) {
            if (previewer == nil) {
                previewer = [[VideoPreviewer alloc] init];
                previewer.isDefaultPreviewer = YES;
            }
        }
    }
    return previewer;
}

-(void) push:(uint8_t*)videoData length:(int)len
{
#if __TEST_VIDEO_DELAY__
    if ([DJITestDelayLogic sharedInstance].hasSynced && ![DJITestDelayLogic sharedInstance].isSyncing) {
        [[DJITestDelayLogic sharedInstance] startSyncTime];
        return;
    }
    if ([DJITestDelayLogic sharedInstance].hasSynced) {
        NSTimeInterval currentTimeInterval = [[NSDate date] timeIntervalSinceReferenceDate];
        [[DJITestDelayLogic sharedInstance] logPackSize:len time:currentTimeInterval];
        return;
    }
#endif
    
#if __TEST_PACK_DUMP__
    if (!packLayerDumper) {
        packLayerDumper = [[DJIDataDumper alloc] init];
        packLayerDumper.namePerfix = @"videoPack";
        packLayerDumper.packAlignMode = YES;
    }
    
    if (packLayerDumper) {
        [packLayerDumper dumpData:videoData length:len];
    }
#endif
    
    _lastDataInputTime = [self getTickCount];
    if (_status.isRunning) {
        if (_encoderType == H264EncoderType_LightBridge2) {
            ////Remove the extra aud in lb2
            [_lb2Hack parse:videoData inSize:len];
        }else{
            [_videoExtractor parseVideo:videoData length:len withFrame:^(VideoFrameH264Raw *frame) {
                if (!frame) {
                    return;
                }
                
                if (self.dataQueue.count > FRAME_DROP_THRESHOLD) {
//                    DJILOG(@"decode dataqueue drop %d", FRAME_DROP_THRESHOLD);
                    [self.dataQueue clear];
                }
#if __TEST_VIDEO_STUCK__
                [DJIVideoStuckTester parseFrameWithIndex:frame->frame_info.frame_index];
#endif
                [self.dataQueue push:(uint8_t*)frame length:sizeof(VideoFrameH264Raw) + frame->frame_size];
            }];
        }
    }
    else
    {
        [self.dataQueue clear];
    }
}

-(void) clearVideoData
{
    [self.dataQueue clear];
    [_glView clear];
}

-(void) snapshotPreview:(void(^)(UIImage* snapshot))block{
    if (!_glView || _status.isPause || safe_resume_skip_count) {
        if (block) {
            block(nil);
        };
        return;
    }
    
    _glView.snapshotCallback = block;
}

-(void) snapshotThumnnail:(void(^)(UIImage* snapshot))block{
    if (!_glView || _status.isPause || safe_resume_skip_count) {
        if (block) {
            block(nil);
        };
        return;
    }
    
    _glView.snapshotThumbnailCallback = block;
}


-(BOOL)setView:(UIView *)view
{
    BEGIN_MAIN_DISPATCH_QUEUE
    if(_glView == nil){
        //generate
        _glView = [[MovieGLView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, view.frame.size.width, view.frame.size.height)];
        _glView.delegate = self;
        _glView.rotation = self.rotation;
        _glView.contentClipRect = self.contentClipRect;
    }
    
    if(_glView.superview != view){
        [view addSubview:_glView];
    }
    [view sendSubviewToBack:_glView];
    [_glView adjustSize];
    _status.isGLViewInit = YES;
    //set self frame property
    [self movieGlView:_glView didChangedFrame:_glView.frame];
    self.internalGLView = _glView;
    END_DISPATCH_QUEUE
    return NO;
}

-(void)unSetView
{
    BEGIN_MAIN_DISPATCH_QUEUE
    if(_glView != nil && _glView.superview !=nil)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [_glView removeFromSuperview];
            //_glView = nil; // Deliberately not release dglView, Avoid each entry view flickering。
            _status.isGLViewInit = NO;
            self.internalGLView = nil;
        });
    }
    END_DISPATCH_QUEUE
}

-(void)adjustViewSize{
    BEGIN_MAIN_DISPATCH_QUEUE
    pthread_mutex_lock(&_render_mutex);
    if (_glView && [self glviewCanRender]) {
        [_glView adjustSize];
    }
    pthread_mutex_unlock(&_render_mutex);
    END_DISPATCH_QUEUE
}

-(CGPoint) convertPoint:(CGPoint)point toVideoViewFromView:(UIView*)view{
    if (!_glView) {
        return CGPointZero;
    }
    
    return [_glView convertPoint:point fromView:view];
}

-(CGPoint) convertPoint:(CGPoint)point fromVideoViewToView:(UIView *)view{
    if (!_glView) {
        return CGPointZero;
    }
    
    return [_glView convertPoint:point toView:view];
}

- (BOOL)start
{
    BEGIN_MAIN_DISPATCH_QUEUE
    if(_decodeThread == nil && !_status.isRunning)
    {
        _decodeThread = [[NSThread alloc] initWithTarget:self selector:@selector(decodeRunloop) object:nil];
        _decodeThread.qualityOfService = NSQualityOfServiceUserInteractive;
        [_decodeThread start];
    }
    END_DISPATCH_QUEUE
    return YES;
}

-(void) reset
{
    BEGIN_MAIN_DISPATCH_QUEUE
    if(_decodeThread && _status.isRunning)
    {
        safe_resume_skip_count = 0;
        _status.isRunning = NO;
        while (!_status.isFinish) {
            usleep(10000);
        }
        [_decodeThread cancel];
        while (!_decodeThread.isFinished) {
            usleep(10000);
        }
        _decodeThread = nil;
        [_videoExtractor clearBuffer];
        [_dataQueue clear];
        _decodeThread = [[NSThread alloc] initWithTarget:self selector:@selector(decodeRunloop) object:nil];
        [_decodeThread start];
        
        if (_hw_decoder) {
            [_hw_decoder resetLater];
            
        }

        for (id<VideoStreamProcessor> processor in _stream_processor_list) {
            if ([processor respondsToSelector:@selector(streamProcessorReset)]) {
                [processor streamProcessorReset];
            }
        }
    }
    END_DISPATCH_QUEUE
}

- (void)resume{
    BEGIN_MAIN_DISPATCH_QUEUE
    _status.isPause = NO;
//    DJILOG(@"Resume the decoding");
    END_DISPATCH_QUEUE
}

- (void)safeResume{
//    DJILOG(@"begin Try safe resuming");
    safe_resume_skip_count = 25;
    [self resume];
}

- (void)pause{
    [self pauseWithGrayout:YES];
}

- (void)pauseWithGrayout:(BOOL)isGrayout{
    BEGIN_MAIN_DISPATCH_QUEUE
    _status.isPause = YES;
    _grayOutPause = isGrayout;
//    DJILOG(@"Pause decoding");
    //Wake up waiting threads will immediately render a black white image
    [self.dataQueue wakeupReader];
    
    for (id<VideoStreamProcessor> processor in _stream_processor_list) {
        if ([processor respondsToSelector:@selector(streamProcessorPause)]) {
            [processor streamProcessorPause];
        }
    }
    END_DISPATCH_QUEUE
}

- (void)close{
    BEGIN_MAIN_DISPATCH_QUEUE
    [self privateClose];
    END_DISPATCH_QUEUE
}

-(void) clearRender
{
    BEGIN_MAIN_DISPATCH_QUEUE
    [_glView clear];
    [self.dataQueue wakeupReader];
    END_DISPATCH_QUEUE
}

- (void)privateClose
{
    [_dataQueue clear];
    if(_decodeThread!=nil){
        [_decodeThread cancel];
        _decodeThread = nil;
    }
    _status.isRunning = NO;
}

- (void)setType:(VideoPreviewerType)type{
    if(_type == type)return;
    if(_glView == nil)return;
    BEGIN_MAIN_DISPATCH_QUEUE
    pthread_mutex_lock(&_render_mutex);
    _type = type;
    if(_type == VideoPreviewerTypeFullWindow){
        [_glView setType:VideoPresentContentModeAspectFill];
        
        if ([self glviewCanRender]) {
            [_glView render:nil];
        }
    }
    else if(_type == VideoPreviewerTypeAutoAdapt){
        [_glView setType:VideoPresentContentModeAspectFit];
        
        if ([self glviewCanRender]) {
            [_glView render:nil];
        }
    }
    pthread_mutex_unlock(&_render_mutex);
    END_DISPATCH_QUEUE
}

-(void) setRotation:(VideoStreamRotationType)rotation{
    if (_rotation == rotation) {
        return;
    }
    
    _rotation = rotation;
    [_glView setRotation:rotation];
}

-(void) setContentClipRect:(CGRect)rect{
    if (CGRectEqualToRect(rect, _contentClipRect)) {
        return;
    }
    
    _contentClipRect = rect;
    [_glView setContentClipRect:rect];
}

-(BOOL) glviewCanRender{
    return !_status.isBackground && _status.isGLViewInit;
}

-(void) setOverExposedWarningThreshold:(float)overExposedWarningThreshold
{
    _overExposedWarningThreshold = overExposedWarningThreshold;
    _glView.overExposedMark = overExposedWarningThreshold;
}

-(void) setEnableFocusWarning:(BOOL)enableFocusWarning
{
    _enableFocusWarning = enableFocusWarning;
    _glView.enableFocusWarning  = enableFocusWarning;
}

- (void) setFocusWarningThreshold:(float)focusWarningThreshold{
    
    _focusWarningThreshold = focusWarningThreshold;
    _glView.focusWarningThreshold = focusWarningThreshold;
}

-(void) setLuminanceScale:(float)luminanceScale{
    _luminanceScale = luminanceScale;
    _glView.luminanceScale = luminanceScale;
}

-(void) setEnableHSB:(BOOL)enableHSB{
    _enableHSB = enableHSB;
    _glView.enableHSB = enableHSB;
}

-(void) setHsbConfig:(DJILiveViewRenderHSBConfig)hsbConfig{
    _hsbConfig = hsbConfig;
    _glView.hsbConfig = hsbConfig;
}

-(void) setEncoderType:(H264EncoderType)encoderType{
    if (_encoderType == encoderType) {
        return;
    }
    
    _encoderType = encoderType;
    _stream_basic_info.encoderType = encoderType;
}

-(void) setEnableShadowAndHighLightenhancement:(BOOL)enable{
    if (_enableShadowAndHighLightenhancement == enable) {
        return;
    }
    
    _enableShadowAndHighLightenhancement = enable;
    _glView.enableShadowAndHighLightenhancement = enable;
}

-(void) setEnableHardwareDecode:(BOOL)enableHardwareDecode{
    if (_enableHardwareDecode == enableHardwareDecode) {
        return;
    }
    
    _enableHardwareDecode = enableHardwareDecode;
    [_hw_decoder resetLater];
}


-(void) registStreamProcessor:(id<VideoStreamProcessor>)processor{
    if (processor) {
        
        pthread_mutex_lock(&_processor_mutex);
        [_stream_processor_list addObject:processor];
        pthread_mutex_unlock(&_processor_mutex);
    }
}

-(void) unregistStreamProcessor:(id)processor{
    pthread_mutex_lock(&_processor_mutex);
    [_stream_processor_list removeObject:processor];
    pthread_mutex_unlock(&_processor_mutex);
}

-(void) registFrameProcessor:(id<VideoFrameProcessor>)processor{
    if (processor) {
        
        pthread_mutex_lock(&_processor_mutex);
        [_frame_processor_list addObject:processor];
        pthread_mutex_unlock(&_processor_mutex);
    }
}

-(void) unregistFrameProcessor:(id)processor{
    
    pthread_mutex_lock(&_processor_mutex);
    [_frame_processor_list removeObject:processor];
    pthread_mutex_unlock(&_processor_mutex);
}

#pragma mark - private
- (void)enterBackground{
    //It is not allowed to call OpenGL's interface in the background. Ensure all work is done before entering the background.
    pthread_mutex_lock(&_render_mutex);
//    DJILOG(@"videoPreviewer background");
    _status.isBackground = YES;
    pthread_mutex_unlock(&_render_mutex);
}

- (void)enterForegournd{
//    DJILOG(@"videoPreviewer active");
    _status.isBackground = NO;
}

// Update the decoder's status according to the timestamp when the previous data is received
- (void)updateDecoderStatus{
    if (_status.isPause) {//not update under the pause state
        return;
    }
    
    long long current = [self getTickCount];

    if (current - _lastDataInputTime > 2000*1000) {
        self.decoderStatus = VideoDecoderStatus_NoData;
        return;
    }
    
    if (current - _lastFrameDecodedTime > 2000*1000) {
        self.decoderStatus = VideoDecoderStatus_DecoderError;
        return;
    }
    
    self.decoderStatus = VideoDecoderStatus_Normal;
    return;
}

-(long long) getTickCount
{
    struct timeval t;
    gettimeofday(&t, NULL);
    long long microSec = t.tv_sec*1000*1000 + t.tv_usec;
    
    return microSec;
}

-(void) decodeRunloop
{
    _status.isRunning = YES;
    _status.isFinish = NO;
    safe_resume_skip_count = 0;
    
    videoDecoderCanReset = NO;
    videoDecoderFailedCount = 0;
    
    BOOL stream_info_changed = YES; //need notify at the first time
    DJIVideoStreamBasicInfo current_stream_info = {0};
    memcpy(&current_stream_info, &_stream_basic_info, sizeof(DJIVideoStreamBasicInfo));
    
    while(_status.isRunning)
    {
        @autoreleasepool {
            VideoFrameH264Raw* frameRaw = nil;
            int inputDataSize = 0;
            uint8_t *inputData = nil;
            
            int queueNodeSize;
#if __TEST_QUEUE_PULL__
            //Get the test data from the queue
            frameRaw = [self testQueuePull:&queueNodeSize];
#elif __TEST_FRAME_PULL__
            //Get test data frame
            frameRaw = [self testFramePull:&queueNodeSize];
#else
        
#if __TEST_PACK_PULL__
            [self testPackPull];
#endif
            //Normal access to data
            frameRaw = (VideoFrameH264Raw*)[_dataQueue pull:&queueNodeSize];
#endif
            
            if (frameRaw && frameRaw->frame_size + sizeof(VideoFrameH264Raw) == queueNodeSize) {
                inputData = frameRaw->frame_data;
                inputDataSize = frameRaw->frame_size;
            }
            [self updateDecoderStatus];
            
#if __TEST_FRAME_DUMP__
            if (!frameLayerDumper) {
                frameLayerDumper = [[DJIH264FrameRawLayerDumper alloc] init];
            }
            [frameLayerDumper dumpFrame:frameRaw];
#endif
            
            //sync config
            _glView.overExposedMark = _overExposedWarningThreshold;
            _glView.luminanceScale = _luminanceScale;
            _glView.enableFocusWarning = _enableFocusWarning;
            _glView.focusWarningThreshold = _focusWarningThreshold;
            _glView.dLogReverse = _dLogReverse;
            _glView.enableHSB = _enableHSB;
            _glView.hsbConfig = _hsbConfig;
            _glView.enableShadowAndHighLightenhancement = _enableShadowAndHighLightenhancement;
            _glView.shadowsLighten = _shadowsLighten;
            _glView.highlightsDecrease = _highlightsDecrease;
            
            if(inputData == NULL)
            {
                if (safe_resume_skip_count) {
                    //waiting for safe resume
                    _status.hasImage = NO; // no image, but it won't trigger the NoImage notification
                    continue;
                }
                
                videoDecoderCanReset = NO;
                pthread_mutex_lock(&_render_mutex);
                if([self glviewCanRender]){
                    // render as grey when it is paused
                    _glView.grayScale = _grayOutPause;
                    [_glView render:nil];
                    _glView.grayScale = NO;
                }
                pthread_mutex_unlock(&_render_mutex);
                
                if(_status.hasImage && !_status.isPause){
                    _status.hasImage = NO;
                    
                    if (self.isDefaultPreviewer) {
                        //only notify if this is default previewer
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [[NSNotificationCenter defaultCenter] postNotificationName:VIDEO_PREVIEWER_EVEN_NOTIFICATIOIN
                                                                                object:@(VideoPreviewerEventNoImage)];
                        });
                    }
                }
                continue;
            }
            
            if(!_status.hasImage){
                _status.hasImage = YES;
                if (self.isDefaultPreviewer) {
                    //only notify if this is default previewer
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[NSNotificationCenter defaultCenter] postNotificationName:VIDEO_PREVIEWER_EVEN_NOTIFICATIOIN
                                                                            object:@(VideoPreviewerEventHasImage)];
                    });
                }
            }
            
            _stream_basic_info.frameRate = _videoExtractor.frameRate;
            _stream_basic_info.frameSize = CGSizeMake(_videoExtractor.outputWidth, _videoExtractor.outputHeight);
            if (memcmp(&current_stream_info, &_stream_basic_info, sizeof(current_stream_info)) !=0 ) {
                current_stream_info = _stream_basic_info;
                stream_info_changed = YES;
            }
            
            //notifiy rkvo
            if (stream_info_changed) {
                __weak VideoPreviewer* target = self;
                dispatch_async(dispatch_get_main_queue(),
                               ^{
                                   target.currentStreamInfo = current_stream_info;
                               });
            }
            
            
            if (frameRaw->type_tag == TYPE_TAG_VideoFrameH264Raw) {
                
                //decoder select
                if(_hw_decoder && !_hw_decoder.hardwareUnavailable && _enableHardwareDecode){
                    //decode use video toolbox
                    _hw_decoder.enabled = YES;
                    _hw_decoder.encoderType = _encoderType;
                    _hw_decoder.enableFastUpload = self.enableFastUpload;
                    _soft_decoder.enabled = NO;
                    
                    if (self.enableFastUpload) {
                        //fast upload，the output format is difference
                        self.frameOutputType = VPFrameTypeYUV420SemiPlaner;
                    }
                    else{
                        self.frameOutputType = VPFrameTypeYUV420Planer;
                    }
                }
                else{
                    _hw_decoder.enabled = NO;
                    _soft_decoder.enabled = YES;
                    self.frameOutputType = VPFrameTypeYUV420Planer;
                }

                // Phantom 4 workaround: frames of Phantom 4 may set the IDR
                // flag mistakenly. To be save, unset the IDR flag for all frames.
                if (_encoderType == H264EncoderType_1860_phantom4x) {
                    frameRaw->frame_info.frame_flag.has_idr = 0;
                }
                
                //rotation info set
                //will effect video cache system
                frameRaw->frame_info.rotate = _rotation;
                frameRaw->frame_info.frame_flag.channelType = _videoChannelTag;
                
                pthread_mutex_lock(&_processor_mutex);
                NSArray* streamProcessorCopyList = [NSArray arrayWithArray:_stream_processor_list];
                pthread_mutex_unlock(&_processor_mutex);
                
                //processors
                for (id<VideoStreamProcessor> processor in streamProcessorCopyList) {
                    if (![processor conformsToProtocol:@protocol(VideoStreamProcessor)]) {
                        continue;
                    }
                    
                    if (stream_info_changed && [processor respondsToSelector:@selector(streamProcessorInfoChanged:)]) {
                        [processor streamProcessorInfoChanged:&current_stream_info];
                    }
                    
                    if (![processor streamProcessorEnabled]) {
                        continue;
                    }
                    
                    DJIVideoStreamProcessorType processor_type = [processor streamProcessorType];
                    
                    if (processor_type == DJIVideoStreamProcessorType_Decoder) {
                        //A decoder having a special treatment
                        if(!_status.isBackground){ //Background without decoding
#if __TEST_VIDEO_STUCK__
                            [DJIVideoStuckTester startDecodeFrameWithIndex:frameRaw->frame_uuid];
#endif
                            bool isSuccess = false;
                            if ([processor streamProcessorHandleFrameRaw:frameRaw]) {
                                //success decoding! reset failCount
                                videoDecoderFailedCount = 0;
                                
                                videoDecoderCanReset = YES;
                                isSuccess = true;
                            }else{
#if __TEST_VIDEO_STUCK__
                                [DJIVideoStuckTester finisedDecodeFrameWithIndex:frameRaw->frame_uuid withState:false];
#endif
                                [self videoProcessFailedFrame];
                            }
                        }
                    }
                    else if(processor_type == DJIVideoStreamProcessorType_Modify
                             || processor_type == DJIVideoStreamProcessorType_Passthrough){
                        //It does not affect the subsequent processor
                        [processor streamProcessorHandleFrameRaw:frameRaw];
                        //[processor streamProcessorHandleFrame:inputData size:inputDataSize];
                    }
                    else if (processor_type == DJIVideoStreamProcessorType_Consume){
                        if(processor != _stream_processor_list.lastObject) {
                            //consume not in need of a last copy data
                            VideoFrameH264Raw* data_copy = (VideoFrameH264Raw*)malloc(queueNodeSize);
                            memcpy(data_copy, frameRaw, queueNodeSize);
                            if (![processor streamProcessorHandleFrameRaw:data_copy]) {
                                free(data_copy);
                            }
                        }
                        else if([processor streamProcessorHandleFrameRaw:frameRaw]){
                            //Consumed data, no copy
                            frameRaw = NULL;
                        }
                    }
                }
            }
            
            //cleanups
            stream_info_changed = NO;
            
#if __PERFROMANCE_COUNT__
            //Performance Testing
            [self performanceCount:inputDataSize];
#endif
            
            if(safe_resume_skip_count){
                safe_resume_skip_count--;
//                DJILog(@"safe resume frame:%d", safe_resume_skip_count);
                if (safe_resume_skip_count == 0) { //Recovering from decoding pause
//                    DJILOG(@"safe resume complete");
                    
                    if (self.isDefaultPreviewer) {
                        //only notify if this is default previewer
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [[NSNotificationCenter defaultCenter] postNotificationName:VIDEO_PREVIEWER_EVEN_NOTIFICATIOIN object:@(VideoPreviewerEventResumeReady)];
                        });
                    }
                }
            }
            
            
            if (frameRaw) {
                free(frameRaw);
                frameRaw = NULL;
            }
        }
    }
    
    _status.isFinish = YES;
}

// This method has to be executed with render mutex locked.
-(void) decoderRenderFrame:(VideoFrameYUV*)frame{
    //Out frame processing
    BOOL dropFrame = NO;
    if (self.dataQueue.count >= 2*RENDER_DROP_THRESHOLD)
    {
        if (glViewRenderFrameCount% 3!=0) {
            dropFrame = YES;
        }
    }
    else if(self.dataQueue.count > RENDER_DROP_THRESHOLD)
    {
        if (glViewRenderFrameCount%2 != 0) {
            dropFrame = YES;
        }
    }
    
    if (!dropFrame) {
        [_glView render:frame];
    }
        
    glViewRenderFrameCount++;
}
#pragma mark - glview frame change

-(void) movieGlView:(MovieGLView *)view didChangedFrame:(CGRect)frame{
    self.frame = frame;
}

#pragma mark - lb2 hack delegate

-(void) lb2AUDHackParser:(id)parser didParsedData:(void *)data size:(int)size{
    
#if __LB2_PARSER_DUMP__
    if(!lb2Dumper){
        lb2Dumper = [[DJIDataDumper alloc] init];
        lb2Dumper.namePerfix = @"lb2_hack";
    }
    
    [lb2Dumper dumpData:data length:size];
#endif
    
    [_videoExtractor parseVideo:data length:size withFrame:^(VideoFrameH264Raw *frame) {
        if (!frame) {
            return;
        }
        
        if (self.dataQueue.count > FRAME_DROP_THRESHOLD) {
//            DJILOG(@"decode dataqueue drop %d", FRAME_DROP_THRESHOLD);
            [self.dataQueue clear];
        }
        [self.dataQueue push:(uint8_t*)frame length:sizeof(VideoFrameH264Raw) + frame->frame_size];
    }];
}

#pragma mark - frame processor interface

-(BOOL) videoProcessorEnabled
{
    return YES;
}

-(void) videoProcessFrame:(VideoFrameYUV *)frame{
    _lastFrameDecodedTime = [self getTickCount];
    
    if (safe_resume_skip_count || _status.isPause) {
        //Decoding need to skip a certain number of frames
        return;
    }
    
    pthread_mutex_lock(&_render_mutex);
    if ([self glviewCanRender]) {
        [self decoderRenderFrame:frame];
    }
    pthread_mutex_unlock(&_render_mutex);
    
    pthread_mutex_lock(&_processor_mutex);
    NSArray* frameProcessorCopyList = [NSArray arrayWithArray:_frame_processor_list];
    pthread_mutex_unlock(&_processor_mutex);
    
    for (id<VideoFrameProcessor> processor in frameProcessorCopyList) {
        if ([processor conformsToProtocol:@protocol(VideoFrameProcessor)]) {
            
            if (![processor videoProcessorEnabled]) {
                continue;
            }
            
            [processor videoProcessFrame:frame];
        }
    }
}

//decode single frame failed.
-(void) videoProcessFailedFrame{
    
    videoDecoderFailedCount++;
    
    if (videoDecoderFailedCount >= 6) {
        if (videoDecoderCanReset || _enableHardwareDecode){
            [self reset];
            videoDecoderCanReset = NO;
        }
        
        videoDecoderFailedCount = 0;
    }
    
    pthread_mutex_lock(&_processor_mutex);
    NSArray* frameProcessorCopyList = [NSArray arrayWithArray:_frame_processor_list];
    pthread_mutex_unlock(&_processor_mutex);
    
    for (id<VideoFrameProcessor> processor in frameProcessorCopyList) {
        if ([processor conformsToProtocol:@protocol(VideoFrameProcessor)]) {
            
            if (![processor videoProcessorEnabled]) {
                continue;
            }
            
            [processor videoProcessFailedFrame];
        }
    }
}

#pragma mark - videotoolbox decode callback

//handle 264 frame output from videotoolbox
-(void) decompressedFrame:(CVImageBufferRef)image frameInfo:(VideoFrameH264Raw *)frame
{
    if (image == nil) {
#if __TEST_VIDEO_STUCK__
        if (frame != NULL)
        {
            [DJIVideoStuckTester finisedDecodeFrameWithIndex:frame->frame_uuid withState:false];
        }
#endif
        [self videoProcessFailedFrame];
        return;
    }
#if __TEST_VIDEO_STUCK__
    if (frame != NULL)
    {
        [DJIVideoStuckTester finisedDecodeFrameWithIndex:frame->frame_uuid withState:true];
    }
#endif
    //check status
    if(_status.isPause || _status.isBackground){
        return;
    }
    
    CFTypeID imageType = CFGetTypeID(image);
    if (imageType == CVPixelBufferGetTypeID()
        && (kCVPixelFormatType_420YpCbCr8Planar == CVPixelBufferGetPixelFormatType(image)
            || kCVPixelFormatType_420YpCbCr8PlanarFullRange == CVPixelBufferGetPixelFormatType(image))) {
            //make sure this is a yuv420 image
            CGSize size = CVImageBufferGetDisplaySize(image);
            if(kCVReturnSuccess != CVPixelBufferLockBaseAddress(image, 0))
                return;

            // -----------------------Cape added-----------------------
            [self.delegate didReceiveDecompressedFrame:image];
            // --------------------------------------------------------

            VideoFrameYUV yuvImage = {0};
            yuvImage.luma = CVPixelBufferGetBaseAddressOfPlane(image, 0);
            yuvImage.chromaB = CVPixelBufferGetBaseAddressOfPlane(image, 1);
            yuvImage.chromaR = CVPixelBufferGetBaseAddressOfPlane(image, 2);
            yuvImage.lumaSlice = (int)CVPixelBufferGetBytesPerRowOfPlane(image, 0);
            yuvImage.chromaBSlice = (int)CVPixelBufferGetBytesPerRowOfPlane(image, 1);
            yuvImage.chromaRSlice = (int)CVPixelBufferGetBytesPerRowOfPlane(image, 2);
            yuvImage.width = size.width;
            yuvImage.height = size.height;
            yuvImage.frame_uuid = -1;
            yuvImage.frame_info.frame_index = H264_FRAME_INVALIED_UUID;
            
            if (frame && frame->frame_uuid != H264_FRAME_INVALIED_UUID) {
                yuvImage.frame_info = frame->frame_info;
                yuvImage.frame_uuid = frame->frame_uuid;
            }

            [self videoProcessFrame:&yuvImage];
            
            CVPixelBufferUnlockBaseAddress(image, 0);
        }
    else if (imageType == CVPixelBufferGetTypeID()
             && (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange == CVPixelBufferGetPixelFormatType(image)
                 || kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange == CVPixelBufferGetPixelFormatType(image))) {

                 CGSize size = CVImageBufferGetDisplaySize(image);
                 if(kCVReturnSuccess != CVPixelBufferLockBaseAddress(image, 0))
                     return;

                 // -----------------------Cape added-----------------------
                 // FIXME: Causes crash in webRTC with XT. Works with X3 but super janky video.
                 [self.delegate didReceiveDecompressedFrame:image];
                 // --------------------------------------------------------

                 VideoFrameYUV yuvImage = {0};
                 yuvImage.luma = CVPixelBufferGetBaseAddressOfPlane(image, 0);
                 yuvImage.chromaB = CVPixelBufferGetBaseAddressOfPlane(image, 1);
                 yuvImage.lumaSlice = (int)CVPixelBufferGetBytesPerRowOfPlane(image, 0);
                 yuvImage.chromaBSlice = (int)CVPixelBufferGetBytesPerRowOfPlane(image, 1);
                 yuvImage.width = size.width;
                 yuvImage.height = size.height;
                 yuvImage.frame_uuid = -1;
                 yuvImage.frameType = VPFrameTypeYUV420SemiPlaner;
                 yuvImage.frame_info.frame_index = H264_FRAME_INVALIED_UUID;

                 if (frame && frame->frame_uuid != H264_FRAME_INVALIED_UUID) {
                     yuvImage.frame_info = frame->frame_info;
                     yuvImage.frame_uuid = frame->frame_uuid;
                 }
                 yuvImage.cv_pixelbuffer_fastupload = image;
                 [self videoProcessFrame:&yuvImage];

                 CVPixelBufferUnlockBaseAddress(image, 0);
             }
}

-(void) hardwareDecoderUnavailable{
    //use soft decoder
    self.enableHardwareDecode = NO;
}


#pragma mark - tests

static FILE* g_fp = nil;
static uint8_t* g_pBuffer = nil;

#if __WAIT_STEP_FRAME__
dispatch_semaphore_t g_restart_wait = 0;
#endif

-(uint8_t*) testQueuePull:(int*)size{
    int frameSize = 2048;
    
    if (!g_fp) {
        NSArray* doucuments = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString* filePath = [doucuments objectAtIndex:0];
        
        filePath = [filePath stringByAppendingPathComponent:@"hard_3M.h264"];
        g_fp = fopen([filePath UTF8String], "rb");
        g_pBuffer = (uint8_t*)malloc(frameSize);
    }
    
#if __WAIT_STEP_FRAME__
    if (g_restart_wait == 0) {
        g_restart_wait = dispatch_semaphore_create(0);
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleTestNotification:)
                                                     name:@"preview"
                                                   object:nil];
    }

#endif
    
    while (g_fp)
    {
        static int read_size = 0;
        static int parse_size = 0;
        static int frame_counter = 0;
        
        while (!feof(g_fp)) {
            
            __block uint8_t* outframe = nil;
            __block int outframeSize = 0;
            
            size_t nRead = fread(g_pBuffer, 1, frameSize, g_fp);
            //                        [[[VideoPreviewer instance] dataQueue] push:pBuffer length:nRead];
            read_size += nRead;
            [_videoExtractor parseVideo:g_pBuffer length:frameSize withFrame:^(VideoFrameH264Raw *frame) {
                if (frame) {
                    outframe = (uint8_t*)frame;
                    outframeSize = frame->frame_size + sizeof(VideoFrameH264Raw);
                }
            }];
            if (outframe) {
                self.encoderType = H264EncoderType_GD600;
                self.enableHardwareDecode = YES;
                *size = outframeSize;
                
#if __WAIT_STEP_FRAME__
                dispatch_semaphore_wait(g_restart_wait, DISPATCH_TIME_FOREVER);
//                DJILog(@"frame %d offset:%p", frame_counter, parse_size);
#endif
                parse_size += outframeSize;
                frame_counter ++;
                return outframe;
            }
        }
        
        parse_size = 0;
        frame_counter = 0;
        fseek(g_fp, SEEK_SET, 0);
    }
    return nil;
}

#if __TEST_FRAME_PULL__

static DJIH264FrameRawLayerDumper* g_frameReader = nil;
-(VideoFrameH264Raw*) testFramePull:(int*)size{
    static DJIDataDumper* dumper = nil;
    
    if (!g_frameReader) {
        g_frameReader = [[DJIH264FrameRawLayerDumper alloc] init];
        [g_frameReader openFile:@"h264frame_2016-05-06[10][29][48][372]_clip.bin"];
        //dumper = [[DJIDataDumper alloc] init];
        //dumper.namePerfix = @"frame_out";
    }
    
#if __WAIT_STEP_FRAME__
    if (g_restart_wait == 0) {
        g_restart_wait = dispatch_semaphore_create(0);
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleTestNotification:)
                                                     name:@"preview"
                                                   object:nil];
    }
    dispatch_semaphore_wait(g_restart_wait, DISPATCH_TIME_FOREVER);
#endif
    
    VideoFrameH264Raw* frame = [g_frameReader readNextFrame];
    if (!frame) {
        [g_frameReader seekToHead];
        return nil;
    }
    
    [dumper dumpData:frame->frame_data length:frame->frame_size];
    
    self.encoderType = H264EncoderType_H1_Inspire2;
    *size = (int)frame->frame_size + (int)sizeof(VideoFrameH264Raw);
    return frame;
}
#endif

-(void) handleTestNotification:(NSNotification*)notify{
    
#if __WAIT_STEP_FRAME__
    if ([notify.object isEqualToString:@"start"]) {

        if (g_restart_wait) {
            dispatch_semaphore_signal(g_restart_wait);
        }
    }
#endif
}

static NSThread* g_pack_pull_test_thread;

-(void) testPackPull{
#if __TEST_PACK_PULL__
    if (g_pack_pull_test_thread) {
        return;
    }
    
    g_pack_pull_test_thread = [[NSThread alloc] initWithTarget:self
                                                      selector:@selector(packPullThreadWork)
                                                        object:nil];
    [g_pack_pull_test_thread start];
#endif
}

#if __TEST_PACK_PULL__
-(void) packPullThreadWork{
    DJIDataDumper* dumper = [[DJIDataDumper alloc] init];
    if (![dumper openFile:@"videoPack_2016-09-24[21][12][15][720].bin" withPackAlignMode:YES]) {
        return;
    }
    
    size_t data_counter = 0;
    size_t pack_counter = 0;
    
    while (1) {
        @autoreleasepool {
            if (self.dataQueue.count > 3) {
                usleep(5000);
                continue;
            }
            
            size_t size = 0;
            uint8_t* data = [dumper readNextPack:&size];
            pack_counter++;
            data_counter += size;
            
            if (data && size) {
                self.encoderType = H264EncoderType_LightBridge2;
                [self push:data length:(int)size];
            }
            else{
                [dumper seekToHead];
                pack_counter = 0;
                data_counter = 0;
#if __WAIT_STEP_FRAME__
                if (g_restart_wait == 0) {
                    g_restart_wait = dispatch_semaphore_create(0);
                    [[NSNotificationCenter defaultCenter] addObserver:self
                                                             selector:@selector(handleTestNotification:)
                                                                 name:@"preview"
                                                               object:nil];
                }
                dispatch_semaphore_wait(g_restart_wait, DISPATCH_TIME_FOREVER);
#endif
            }
            
            if (data) {
                free(data);
            }
        }
        usleep(2000);
    }
}
#endif

-(void) performanceCount:(int)inputDataSize {
    static NSDate* startTime = nil;
    static int video_last_count_time = 0;
    CGFloat _outputFps;
    int _outputKbitPerSec;
    
    if (startTime == nil) {
        startTime = [NSDate date];
    }
    
    //status check
    int tEndTime = (1000*(-[startTime timeIntervalSinceNow]));
    {
        static int frame_count = 0;
        static int bits_count = 0;
        
        frame_count++;
        bits_count += inputDataSize*8;
        
        int diff = (int)((tEndTime - video_last_count_time));
        if (diff >= 1000) {
            _outputFps = 1000*frame_count/(double)diff;
            _outputKbitPerSec = (1000/(double)1024)*(bits_count/(double)diff);
            
//            DJILOG(@"fps:%.2f rate:%dkbps buffer:%d", _outputFps, _outputKbitPerSec, (int)_dataQueue.count);
            
            frame_count = 0;
            bits_count = 0;
            video_last_count_time = tEndTime;
        }
    }
}

// -----------------------Cape added-----------------------
-(void) setDelegate:(id<DecompressedFrameDelegate>)delegate
{
    _delegate = delegate;
    self.soft_decoder.delegate = delegate;
}
// --------------------------------------------------------

@end
