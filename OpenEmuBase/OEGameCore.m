/*
 Copyright (c) 2009, OpenEmu Team

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <OpenGL/gl.h>

#import "OEGameCore.h"
#import "OEGameCoreController.h"
#import "OEAbstractAdditions.h"
#import "OERingBuffer.h"
#import "OETimingUtils.h"

#ifndef BOOL_STR
#define BOOL_STR(b) ((b) ? "YES" : "NO")
#endif

NSString *const OEGameCoreErrorDomain = @"org.openemu.GameCore.ErrorDomain";

@implementation OEGameCore
{
    NSThread *_gameCoreThread;
    CFRunLoopRef _gameCoreRunLoop;

    void (^_stopEmulationHandler)(void);

    OERingBuffer __strong **ringBuffers;

    OEDiffQueue            *rewindQueue;
    NSUInteger              rewindCounter;

    BOOL                    shouldStop;
    BOOL                    singleFrameStep;
    BOOL                    isRewinding;
    BOOL                    isPausedExecution;

    NSTimeInterval          lastRate;
}

static Class GameCoreClass = Nil;
static NSTimeInterval defaultTimeInterval = 60.0;

+ (void)initialize
{
    if(self == [OEGameCore class])
    {
        GameCoreClass = [OEGameCore class];
    }
}

- (id)init
{
    self = [super init];
    if(self != nil)
    {
        NSUInteger count = [self audioBufferCount];
        ringBuffers = (__strong OERingBuffer **)calloc(count, sizeof(OERingBuffer *));
    }
    return self;
}

- (void)dealloc
{
    DLog(@"%s", __FUNCTION__);

    for(NSUInteger i = 0, count = [self audioBufferCount]; i < count; i++)
        ringBuffers[i] = nil;

    free(ringBuffers);
}

- (OERingBuffer *)ringBufferAtIndex:(NSUInteger)index
{
    NSAssert1(index < [self audioBufferCount], @"The index %lu is too high", index);
    if(ringBuffers[index] == nil)
        ringBuffers[index] = [[OERingBuffer alloc] initWithLength:[self audioBufferSizeForBuffer:index] * 16];

    return ringBuffers[index];
}

- (NSString *)pluginName
{
    return [[self owner] pluginName];
}

- (NSString *)biosDirectoryPath
{
    return [[self owner] biosDirectoryPath];
}

- (NSString *)supportDirectoryPath
{
    return [[self owner] supportDirectoryPath];
}

- (NSString *)batterySavesDirectoryPath
{
    return [[self supportDirectoryPath] stringByAppendingPathComponent:@"Battery Saves"];
}

- (BOOL)supportsRewinding
{
    return [[self owner] supportsRewindingForSystemIdentifier:[self systemIdentifier]];
}

- (NSUInteger)rewindInterval
{
    return [[self owner] rewindIntervalForSystemIdentifier:[self systemIdentifier]];
}

- (NSUInteger)rewindBufferSeconds
{
    return [[self owner] rewindBufferSecondsForSystemIdentifier:[self systemIdentifier]];
}

- (OEDiffQueue *)rewindQueue
{
    if(rewindQueue == nil) {
        NSUInteger capacity = ceil(([self frameInterval]*[self rewindBufferSeconds]) / ([self rewindInterval]+1));
        rewindQueue = [[OEDiffQueue alloc] initWithCapacity:capacity];
    }
    return rewindQueue;
}

#pragma mark - Execution

- (void)performBlock:(void(^)(void))block
{
    if (_gameCoreRunLoop == nil) {
        block();
        return;
    }

    CFRunLoopPerformBlock(_gameCoreRunLoop, kCFRunLoopCommonModes, ^{
        block();
    });
}

- (void)_gameCoreThreadWithStartEmulationCompletionHandler:(void (^)(void))startCompletionHandler
{
    @autoreleasepool {
        _gameCoreRunLoop = CFRunLoopGetCurrent();

        [self startEmulation];

        if (startCompletionHandler != nil)
            dispatch_async(dispatch_get_main_queue(), startCompletionHandler);

        [self runGameLoop:nil];

        _gameCoreRunLoop = nil;
    }
}

// GameCores that render direct to OpenGL rather than a buffer should override this and return YES
// If the GameCore subclass returns YES, the renderDelegate will set the appropriate GL Context
// So the GameCore subclass can just draw to OpenGL
- (BOOL)rendersToOpenGL
{
    return NO;
}

- (void)setupEmulationWithCompletionHandler:(void (^)(void))completionHandler
{
    [self setupEmulation];

    if (completionHandler != nil)
        completionHandler();
}

- (void)setupEmulation
{
}

- (void)startEmulationWithCompletionHandler:(void (^)(void))completionHandler
{
    _gameCoreThread = [[NSThread alloc] initWithTarget:self selector:@selector(_gameCoreThreadWithStartEmulationCompletionHandler:) object:completionHandler];
    _gameCoreThread.name = @"org.openemu.core-thread";
    _gameCoreThread.qualityOfService = NSQualityOfServiceUserInteractive;

    [_gameCoreThread start];
}

- (void)resetEmulationWithCompletionHandler:(void (^)(void))completionHandler
{
    [self performBlock:^{
        [self resetEmulation];

        if (completionHandler)
            dispatch_async(dispatch_get_main_queue(), completionHandler);
    }];
}

- (void)runStartUpFrameWithCompletionHandler:(void(^)(void))handler
{
    [_renderDelegate willExecute];
    [self executeFrame];
    [_renderDelegate didExecute];

    handler();
}

- (void)runGameLoop:(id)anArgument
{
    NSTimeInterval realTime, emulatedTime = OEMonotonicTime();

#if 0
    __block NSTimeInterval gameTime = 0;
    __block int wasZero=1;
#endif

    DLog(@"main thread: %s", BOOL_STR([NSThread isMainThread]));

    OESetThreadRealtime(1. / (_rate * [self frameInterval]), .007, .03); // guessed from bsnes

    while(!shouldStop)
    {
    @autoreleasepool
    {
#if 0
        gameTime += 1. / [self frameInterval];
        if(wasZero && gameTime >= 1)
        {
            NSUInteger audioBytesGenerated = ringBuffers[0].bytesWritten;
            double expectedRate = [self audioSampleRateForBuffer:0];
            NSUInteger audioSamplesGenerated = audioBytesGenerated/(2*[self channelCount]);
            double realRate = audioSamplesGenerated/gameTime;
            NSLog(@"AUDIO STATS: sample rate %f, real rate %f", expectedRate, realRate);
            wasZero = 0;
        }
#endif

        // Frame skipping actually isn't possible with LLE...
        self.shouldSkipFrame = NO;

        BOOL executing = _rate > 0 || singleFrameStep || isPausedExecution;

        if(executing && isRewinding)
        {
            if (singleFrameStep) {
                singleFrameStep = isRewinding = NO;
            }

            NSData *state = [[self rewindQueue] pop];
            if(state)
            {
                [_renderDelegate willExecute];
                [self executeFrame];
                [_renderDelegate didExecute];

                [self deserializeState:state withError:nil];
            }
        }
        else if(executing)
        {
            singleFrameStep = NO;
            //OEPerfMonitorObserve(@"executeFrame", gameInterval, ^{

            if([self supportsRewinding] && rewindCounter == 0)
            {
                NSData *state = [self serializeStateWithError:nil];
                if(state)
                {
                    [[self rewindQueue] push:state];
                }
                rewindCounter = [self rewindInterval];
            }
            else
            {
                --rewindCounter;
            }

            [_renderDelegate willExecute];
            [self executeFrame];
            [_renderDelegate didExecute];
            //});
        }

        NSTimeInterval frameInterval = self.frameInterval;
        NSTimeInterval adjustedRate = _rate ?: 1;
        NSTimeInterval advance = 1.0 / (adjustedRate * frameInterval);

        emulatedTime += advance;
        realTime = OEMonotonicTime();

        // if we are running more than a second behind, synchronize
        if(realTime - emulatedTime > 1.0)
        {
            NSLog(@"Synchronizing because we are %g seconds behind", realTime - emulatedTime);
            emulatedTime = realTime;
        }

        OEWaitUntil(emulatedTime);

        // Service the event loop, which may now contain HID events, exactly once.
        // TODO: If paused, this burns CPU waiting to unpause, because it still runs at 1x rate.
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, 0);
    }
    }

    [[self delegate] gameCoreDidFinishFrameRefreshThread:self];
}

- (void)stopEmulation
{
    [_renderDelegate suspendFPSLimiting];
    shouldStop = YES;
    DLog(@"Ending thread");
    [self didStopEmulation];
}

- (void)stopEmulationWithCompletionHandler:(void(^)(void))completionHandler;
{
    [self performBlock:^{
        _stopEmulationHandler = [completionHandler copy];

        if (self.hasAlternateRenderingThread)
            [_renderDelegate willRenderFrameOnAlternateThread];
        else
            [_renderDelegate willExecute];

        [self stopEmulation];
    }];
}

- (void)didStopEmulation
{
    if(_stopEmulationHandler != nil)
        dispatch_async(dispatch_get_main_queue(), _stopEmulationHandler);

    _stopEmulationHandler = nil;
}

- (void)startEmulation
{
    if ([self class] == GameCoreClass) return;
    if (_rate != 0) return;

    [_renderDelegate resumeFPSLimiting];
    self.rate = 1;
}

#pragma mark - ABSTRACT METHODS

- (void)resetEmulation
{
    [self doesNotImplementSelector:_cmd];
}

- (void)executeFrame
{
    [self doesNotImplementSelector:_cmd];
}

- (BOOL)loadFileAtPath:(NSString *)path
{
    [self doesNotImplementSelector:_cmd];
    return NO;
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated"
    return [self loadFileAtPath:path];
#pragma clang diagnostic pop
}

#pragma mark - Video

- (OEIntRect)screenRect
{
    return (OEIntRect){ {}, [self bufferSize]};
}

- (OEIntSize)bufferSize
{
    [self doesNotImplementSelector:_cmd];
    return (OEIntSize){};
}

- (OEIntSize)aspectSize
{
    return (OEIntSize){ 4, 3 };
}

- (const void *)videoBuffer
{
    [self doesNotImplementSelector:_cmd];
    return NULL;
}

- (GLenum)pixelFormat
{
    [self doesNotImplementSelector:_cmd];
    return 0;
}

- (GLenum)pixelType
{
    [self doesNotImplementSelector:_cmd];
    return 0;
}

- (GLenum)internalPixelFormat
{
    return GL_RGB;
}

- (BOOL)hasAlternateRenderingThread
{
    return NO;
}

- (BOOL)needsDoubleBufferedFBO
{
    return NO;
}

- (OEGameCoreRendering)gameCoreRendering {
    if ([self respondsToSelector:@selector(rendersToOpenGL)]) {
        return [self rendersToOpenGL] ? OEGameCoreRenderingOpenGL2Video : OEGameCoreRendering2DVideo;
    }

    return OEGameCoreRendering2DVideo;
}

- (const void*)getVideoBufferWithHint:(void *)hint
{
    return [self videoBuffer];
}

- (BOOL)tryToResizeVideoTo:(OEIntSize)size
{
    if (self.gameCoreRendering == OEGameCoreRendering2DVideo)
        return NO;

    return YES;
}

- (NSTimeInterval)frameInterval
{
    return defaultTimeInterval;
}

- (void)fastForward:(BOOL)flag
{
    float newrate = flag ? 5.0 : 1.0;
  
    if (self.isEmulationPaused) {
        lastRate = newrate;
    } else {
        self.rate = newrate;
    }
}

- (void)rewind:(BOOL)flag
{
    if(flag && [self supportsRewinding] && ![[self rewindQueue] isEmpty])
    {
        isRewinding = YES;
    }
    else
    {
        isRewinding = NO;
    }
}

- (void)setPauseEmulation:(BOOL)paused
{
    if (self.rate == 0 && paused)  return;
    if (self.rate != 0 && !paused) return;

    // Set rate to 0 and store the previous rate.
    if (paused) {
        lastRate = self.rate;
        self.rate = 0;
    } else {
        self.rate = lastRate;
    }
}

- (BOOL)isEmulationPaused
{
    return self.rate == 0;
}

- (void)fastForwardAtSpeed:(CGFloat)fastForwardSpeed;
{
    // FIXME: Need implementation.
}

- (void)rewindAtSpeed:(CGFloat)rewindSpeed;
{
    // FIXME: Need implementation.
}

- (void)slowMotionAtSpeed:(CGFloat)slowMotionSpeed;
{
    // FIXME: Need implementation.
}

- (void)stepFrameForward
{
    singleFrameStep = YES;
}

- (void)stepFrameBackward
{
    singleFrameStep = isRewinding = YES;
}

- (void)setRate:(float)rate
{
    NSLog(@"Rate change %f -> %f", _rate, rate);

    _rate = rate;
    [_renderDelegate setEnableVSync:_rate == 1];
    OESetThreadRealtime(1./(_rate * [self frameInterval]), .007, .03);
}

- (void)beginPausedExecution
{
    if (isPausedExecution == YES) return;

    isPausedExecution = YES;
    [_renderDelegate suspendFPSLimiting];
    [_audioDelegate pauseAudio];
}

- (void)endPausedExecution
{
    if (isPausedExecution == NO) return;

    isPausedExecution = NO;
    [_renderDelegate resumeFPSLimiting];
    [_audioDelegate resumeAudio];
}

#pragma mark - Audio

- (NSUInteger)audioBufferCount
{
    return 1;
}

- (void)getAudioBuffer:(void *)buffer frameCount:(NSUInteger)frameCount bufferIndex:(NSUInteger)index
{
    [[self ringBufferAtIndex:index] read:buffer maxLength:frameCount * [self channelCountForBuffer:index] * sizeof(UInt16)];
}

- (NSUInteger)channelCount
{
    [self doesNotImplementSelector:_cmd];
    return 0;
}

- (double)audioSampleRate
{
    [self doesNotImplementSelector:_cmd];
    return 0;
}

- (NSUInteger)audioBitDepth
{
    return 16;
}

- (NSUInteger)channelCountForBuffer:(NSUInteger)buffer
{
    if(buffer == 0) return [self channelCount];

    NSLog(@"Buffer count is greater than 1, must implement %@", NSStringFromSelector(_cmd));
    [self doesNotImplementSelector:_cmd];
    return 0;
}

- (NSUInteger)audioBufferSizeForBuffer:(NSUInteger)buffer
{
    // 4 frames is a complete guess
    double frameSampleCount = [self audioSampleRateForBuffer:buffer] / [self frameInterval];
    NSUInteger channelCount = [self channelCountForBuffer:buffer];
    NSUInteger bytesPerSample = [self audioBitDepth] / 8;
    NSAssert(frameSampleCount, @"frameSampleCount is 0");
    return channelCount*bytesPerSample * frameSampleCount;
}

- (double)audioSampleRateForBuffer:(NSUInteger)buffer
{
    if(buffer == 0) return [self audioSampleRate];

    NSLog(@"Buffer count is greater than 1, must implement %@", NSStringFromSelector(_cmd));
    [self doesNotImplementSelector:_cmd];
    return 0;
}


#pragma mark - Input

- (NSTrackingAreaOptions)mouseTrackingOptions
{
    return 0;
}

#pragma mark - Save state

- (NSData *)serializeStateWithError:(NSError **)outError
{
    return nil;
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError **)outError
{
    return NO;
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void(^)(BOOL success, NSError *error))block
{
    block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreDoesNotSupportSaveStatesError userInfo:nil]);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void(^)(BOOL success, NSError *error))block
{
    block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreDoesNotSupportSaveStatesError userInfo:nil]);
}

#pragma mark - Cheats

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
}

#pragma mark - Misc

- (void)changeDisplayMode;
{
}

#pragma mark - Discs

- (NSUInteger)discCount
{
    return 1;
}

- (void)setDisc:(NSUInteger)discNumber
{
}

@end
