//
//  VideoPreviewerLogging.h
//  VideoPreviewer
//
//  Created by Rick Pasetto on 1/25/18.
//  Copyright © 2018 dji. All rights reserved.
//

#ifndef VideoPreviewerLogging_h
#define VideoPreviewerLogging_h

#define DEBUGLOG(string) if(VideoPreviewerLogging.debugLog){VideoPreviewerLogging.debugLog(string);}
#define INFOLOG(string) if(VideoPreviewerLogging.infoLog){VideoPreviewerLogging.infoLog(string);}
#define ERRORLOG(string) if(VideoPreviewerLogging.errorLog){VideoPreviewerLogging.errorLog(string);}

#define STRINGIFY(fmt, ...) [NSString stringWithFormat:fmt, ##__VA_ARGS__]
#define DJILOG(fmt, ...)  DEBUGLOG(STRINGIFY(fmt, ##__VA_ARGS__))
#define INFO(fmt, ...)  INFOLOG(STRINGIFY(fmt, ##__VA_ARGS__))
#define ERROR(fmt, ...)  ERRORLOG(STRINGIFY(fmt, ##__VA_ARGS__))

@interface VideoPreviewerLogging : NSObject
typedef void (^ _Nullable LogFunc)(NSString * _Nonnull fmt);
@property (class, strong) LogFunc debugLog;
@property (class, strong) LogFunc infoLog;
@property (class, strong) LogFunc errorLog;
@end

#endif /* VideoPreviewerLogging_h */
