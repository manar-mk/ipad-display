#import "ViewController.h"
#import "FrameServer.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

static const uint16_t kPort = 7801;
static const int kAudioBuffers = 6;

@interface ViewController () <FrameServerDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIImageView *screen;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) FrameServer *server;
@end

@implementation ViewController {
    // touch state: one finger drives the mouse, two fingers scroll / pinch
    BOOL _multi, _mouseDown;
    UITouch *_mouseTouch;
    CGPoint _lastPan;
    CGFloat _lastScale;
    // audio playback: PCM chunks from the host are queued into AudioQueue buffers
    AudioQueueRef _queue;
    AudioQueueBufferRef _buffers[kAudioBuffers];
    NSMutableData *_pending;      // PCM not yet handed to the queue
    NSMutableArray *_freeBuffers; // NSValue(pointer) of idle AudioQueueBufferRef
    uint32_t _rate;
    uint8_t _channels;
    BOOL _audioStarted;
    // H.264 video: hardware decode + display via AVSampleBufferDisplayLayer
    AVSampleBufferDisplayLayer *_videoLayer;
    CMVideoFormatDescriptionRef _videoFormat;
    CGSize _videoSize;
    BOOL _videoActive;   // last content shown was video (not a JPEG)
    BOOL _waitKey;       // drop deltas until a keyframe arrives
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.view.multipleTouchEnabled = YES;

    // two-finger pan = scroll, pinch = zoom (Ctrl+wheel on the host), long press = right click
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    pan.minimumNumberOfTouches = 2; pan.maximumNumberOfTouches = 2; pan.cancelsTouchesInView = NO; pan.delegate = self;
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(onPinch:)];
    pinch.cancelsTouchesInView = NO; pinch.delegate = self;
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    lp.minimumPressDuration = 0.7; lp.allowableMovement = 12; lp.cancelsTouchesInView = NO; lp.delegate = self;
    [self.view addGestureRecognizer:pan];
    [self.view addGestureRecognizer:pinch];
    [self.view addGestureRecognizer:lp];

    self.screen = [[UIImageView alloc] initWithFrame:self.view.bounds];
    self.screen.contentMode = UIViewContentModeScaleAspectFit;
    self.screen.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.screen];

    _videoLayer = [AVSampleBufferDisplayLayer layer];
    _videoLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    _videoLayer.backgroundColor = [UIColor blackColor].CGColor;
    _videoLayer.frame = self.view.bounds;
    _videoLayer.hidden = YES;
    [self.view.layer addSublayer:_videoLayer];
    _waitKey = YES;

    self.status = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 30, 30)];
    self.status.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.status.textColor = [UIColor lightGrayColor];
    self.status.font = [UIFont systemFontOfSize:20];
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.numberOfLines = 0;
    [self.view addSubview:self.status];

    // Never dim / lock while acting as a monitor.
    [UIApplication sharedApplication].idleTimerDisabled = YES;

    // Playback category: sound keeps playing with the mute switch on and mixes with nothing else.
    NSError *sessErr = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&sessErr];
    [[AVAudioSession sharedInstance] setActive:YES error:&sessErr];

    _pending = [NSMutableData data];
    _freeBuffers = [NSMutableArray array];

    self.server = [[FrameServer alloc] initWithPort:kPort];
    self.server.delegate = self;
    NSError *err = nil;
    if (![self.server start:&err]) {
        self.status.text = [NSString stringWithFormat:@"Не удалось открыть порт %d: %@", kPort, err.localizedDescription];
        return;
    }
    [self showWaiting];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(showWaiting)
                                                 name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)showWaiting {
    if (self.screen.image) return;
    NSString *ip = [FrameServer wifiAddress] ?: @"нет Wi-Fi";
    self.status.hidden = NO;
    self.status.text = [NSString stringWithFormat:
        @"iPad Display\n\nОжидание компьютера…\n\n"
        @"Wi-Fi: iPad виден хосту автоматически (адрес %@, порт %d).\n"
        @"USB: подключите кабель, хост найдёт iPad через usbmuxd.", ip, kPort];
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

#pragma mark - touch -> host

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _videoLayer.frame = self.view.bounds;
    [CATransaction commit];
}

