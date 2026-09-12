#import "ViewController.h"
#import "FrameServer.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

// UI language: Russian when the iPad is set to Russian, English otherwise.
static NSString *L(NSString *ru, NSString *en) {
    NSString *lang = [[NSLocale preferredLanguages] firstObject] ?: @"en";
    return [lang hasPrefix:@"ru"] ? ru : en;
}

static const uint16_t kPort = 7801;
static const int kAudioBuffers = 6;

@interface ViewController () <FrameServerDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIImageView *screen;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) FrameServer *server;
// called from the AudioQueue C callbacks below
- (void)audioBufferFree:(AudioQueueBufferRef)buf fromQueue:(AudioQueueRef)q;
- (void)fillSilence:(AudioQueueBufferRef)buf;
@end

@implementation ViewController {
    // host selection: hosts seen on the LAN (ip -> name), the connected peer, the picker button
    NSMutableDictionary *_hosts;
    NSString *_peerIp;
    UIButton *_hostBtn;
    UIImageView *_logo;
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
    // keep-alive: a silent stream so iOS keeps the app (and its listening socket) running in the background
    AudioQueueRef _kaQueue;
    NSMutableData *_kaSilence; // zero-filled once: the SDK we link against has no _memset
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

    // waiting screen: the app icon above the status text
    _logo = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"Icon-152"]];
    _logo.frame = CGRectMake(0, 0, 104, 104);
    _logo.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds) - 120);
    _logo.layer.cornerRadius = 23; _logo.layer.masksToBounds = YES;
    _logo.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                           | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:_logo];

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
    // Done off the main thread on purpose — see startKeepAlive.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *sessErr = nil;
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&sessErr];
        [[AVAudioSession sharedInstance] setActive:YES error:&sessErr];
        [self startKeepAlive];
    });

    _pending = [NSMutableData data];
    _freeBuffers = [NSMutableArray array];
    _hosts = [NSMutableDictionary dictionary];

    // host picker: a button on the waiting screen, and a three-finger tap at any time
    _hostBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _hostBtn.frame = CGRectMake(20, 20, 320, 36);
    _hostBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    _hostBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [_hostBtn addTarget:self action:@selector(showHostPicker) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_hostBtn];
    UITapGestureRecognizer *three = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showHostPicker)];
    three.numberOfTouchesRequired = 3; three.cancelsTouchesInView = NO; three.delegate = self;
    [self.view addGestureRecognizer:three];

    self.server = [[FrameServer alloc] initWithPort:kPort];
    self.server.delegate = self;
    self.server.preferredHost = [[NSUserDefaults standardUserDefaults] stringForKey:@"preferredHost"];
    [self updateHostButton];
    NSError *err = nil;
    if (![self.server start:&err]) {
        self.status.text = [NSString stringWithFormat:L(@"Не удалось открыть порт %d: %@", @"Could not open port %d: %@"), kPort, err.localizedDescription];
        return;
    }
    [self showWaiting];

    // mediaserverd can be restarted under us; every AudioQueue made before that keeps reporting itself as
    // running, with its sample clock advancing, while rendering into nothing. Rebuild everything when iOS says so.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mediaServicesReset)
                                                 name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(showWaiting)
                                                 name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)showWaiting {
    if (_peerIp) return; // a host is on the line: leave its picture alone
    // The video layer keeps its last (black) frame on top of everything, so take it down explicitly —
    // otherwise coming back from the background shows a black screen instead of this one.
    if (_videoActive) [self stopVideo];
    _videoLayer.hidden = YES;
    self.screen.image = nil;
    self.screen.hidden = NO;
    NSString *ip = [FrameServer wifiAddress] ?: L(@"нет Wi-Fi", @"no Wi-Fi");
    NSString *pref = self.server.preferredHost;
    self.status.hidden = NO; _logo.hidden = NO;
    NSString *who = pref.length
        ? [NSString stringWithFormat:L(@"Показывается только хост %@ (и любой по USB).", @"Only host %@ is shown (plus anything over USB)."), [self hostLabel:pref]]
        : L(@"Принимается любой хост.", @"Any host is accepted.");
    self.status.text = [NSString stringWithFormat:
        L(@"iPad Display\n\nОжидание компьютера…\n\n"
          @"Wi-Fi: хост находит iPad сам (адрес %@, порт %d).\n"
          @"USB: подключите кабель — хост найдёт iPad сам.\n\n"
          @"%@ Сменить: кнопка вверху или тап тремя пальцами.",
          @"iPad Display\n\nWaiting for a computer…\n\n"
          @"Wi-Fi: the host finds this iPad by itself (address %@, port %d).\n"
          @"USB: plug the cable in — the host finds the iPad by itself.\n\n"
          @"%@ To change: the button above or a three-finger tap."),
        ip, kPort, who];
    [self updateHostButton];
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

#pragma mark - host selection

- (NSString *)hostLabel:(NSString *)ip { NSString *n = _hosts[ip]; return n.length ? [NSString stringWithFormat:@"%@ (%@)", n, ip] : ip; }

- (void)updateHostButton {
    NSString *pref = self.server.preferredHost;
    NSString *t = pref.length ? [NSString stringWithFormat:L(@"Хост: %@ ▾", @"Host: %@ ▾"), [self hostLabel:pref]] : L(@"Хост: любой ▾", @"Host: any ▾");
    [_hostBtn setTitle:t forState:UIControlStateNormal];
    _hostBtn.hidden = _videoActive || self.screen.image != nil;
}

- (void)frameServerDidSeeHost:(NSString *)name address:(NSString *)ip {
    if (![_hosts[ip] isEqualToString:name]) { _hosts[ip] = name; [self updateHostButton]; }
}

- (void)frameServerDidReceiveHostName:(NSString *)name {
    if (_peerIp.length && ![_peerIp isEqualToString:@"127.0.0.1"]) { _hosts[_peerIp] = name; [self updateHostButton]; }
    if (!self.status.hidden) self.status.text = [NSString stringWithFormat:L(@"Подключено: %@\nОжидание изображения…", @"Connected: %@\nWaiting for the picture…"), [self hostLabel:_peerIp ?: @""]];
}

- (void)choosePreferredHost:(NSString *)ip {
    self.server.preferredHost = ip;
    if (ip.length) [[NSUserDefaults standardUserDefaults] setObject:ip forKey:@"preferredHost"];
    else [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"preferredHost"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    // connected to someone else over Wi-Fi? drop them so the chosen host can take over
    if (ip.length && _peerIp.length && ![_peerIp isEqualToString:ip] && ![_peerIp isEqualToString:@"127.0.0.1"]) [self.server disconnectClient];
    [self updateHostButton];
    [self showWaiting];
}

- (void)showHostPicker {
    if (self.presentedViewController) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:L(@"Какой компьютер показывать", @"Which computer to show")
        message:L(@"USB-подключение принимается всегда. По Wi-Fi — только выбранный хост.", @"USB is always accepted. Over Wi-Fi, only the chosen host is.")
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *pref = self.server.preferredHost;
    [ac addAction:[UIAlertAction actionWithTitle:(pref.length ? L(@"Любой хост", @"Any host") : L(@"✓ Любой хост", @"✓ Any host")) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self choosePreferredHost:nil]; }]];
    NSArray *ips = [_hosts.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *ip in ips) {
        NSString *title = [NSString stringWithFormat:@"%@%@", [ip isEqualToString:pref] ? @"✓ " : @"", [self hostLabel:ip]];
        [ac addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self choosePreferredHost:ip]; }]];
    }
    if (!ips.count) [ac addAction:[UIAlertAction actionWithTitle:L(@"(хосты в сети не найдены — запустите хост)", @"(no hosts on the network — start the host app)") style:UIAlertActionStyleDefault handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:L(@"Отмена", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.view;
    ac.popoverPresentationController.sourceRect = _hostBtn.hidden ? CGRectMake(self.view.bounds.size.width / 2, 40, 1, 1) : _hostBtn.frame;
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - FrameServerDelegate

- (void)frameServerDidConnect:(NSString *)peer {
    _peerIp = [[peer componentsSeparatedByString:@":"] firstObject];
    self.status.text = [NSString stringWithFormat:L(@"Подключено: %@\nОжидание изображения…", @"Connected: %@\nWaiting for the picture…"), [self hostLabel:_peerIp]];
}

- (void)frameServerDidDisconnect {
    _peerIp = nil;
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
            self.status.hidden = YES; _logo.hidden = YES;
            _hostBtn.hidden = YES;
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
        dispatch_async(dispatch_get_main_queue(), ^{ _videoLayer.hidden = NO; self.screen.hidden = YES; self.status.hidden = YES; _logo.hidden = YES; _hostBtn.hidden = YES; });
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

// ---- keep-alive ----------------------------------------------------------
// iOS suspends a backgrounded app within seconds and closes its sockets, so the host could no longer
// reach us after a tap on Home or a lock. With UIBackgroundModes=audio the app keeps running as long as
// it is playing something, so we always play silence: two 0.5 s buffers of zeros, re-queued forever.
// Called from a background queue: every AudioQueue call here goes to mediaserverd, and a wedged
// mediaserverd would otherwise freeze the launch.
static void AQKeepAliveCallback(void *userData, AudioQueueRef q, AudioQueueBufferRef buf) {
    ViewController *vc = (__bridge ViewController *)userData;
    [vc fillSilence:buf];
    AudioQueueEnqueueBuffer(q, buf, 0, NULL);
}

- (void)fillSilence:(AudioQueueBufferRef)buf {
    UInt32 n = buf->mAudioDataBytesCapacity;
    if (_kaSilence.length < n) {
        // Not digital zero: a +-1 LSB dither, about -90 dBFS and inaudible, but a real signal. Feeding the
        // output pure silence for minutes lets the speaker amplifier idle, and the audio that arrives
        // afterwards stays inaudible until something else (a system sound) wakes the hardware again.
        _kaSilence = [NSMutableData dataWithLength:n];
        SInt16 *p = (SInt16 *)_kaSilence.mutableBytes;
        for (NSUInteger i = 0; i < n / 2; i++) p[i] = (i & 1) ? 1 : -1;
    }
    [_kaSilence getBytes:buf->mAudioData length:n];
    buf->mAudioDataByteSize = n;
}

- (void)startKeepAlive {
    if (_kaQueue) return;
    AudioStreamBasicDescription f;
    f.mReserved = 0;
    f.mSampleRate = 8000;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    f.mChannelsPerFrame = 1;
    f.mBitsPerChannel = 16;
    f.mBytesPerFrame = 2;
    f.mFramesPerPacket = 1;
    f.mBytesPerPacket = 2;
    OSStatus ns = AudioQueueNewOutput(&f, AQKeepAliveCallback, (__bridge void *)self, NULL, NULL, 0, &_kaQueue);
    if (ns != noErr) { dbg(@"keep-alive queue failed %d", (int)ns); _kaQueue = NULL; return; }
    // Volume 1.0, not 0.0: the buffers are already zero-filled, so this is just as silent, and a second
    // queue sitting at volume zero was silencing the queue that carries the host audio on iOS 9.
    AudioQueueSetParameter(_kaQueue, kAudioQueueParam_Volume, 1.0);
    for (int i = 0; i < 2; i++) {
        AudioQueueBufferRef b = NULL;
        if (AudioQueueAllocateBuffer(_kaQueue, 8000, &b) != noErr) continue;
        AQKeepAliveCallback((__bridge void *)self, _kaQueue, b);
    }
    OSStatus st = AudioQueueStart(_kaQueue, NULL);
    dbg(@"keep-alive silence started (%d)", (int)st);
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
        // off the main thread: these are synchronous calls into mediaserverd (see startKeepAlive)
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            AVAudioSession *sess = [AVAudioSession sharedInstance];
            NSError *se = nil;
            BOOL okCat = [sess setCategory:AVAudioSessionCategoryPlayback error:&se];
            BOOL okAct = [sess setActive:YES error:&se];
            dbg(@"session category=%d active=%d err=%@ volume=%.2f route=%@", okCat, okAct, se.localizedDescription, sess.outputVolume, sess.currentRoute.outputs.firstObject.portType);
        });
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
        if (chunks % 20 == 0) [self maybeSelfTest];
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

// ---- self test -----------------------------------------------------------
// Is the device still able to make a sound at all? `touch /tmp/ipaddisplay.selftest` over SSH and the app
// plays one second of 440 Hz through the very same queue the host audio uses, then reports the queue clock:
// a wedged mediaserverd accepts and returns buffers happily while never advancing it, so the sample time
// standing still is the proof that nothing is being rendered.
- (void)maybeSelfTest {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:@"/tmp/ipaddisplay.selftest"]) return;
    [fm removeItemAtPath:@"/tmp/ipaddisplay.selftest" error:nil];
    if (!_queue) { dbg(@"self test: no audio queue yet"); return; }
    NSUInteger frames = _rate; // one second
    NSMutableData *tone = [NSMutableData dataWithLength:frames * 2 * _channels];
    SInt16 *out = (SInt16 *)tone.mutableBytes;
    for (NSUInteger i = 0; i < frames; i++) {
        SInt16 v = (SInt16)(12000.0 * sin(2.0 * M_PI * 440.0 * (double)i / (double)_rate));
        for (int ch = 0; ch < _channels; ch++) out[i * _channels + ch] = v;
    }
    // Two independent probes, because "the app renders nothing" and "the device makes no sound" look identical
    // from the host: the tone goes through our AudioQueue, the system sound bypasses it entirely.
    AVAudioSession *sess = [AVAudioSession sharedInstance];
    dbg(@"self test: category=%@ volume=%.2f route=%@ keepAlive=%p mainQueue=%p",
        sess.category, sess.outputVolume, sess.currentRoute.outputs.firstObject.portType, _kaQueue, _queue);
    AudioServicesPlaySystemSound(1007);
    dbg(@"self test: system sound 1007 fired (bypasses our AudioQueue)");
    dbg(@"self test: playing 1 s of 440 Hz (%lu bytes) through the host audio queue", (unsigned long)tone.length);
    [_pending appendData:tone];
    [self pumpAudio];
    [self performSelector:@selector(reportQueueClock) withObject:nil afterDelay:2.0];
}

- (void)reportQueueClock {
    if (!_queue) return;
    AudioTimeStamp ts;
    ts.mSampleTime = -1;
    OSStatus st = AudioQueueGetCurrentTime(_queue, NULL, &ts, NULL);
    UInt32 running = 0, sz = sizeof(running);
    OSStatus rs = AudioQueueGetProperty(_queue, kAudioQueueProperty_IsRunning, &running, &sz);
    dbg(@"queue clock: getTime=%d sampleTime=%.0f isRunning=%u (rs=%d); it must grow by ~%u every second",
        (int)st, ts.mSampleTime, (unsigned)running, (int)rs, (unsigned)_rate);
}

- (void)mediaServicesReset {
    dispatch_async(dispatch_get_main_queue(), ^{
        dbg(@"media services were reset - rebuilding both audio queues");
        uint32_t r = _rate; uint8_t ch = _channels;
        [self stopAudio];
        if (_kaQueue) { AudioQueueStop(_kaQueue, true); AudioQueueDispose(_kaQueue, true); _kaQueue = NULL; }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError *e = nil;
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&e];
            [[AVAudioSession sharedInstance] setActive:YES error:&e];
            [self startKeepAlive];
            if (r) dispatch_async(dispatch_get_main_queue(), ^{ [self frameServerDidReceiveAudioFormat:r channels:ch]; });
        });
    });
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
