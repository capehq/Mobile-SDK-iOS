//
//  SoftwareDecodeProcessor.h
//
//  Copyright (c) 2015 DJI. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "DJIStreamCommon.h"
#import "VideoFrameExtractor.h"

@interface SoftwareDecodeProcessor : NSObject <VideoStreamProcessor>
@property (nonatomic, weak) id<VideoFrameProcessor> frameProcessor;
@property (nonatomic, assign) BOOL enabled;

// -----------------------Cape added-----------------------
@property (nonatomic, weak) id<DecompressedFrameDelegate> delegate;
// --------------------------------------------------------

-(id) initWithExtractor:(VideoFrameExtractor*)extractor;
@end