// Size of what is on screen: the video stream, or the last JPEG.
- (CGSize)contentSize {
    if (_videoActive && _videoSize.width > 0) return _videoSize;
    return self.screen.image ? self.screen.image.size : CGSizeZero;
}

// Rect of the displayed content inside the aspect-fit view.
- (CGRect)imageRect {
    CGSize v = self.screen.bounds.size, s = [self contentSize];
    if (s.width <= 0 || s.height <= 0) return CGRectZero;
    CGFloat k = MIN(v.width / s.width, v.height / s.height);
    CGFloat w = s.width * k, h = s.height * k;
    return CGRectMake((v.width - w) / 2, (v.height - h) / 2, w, h);
}

- (void)sendTouch:(UITouch *)t phase:(uint8_t)phase {
    CGRect r = [self imageRect];
    if (CGRectIsEmpty(r)) return;
    CGPoint p = [t locationInView:self.screen];
    CGFloat nx = (p.x - r.origin.x) / r.size.width, ny = (p.y - r.origin.y) / r.size.height;
    nx = MAX(0, MIN(1, nx)); ny = MAX(0, MIN(1, ny));
    [self.server sendTouchPhase:phase x:(uint16_t)(nx * 65535) y:(uint16_t)(ny * 65535)];
}

// One finger = mouse. As soon as a second finger lands, the mouse button is released and the
// gesture recognizers (two-finger pan = scroll, pinch = zoom) take over until all fingers lift.
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (event.allTouches.count >= 2) { if (_mouseDown) { [self sendTouch:_mouseTouch phase:2]; _mouseDown = NO; } _multi = YES; return; }
    if (_multi) return;
    _mouseTouch = touches.anyObject; _mouseDown = YES;
    [self sendTouch:_mouseTouch phase:0];
}
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_multi || !_mouseDown) return;
    if ([touches containsObject:_mouseTouch]) [self sendTouch:_mouseTouch phase:1];
}
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event { [self touchesDone:touches withEvent:event]; }
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event { [self touchesDone:touches withEvent:event]; }
- (void)touchesDone:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_mouseDown && [touches containsObject:_mouseTouch]) { [self sendTouch:_mouseTouch phase:2]; _mouseDown = NO; }
    // all fingers up -> leave multi mode
    NSUInteger still = 0;
    for (UITouch *t in event.allTouches) if (t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled) still++;
    if (still == 0) { _multi = NO; _mouseTouch = nil; }
}

// points on screen -> pixels of the transmitted frame
- (CGFloat)frameScale {
    CGRect r = [self imageRect];
    CGSize s = [self contentSize];
    return (r.size.width > 0 && s.width > 0) ? s.width / r.size.width : 1;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) { _lastPan = CGPointZero; return; }
    if (g.state != UIGestureRecognizerStateChanged) return;
    CGPoint t = [g translationInView:self.view];
    CGFloat k = [self frameScale];
    CGFloat dx = (t.x - _lastPan.x) * k, dy = (t.y - _lastPan.y) * k;
    _lastPan = t;
    if (fabs(dx) < 1 && fabs(dy) < 1) return;
    [self.server sendScrollDx:(int16_t)MAX(-32000, MIN(32000, dx)) dy:(int16_t)MAX(-32000, MIN(32000, dy))];
}

