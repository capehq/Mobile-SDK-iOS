//
//  VideoPreviewer.h
//
//  Copyright (c) 2013 DJI. All rights reserved.
//


#import <UIKit/UIKit.h>
#import "DJIStreamCommon.h"
#import "VideoFrameExtractor.h"
#import "MovieGLView.h"
#import "H264VTDecode.h"
#import "DJIVideoHelper.h"
#import "DJISmoothDecode.h"
#import "SoftwareDecodeProcessor.h"
#import "DJIVideoPresentViewAdjustHelper.h"

// SDK
#import "DJIRTPlayerRenderView.h"
#import "DJIVTH264DecoderIFrameData.h"

#define __WAIT_STEP_FRAME__   (0) //单步调试用，搭配test_queue_pull

#define VIDEO_PREVIEWER_DISPATCH "video_preview_create_thread_dispatcher"
#define VIDEO_PREVIEWER_EVEN_NOTIFICATIOIN @"video_preview_even_notification"

typedef struct{
    BOOL isInit:1;  // YES when VideoPreviewer is initialized
    BOOL isRunning:1;   // YES when the decoding thread is running
    BOOL isPause:1;     // YES when the decoder is paused
    BOOL isFinish:1;    // YES when it is finished
    BOOL hasImage:1;    // YES when it has image
    BOOL isGLViewInit:1; // YES when the GLView is initialized
    BOOL isBackground:1;    // YES when VideoPreview is in background
    uint8_t other:1;    // reserved
}VideoPreviewerStatus;

typedef enum : NSUInteger {
    VideoDecoderStatus_Normal, //normal status
    VideoDecoderStatus_NoData,  //no data
    VideoDecoderStatus_DecoderError,   //decode error
} VideoDecoderStatus;

typedef NS_ENUM(NSUInteger, VideoPreviewerEvent){
    VideoPreviewerEventNoImage,     //decode no image
    VideoPreviewerEventHasImage,    //decode has image
    VideoPreviewerEventResumeReady,      //after safe resume resume decode
};

typedef NS_ENUM(NSUInteger, VideoPreviewerType){
    VideoPreviewerTypeAutoAdapt,    //auto just to adapt size
    VideoPreviewerTypeFullWindow,   //full window
    VideoPreviewerTypeNone, //none
};


#pragma mark - data input

/**
 *  UI component used to show the video feed streamed from DJI device. FFmpeg is
 *  required. It consists of decoder, data buffer queue and OpenGL renderer。
 *  Set the view before calling the `start` method。
 */
@interface VideoPreviewer : NSObject


@property (nonatomic,assign,getter=isPerformanceCountEnabled) BOOL performanceCountEnabled;

// a tag for video processor and frame processor
@property (assign, nonatomic) uint8_t videoChannelTag;

/*
 * create a new preview, this instance is not the default one
 */
-(instancetype _Nonnull ) init;
-(instancetype _Nonnull ) initWithQueueSize:(int)queueSize;

/**
 *  Push video data
 */
-(void) push:(uint8_t*_Nonnull)videoData length:(int)len;

/**
 *  Clear video data buffer
 */
-(void) clearVideoData;

/** Logging */
typedef void (^ _Nullable LogFunc)(NSString * _Nonnull fmt);
@property (class, strong) LogFunc debugLog;
@property (class, strong) LogFunc infoLog;
@property (class, strong) LogFunc errorLog;

@end

#pragma mark - instance

@interface VideoPreviewer (Instance)

/**
 *  YES if this is the first instance
 */
@property (nonatomic, readonly) BOOL isDefaultPreviewer;

/**
 *  get default previewer
 */
+(VideoPreviewer*_Nullable) instance;

// SDK
/**
 *  Release the default instance.
 */
+(void)releaseInstance;

@end

#pragma mark - geometry

@interface VideoPreviewer (Geometry)
/**
 *  for kvo, preview content frame
 */
@property (nonatomic, readonly) CGRect frame;

/*
 * for internal use only
 */
@property (nonatomic, readonly) MovieGLView* _Nullable internalGLView;
@end

@interface VideoPreviewer ()

/**
 *  rotation of the preview content
 *  CAUTION: SHOULD BE CALLED IN MAIN THREAD!
 */
@property (assign, nonatomic) VideoStreamRotationType rotation;

// content clipping [0~1] in width, [0~1] in height,
// use all 0 as default
// use this rect to mark the usable part of the input stream
// glview will use this part to do auto size adjust
// CAUTION: SHOULD BE CALLED IN MAIN THREAD!
@property (assign, nonatomic) CGRect contentClipRect;

/**
 *  The display type used by the Video Previewer
 *  CAUTION: SHOULD BE CALLED IN MAIN THREAD!
 */
@property (nonatomic, assign) VideoPreviewerType type;

/**
 *  set the UIView which will display the rendering video stream
 *
 *  @param view the UIView instance to display the video stream
 *
 *  @return `YES` if it is set successfully.
 */
- (BOOL)setView:(UIView *_Nullable)view;

/**
 *  Unset the view which is set previously.
 */
- (void)unSetView;

/*
 * resize
 */
- (void)adjustViewSize;

/**
 *  Convert a point on the view to the coordinate system used by the video stream.
 *
 *  @param point coordinate of the point in the view.
 *  @param view the instance of the UIView.
 *  @return the location of point in the video stream coordinate
 */
