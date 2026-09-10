#import "ViewController.h"
#import "FrameServer.h"
#import <AudioToolbox/AudioToolbox.h>

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

    self.status = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 30, 30)];
    self.status.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.status.textColor = [UIColor lightGrayColor];
    self.status.font = [UIFont systemFontOfSize:20];
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.numberOfLines = 0;
    [self.view addSubview:self.status];

    // Never dim / lock while acting as a monitor.
    [UIApplication sharedApplication].idleTimerDisabled = YES;

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

// Rect of the displayed image inside the aspect-fit image view.
- (CGRect)imageRect {
    UIImage *img = self.screen.image;
    if (!img) return CGRectZero;
    CGSize v = self.screen.bounds.size, s = img.size;
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
    return (r.size.width > 0 && self.screen.image) ? self.screen.image.size.width / r.size.width : 1;
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
            self.screen.image = decoded;
            self.status.hidden = YES;
        }
        // Ack after the frame is committed for display.
        dispatch_async(dispatch_get_main_queue(), ^{ done(); });
    });
}

#pragma mark - audio playback (AudioQueue, PCM s16le)

static void AQOutputCallback(void *userData, AudioQueueRef q, AudioQueueBufferRef buf) {
    ViewController *vc = (__bridge ViewController *)userData;
    [vc audioBufferFree:buf];
}

- (void)frameServerDidReceiveAudioFormat:(uint32_t)sampleRate channels:(uint8_t)channels {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_queue && _rate == sampleRate && _channels == channels) return;
        [self stopAudio];
        _rate = sampleRate; _channels = channels ? channels : 1;
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
        if (AudioQueueNewOutput(&f, AQOutputCallback, (__bridge void *)self, NULL, NULL, 0, &_queue) != noErr) { _queue = NULL; return; }
        UInt32 bufBytes = (UInt32)(sampleRate / 10 * f.mBytesPerFrame); // 100 ms per buffer
        for (int i = 0; i < kAudioBuffers; i++) {
            if (AudioQueueAllocateBuffer(_queue, bufBytes, &_buffers[i]) == noErr)
                [_freeBuffers addObject:[NSValue valueWithPointer:_buffers[i]]];
        }
        _audioStarted = NO;
    });
}

- (void)frameServerDidReceiveAudio:(NSData *)pcm {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_queue) return;
        [_pending appendData:pcm];
        [self pumpAudio];
    });
}

- (void)audioBufferFree:(AudioQueueBufferRef)buf {
    // called on the AudioQueue thread
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_queue) return;
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
        if (AudioQueueEnqueueBuffer(_queue, buf, 0, NULL) != noErr) { [_freeBuffers addObject:[NSValue valueWithPointer:buf]]; break; }
        if (!_audioStarted && _freeBuffers.count <= kAudioBuffers - 3) { AudioQueueStart(_queue, NULL); _audioStarted = YES; }
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