- (void)onPinch:(UIPinchGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) { _lastScale = 1.0; return; }
    if (g.state != UIGestureRecognizerStateChanged) return;
    CGFloat d = (g.scale - _lastScale) * 1000;
    if (fabs(d) < 10) return;
    _lastScale = g.scale;
    [self.server sendZoomDelta:(int16_t)MAX(-32000, MIN(32000, d))];
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGRect r = [self imageRect];
    if (CGRectIsEmpty(r)) return;
    CGPoint p = [g locationInView:self.screen];
    CGFloat nx = MAX(0, MIN(1, (p.x - r.origin.x) / r.size.width)), ny = MAX(0, MIN(1, (p.y - r.origin.y) / r.size.height));
    if (_mouseDown) { [self sendTouch:_mouseTouch phase:2]; _mouseDown = NO; }
    [self.server sendRightClickX:(uint16_t)(nx * 65535) y:(uint16_t)(ny * 65535)];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b { return YES; }

#pragma mark - FrameServerDelegate

- (void)frameServerDidConnect:(NSString *)peer {
    self.status.text = [NSString stringWithFormat:@"Подключено: %@\nОжидание изображения — нажмите «Старт» на компьютере.", peer];
}

- (void)frameServerDidDisconnect {
    self.screen.image = nil;
    [self stopAudio];
    [self stopVideo];
    [self showWaiting];
}

- (void)frameServerDidReceiveJPEG:(NSData *)jpeg done:(void (^)(void))done {
    // Decode on the background (read) queue so the main thread only blits.
    UIImage *raw = [UIImage imageWithData:jpeg];
    UIImage *decoded = raw;
    if (raw) {
        UIGraphicsBeginImageContextWithOptions(raw.size, YES, 1.0);
        [raw drawAtPoint:CGPointZero];
        decoded = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (decoded) {
            if (_videoActive) [self stopVideo];
            self.screen.image = decoded;
            self.status.hidden = YES;
        }
        // Ack after the frame is committed for display.
        dispatch_async(dispatch_get_main_queue(), ^{ done(); });
    });
}

#pragma mark - H.264 video (AVSampleBufferDisplayLayer)

static uint16_t be16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }

// avcC record: [0]=1 [1..3]=profile/compat/level [4]=0xFC|lengthSize-1 [5]=0xE0|numSPS, (u16 len, SPS)*, numPPS, (u16 len, PPS)*
- (void)frameServerDidReceiveVideoConfig:(NSData *)avcC {
    const uint8_t *p = avcC.bytes;
    NSUInteger n = avcC.length;
    if (n < 7 || p[0] != 1) return;
    NSUInteger i = 5;
    uint8_t numSPS = p[i++] & 0x1f;
    NSMutableArray *sets = [NSMutableArray array];
    for (uint8_t k = 0; k < numSPS && i + 2 <= n; k++) { uint16_t l = be16(p + i); i += 2; if (i + l > n) return; [sets addObject:[NSData dataWithBytes:p + i length:l]]; i += l; }
    if (i >= n) return;
    uint8_t numPPS = p[i++];
    for (uint8_t k = 0; k < numPPS && i + 2 <= n; k++) { uint16_t l = be16(p + i); i += 2; if (i + l > n) return; [sets addObject:[NSData dataWithBytes:p + i length:l]]; i += l; }
    if (sets.count < 2) return;

    const uint8_t *ptrs[8]; size_t sizes[8]; size_t cnt = MIN(sets.count, (NSUInteger)8);
    for (size_t k = 0; k < cnt; k++) { NSData *d = sets[k]; ptrs[k] = d.bytes; sizes[k] = d.length; }
    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, cnt, ptrs, sizes, 4, &fmt);
    if (st != noErr || !fmt) return;
    CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(fmt);
    // Runs on the serial read queue, same as the frames: no hop through the main thread.
    if (_videoFormat) CFRelease(_videoFormat);
    _videoFormat = fmt;
    _videoSize = CGSizeMake(dim.width, dim.height);
    [_videoLayer flush];
    _waitKey = YES;
}