-(CGPoint) convertPoint:(CGPoint)point toVideoViewFromView:(UIView*_Nullable)view;

/**
 *  Convert a point on from the video stream coordinate to the coordinate system
 *  used by the UIView.
 *
 *  @param point coordinate of the point in video stream.
 *  @param view the instance of the UIView.
 *  @return the location of point in the UIView
 */
-(CGPoint) convertPoint:(CGPoint)point fromVideoViewToView:(UIView *_Nullable)view;

@end

#pragma mark - decoder control

@interface VideoPreviewer (DecoderControl)
/**
 *  Current status of Video Previewer.
 */
@property (assign, readonly) VideoPreviewerStatus status;

/**
 *  Current status of the decoder inside Video Previewer.
 */
@property (nonatomic, readonly) VideoDecoderStatus decoderStatus;

/*
 * current stream info for rkvo
 */
@property (nonatomic, readonly) DJIVideoStreamBasicInfo currentStreamInfo;
/**
 *  Format of the output frame
 */
@property (readonly, nonatomic) VPFrameType frameOutputType;
@end

@interface VideoPreviewer ()  <VideoFrameProcessor>

/**
 *  enable hadeware decode
 */
@property (assign, nonatomic) BOOL enableHardwareDecode;

/**
 *  Use for choice the H264 steam type, default is inspire.
 */
@property (assign,nonatomic) H264EncoderType encoderType;

/**
 *  Enables the fast uploading to GPU. It is useful for hardware decoding and
 *  when it is enabled, the output image encoding format will become semi-Planar.
 */
@property (assign, nonatomic) BOOL enableFastUpload;

/**
 *  Start the decoding.
 *
 *  @return `YES` if it is started successfully.
 */
- (BOOL)start;

/**
 *  reset the decoding thread and re-initialize Video Frame Extractor
 */
-(void) reset;

/**
 *  Resume the decoding process. When using hardware decoder, the image may be
 *  abnormal for seconds when it just resumed.
 */
- (void)resume;

/**
 * Resume the decoding process. When using the hardware decoder, it will skip
 *  some frame to avoid abnormal images.
 */
- (void)safeResume;

/**
 *  Pause decoding.
 */
- (void)pause;

/*
 *  Pause decoding and determine if the screen is gray after the pause.
 */
-(void)pauseWithGrayout:(BOOL)isGrayout;

/**
 *  Turn off Video Previewer.
 */
- (void)close;

/*
 * clear gl view to black
 */
- (void)clearRender;

@end

#pragma mark - snapshot

@interface VideoPreviewer (SnapShot)

/**
 *  Screen capture of the current view
 */
-(void) snapshotPreview:(void(^_Nullable)(UIImage* _Nullable snapshot))block;

/**
 *  Screen capture thumbnail
 */
-(void) snapshotThumnnail:(void(^_Nullable)(UIImage* _Nullable snapshot))block;

@end

#pragma mark - processor

@interface VideoPreviewer (Processor)

/**
 *  @param processor Processor registered to receive the H264 stream data.
 */
-(void) registStreamProcessor:(id<VideoStreamProcessor> _Nullable )processor;

/**
 *  @param processor Remove registered processor list.
 */
-(void) unregistStreamProcessor:(id _Nullable )processor;

/*
 *  @param processor Processor registered to receive the VideoFrameYUV frame data.
 */
-(void) registFrameProcessor:(id <VideoFrameProcessor> _Nullable )processor;

/**
 *  @param processor Remove registered processor list.
 */
-(void) unregistFrameProcessor:(id _Nullable )processor;

@end

#pragma mark - filters and effects
///////////////// Filter's config ///////////////////////////

@interface VideoPreviewer ()

/**
 * Enable overexposure tips
 */
@property (nonatomic, assign) float overExposedWarningThreshold;


/**
 * Setting Exposure Compensation
 */
@property (nonatomic, assign) float luminanceScale;


/////////////// use sobel process //////////
/**
 * Enable focus tips
 */
@property (nonatomic, assign) BOOL enableFocusWarning;
/**
 *  Setting the Focus range rendering prompt
 */
@property (nonatomic, assign) float focusWarningThreshold;


////////////// revers d-log filter from camera ///////
@property (assign, nonatomic) DLogReverseLookupTableType dLogReverse;


///////////// hsb config //////////////////
@property (assign, nonatomic) BOOL enableHSB;
@property (assign, nonatomic) DJILiveViewRenderHSBConfig hsbConfig;


///////////// shadow and highlight ///////////
@property (assign, nonatomic) BOOL enableShadowAndHighLightenhancement;
/**
 * 0 - 1, increase to lighten shadows.
 * @default 0
 */
@property(readwrite, nonatomic) CGFloat shadowsLighten;

/**
 * 0 - 1, increase to darken highlights.
 * @default 0
 */
@property(readwrite, nonatomic) CGFloat highlightsDecrease;

// -----------------------Cape added-----------------------
@property(weak, nonatomic) id <DecompressedFrameDelegate> _Nullable delegate;
// -----------------------Cape added-----------------------

@end


#pragma mark - smooth decode
///////////////// delay the decode and smooth config ///////////////////////////

@interface VideoPreviewer ()
@property (nonatomic, strong) id <DJISmoothDecodeProtocol> _Nullable smoothDecode;
@end

