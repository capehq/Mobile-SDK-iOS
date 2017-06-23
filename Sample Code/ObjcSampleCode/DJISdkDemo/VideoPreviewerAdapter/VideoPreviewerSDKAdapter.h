//
//  VideoPreviewerSDKAdapter.h
//  VideoPreviewer
//
//  Copyright © 2016 DJI. All rights reserved.
//

#import <Foundation/Foundation.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#import <DJISDK/DJISDK.h>
#pragma clang diagnostic pop

@class VideoPreviewer;

@interface VideoPreviewerSDKAdapter : NSObject <DJIVideoFeedSourceListener, DJIVideoFeedListener>

+(instancetype _Nonnull )adapterWithDefaultSettings;

+(instancetype _Nonnull )adapterWithForLightbridge2; 

+(instancetype _Nonnull )adapterWithVideoPreviewer:(VideoPreviewer *_Nullable)videoPreviewer andVideoFeed:(DJIVideoFeed *_Nullable)videoFeed;

@property (nonatomic, weak) VideoPreviewer * _Nullable videoPreviewer;

@property (nonatomic, weak) DJIVideoFeed * _Nullable videoFeed;

-(void)start;

-(void)stop;

@end