// Called on the read queue. AVSampleBufferDisplayLayer accepts samples from any thread, so the frame goes
// straight from the socket to the decoder; only the first-frame UI switch touches the main thread.
- (void)frameServerDidReceiveVideoFrame:(NSData *)avcc keyframe:(BOOL)key pts:(uint32_t)ptsMs {
    if (!_videoFormat) { [self.server sendKeyframeRequest]; return; }
    if (_waitKey && !key) return;
    _waitKey = NO;
    if (_videoLayer.status == AVQueuedSampleBufferRenderingStatusFailed) { [_videoLayer flush]; _waitKey = YES; [self.server sendKeyframeRequest]; return; }

    CMBlockBufferRef block = NULL;
    size_t len = avcc.length;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, len, kCFAllocatorDefault, NULL, 0, len, 0, &block) != noErr) return;
    [avcc enumerateByteRangesUsingBlock:^(const void *bytes, NSRange range, BOOL *stop) { CMBlockBufferReplaceDataBytes(bytes, block, range.location, range.length); }];

    CMSampleBufferRef sample = NULL;
    CMSampleTimingInfo timing;
    timing.duration = CMTimeMake(1, 60);
    timing.presentationTimeStamp = CMTimeMake(ptsMs, 1000);
    timing.decodeTimeStamp = kCMTimeInvalid;
    size_t sampleSize = len;
    OSStatus st = CMSampleBufferCreate(kCFAllocatorDefault, block, true, NULL, NULL, _videoFormat, 1, 1, &timing, 1, &sampleSize, &sample);
    CFRelease(block);
    if (st != noErr || !sample) return;
    CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sample, true);
    if (att && CFArrayGetCount(att) > 0) {
        CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(att, 0);
        CFDictionarySetValue(d, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        if (!key) CFDictionarySetValue(d, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
    }
    if (!_videoActive) {
        _videoActive = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ _videoLayer.hidden = NO; self.screen.hidden = YES; self.status.hidden = YES; });
    }
    [_videoLayer enqueueSampleBuffer:sample];
    CFRelease(sample);
    [self.server sendPresented:ptsMs]; // latency probe: host compares with its clock
}

- (void)stopVideo {
    _videoActive = NO;
    _videoLayer.hidden = YES;
    self.screen.hidden = NO;
    [_videoLayer flush];
    _waitKey = YES;
}

#pragma mark - audio playback (AudioQueue, PCM s16le)

// Debug trail for the audio path, readable over SSH: /tmp/ipaddisplay.log
static void dbg(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
    NSString *path = @"/tmp/ipaddisplay.log";
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil]; h = [NSFileHandle fileHandleForWritingAtPath:path]; }
    if (!h) return;
    [h seekToEndOfFile];
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

static void AQOutputCallback(void *userData, AudioQueueRef q, AudioQueueBufferRef buf) {
    ViewController *vc = (__bridge ViewController *)userData;
    [vc audioBufferFree:buf fromQueue:q];
}

