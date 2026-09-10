#import "ViewController.h"
#import "FrameServer.h"

static const uint16_t kPort = 7801;

@interface ViewController () <FrameServerDelegate>
@property (nonatomic, strong) UIImageView *screen;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) FrameServer *server;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

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
        @"USB: на компьютере запустите  iproxy %d %d  и нажмите «Подключить» (хост 127.0.0.1).\n\n"
        @"Wi-Fi: в панели укажите хост %@, порт %d.", kPort, kPort, ip, kPort];
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

#pragma mark - FrameServerDelegate

- (void)frameServerDidConnect:(NSString *)peer {
    self.status.text = [NSString stringWithFormat:@"Подключено: %@\nОжидание изображения — нажмите «Старт» на компьютере.", peer];
}

- (void)frameServerDidDisconnect {
    self.screen.image = nil;
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

@end
