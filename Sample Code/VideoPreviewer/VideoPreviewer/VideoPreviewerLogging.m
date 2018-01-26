//
//  VideoPreviewerLogging.m
//  VideoPreviewer
//
//  Created by Rick Pasetto on 1/25/18.
//  Copyright © 2018 dji. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "VideoPreviewerLogging.h"

@implementation VideoPreviewerLogging

static LogFunc _debugLog;
+ (LogFunc) debugLog { return _debugLog; }
+ (void)setDebugLog:(LogFunc)newFunc { _debugLog = newFunc;}
static LogFunc _infoLog;
+ (LogFunc) infoLog { return _infoLog; }
+ (void)setInfoLog:(LogFunc)newFunc { _infoLog = newFunc; }
static LogFunc _errorLog;
+ (LogFunc) errorLog { return _errorLog; }
+ (void)setErrorLog:(LogFunc)newFunc { _errorLog = newFunc; }

@end