- (void)frameServerDidReceiveAudioFormat:(uint32_t)sampleRate channels:(uint8_t)channels {
    dispatch_async(dispatch_get_main_queue(), ^{
        dbg(@"audio format %u Hz %u ch (queue=%p)", (unsigned)sampleRate, (unsigned)channels, _queue);
        if (_queue && _rate == sampleRate && _channels == channels) return;
        [self stopAudio];
        _rate = sampleRate; _channels = channels ? channels : 1;
        AVAudioSession *sess = [AVAudioSession sharedInstance];
        NSError *se = nil;
        BOOL okCat = [sess setCategory:AVAudioSessionCategoryPlayback error:&se];
        BOOL okAct = [sess setActive:YES error:&se];
        dbg(@"session category=%d active=%d err=%@ volume=%.2f route=%@", okCat, okAct, se.localizedDescription, sess.outputVolume, sess.currentRoute.outputs.firstObject.portType);
        AudioStreamBasicDescription f;
        memset(&f, 0, sizeof(f));
        f.mSampleRate = sampleRate;
        f.mFormatID = kAudioFormatLinearPCM;
        f.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
        f.mChannelsPerFrame = _channels;
        f.mBitsPerChannel = 16;
        f.mBytesPerFrame = 2 * _channels;
        f.mFramesPerPacket = 1;
        f.mBytesPerPacket = f.mBytesPerFrame;
        OSStatus ns = AudioQueueNewOutput(&f, AQOutputCallback, (__bridge void *)self, NULL, NULL, 0, &_queue);
        if (ns != noErr) { dbg(@"AudioQueueNewOutput failed %d", (int)ns); _queue = NULL; return; }
        UInt32 bufBytes = (UInt32)(sampleRate / 10 * f.mBytesPerFrame); // 100 ms per buffer
        for (int i = 0; i < kAudioBuffers; i++) {
            OSStatus as = AudioQueueAllocateBuffer(_queue, bufBytes, &_buffers[i]);
            if (as == noErr) [_freeBuffers addObject:[NSValue valueWithPointer:_buffers[i]]];
            else dbg(@"AudioQueueAllocateBuffer %d failed %d", i, (int)as);
        }
        AudioQueueSetParameter(_queue, kAudioQueueParam_Volume, 1.0);
        _audioStarted = NO;
        dbg(@"queue ready, %lu buffers of %u bytes", (unsigned long)_freeBuffers.count, (unsigned)bufBytes);
    });
}

- (void)frameServerDidReceiveAudio:(NSData *)pcm {
    dispatch_async(dispatch_get_main_queue(), ^{
        static unsigned chunks = 0;
        chunks++;
        if (chunks == 1 || chunks % 200 == 0) dbg(@"audio chunk #%u (%lu bytes) queue=%p pending=%lu free=%lu started=%d", chunks, (unsigned long)pcm.length, _queue, (unsigned long)_pending.length, (unsigned long)_freeBuffers.count, _audioStarted);
        if (!_queue) return;
        [_pending appendData:pcm];
        [self pumpAudio];
    });
}

- (void)audioBufferFree:(AudioQueueBufferRef)buf fromQueue:(AudioQueueRef)q {
    // called on the AudioQueue thread; a buffer from a queue that was already replaced must not be reused
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_queue || q != _queue) return;
        [_freeBuffers addObject:[NSValue valueWithPointer:buf]];
        [self pumpAudio];
    });
}

- (void)pumpAudio {
    NSUInteger halfSecond = (NSUInteger)_rate * _channels; // bytes: rate*2*ch/2
    // keep latency bounded: if more than ~1 s piled up, drop down to half a second
    if (_pending.length > halfSecond * 2) [_pending replaceBytesInRange:NSMakeRange(0, _pending.length - halfSecond) withBytes:NULL length:0];
    while (_freeBuffers.count && _pending.length) {
        AudioQueueBufferRef buf = [_freeBuffers.lastObject pointerValue];
        NSUInteger n = MIN((NSUInteger)buf->mAudioDataBytesCapacity, _pending.length);
        [_pending getBytes:buf->mAudioData range:NSMakeRange(0, n)];
        buf->mAudioDataByteSize = (UInt32)n;
        [_pending replaceBytesInRange:NSMakeRange(0, n) withBytes:NULL length:0];
        [_freeBuffers removeLastObject];
        OSStatus es = AudioQueueEnqueueBuffer(_queue, buf, 0, NULL);
        if (es != noErr) { dbg(@"AudioQueueEnqueueBuffer failed %d (buffer dropped)", (int)es); continue; } // never put a rejected buffer back
        if (!_audioStarted && _freeBuffers.count <= kAudioBuffers - 3) { OSStatus ss = AudioQueueStart(_queue, NULL); _audioStarted = YES; dbg(@"AudioQueueStart -> %d", (int)ss); }
    }
}

- (void)stopAudio {
    if (!_queue) return;
    AudioQueueStop(_queue, true);
    AudioQueueDispose(_queue, true);
    _queue = NULL;
    [_freeBuffers removeAllObjects];
    _pending.length = 0;
    _audioStarted = NO;
}

@end
