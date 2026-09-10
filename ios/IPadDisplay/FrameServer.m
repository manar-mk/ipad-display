#import "FrameServer.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <unistd.h>
#import <errno.h>

static const uint32_t kMaxMessageBytes = 16 * 1024 * 1024;
static const uint16_t kBeaconPort = 7802;

@implementation FrameServer {
    int _listenFd;
    int _clientFd;
    int _beaconFd;
    dispatch_queue_t _acceptQueue;
    dispatch_queue_t _readQueue;
    dispatch_queue_t _writeQueue;
    dispatch_source_t _acceptSource;
    dispatch_source_t _beaconTimer;
    BOOL _running;
}

- (instancetype)initWithPort:(uint16_t)port {
    if ((self = [super init])) {
        _port = port;
        _listenFd = -1;
        _clientFd = -1;
        _beaconFd = -1;
        _acceptQueue = dispatch_queue_create("ipaddisplay.accept", DISPATCH_QUEUE_SERIAL);
        _readQueue = dispatch_queue_create("ipaddisplay.read", DISPATCH_QUEUE_SERIAL);
        _writeQueue = dispatch_queue_create("ipaddisplay.write", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)start:(NSError **)error {
    if (_running) return YES;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return [self fail:error];
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_len = sizeof(addr);
    addr.sin_port = htons(_port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); return [self fail:error]; }
    if (listen(fd, 2) < 0) { close(fd); return [self fail:error]; }

    _listenFd = fd;
    _running = YES;

    __weak FrameServer *weakSelf = self;
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, _acceptQueue);
    dispatch_source_set_event_handler(_acceptSource, ^{ [weakSelf acceptOne]; });
    dispatch_resume(_acceptSource);

    [self startBeacon];
    return YES;
}

- (BOOL)fail:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{NSLocalizedDescriptionKey: @(strerror(errno))}];
    return NO;
}

- (void)stop {
    _running = NO;
    if (_acceptSource) { dispatch_source_cancel(_acceptSource); _acceptSource = nil; }
    if (_beaconTimer) { dispatch_source_cancel(_beaconTimer); _beaconTimer = nil; }
    if (_listenFd >= 0) { close(_listenFd); _listenFd = -1; }
    if (_beaconFd >= 0) { close(_beaconFd); _beaconFd = -1; }
    [self dropClient];
}

- (void)dropClient {
    int fd = _clientFd;
    _clientFd = -1;
    if (fd >= 0) { shutdown(fd, SHUT_RDWR); close(fd); }
}

#pragma mark - LAN discovery beacon

- (void)startBeacon {
    _beaconFd = socket(AF_INET, SOCK_DGRAM, 0);
    if (_beaconFd < 0) return;
    int yes = 1;
    setsockopt(_beaconFd, SOL_SOCKET, SO_BROADCAST, &yes, sizeof(yes));
    __weak FrameServer *weakSelf = self;
    _beaconTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _acceptQueue);
    dispatch_source_set_timer(_beaconTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(_beaconTimer, ^{ [weakSelf sendBeacon]; });
    dispatch_resume(_beaconTimer);
}

- (void)sendBeacon {
    if (_beaconFd < 0 || _clientFd >= 0) return; // silent while a host is connected
    NSString *msg = [NSString stringWithFormat:@"IPADDISPLAY %u", (unsigned)_port];
    const char *bytes = msg.UTF8String;
    struct sockaddr_in to;
    memset(&to, 0, sizeof(to));
    to.sin_family = AF_INET;
    to.sin_len = sizeof(to);
    to.sin_port = htons(kBeaconPort);
    to.sin_addr.s_addr = htonl(INADDR_BROADCAST);
    sendto(_beaconFd, bytes, (size_t)msg.length, 0, (struct sockaddr *)&to, sizeof(to));
}

#pragma mark - connection

- (void)acceptOne {
    struct sockaddr_in peer;
    socklen_t len = sizeof(peer);
    int fd = accept(_listenFd, (struct sockaddr *)&peer, &len);
    if (fd < 0) return;

    int yes = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));

    // one host at a time: a new connection replaces the old one
    [self dropClient];
    _clientFd = fd;

    NSString *peerStr = [NSString stringWithFormat:@"%s:%d", inet_ntoa(peer.sin_addr), ntohs(peer.sin_port)];
    id<FrameServerDelegate> d = self.delegate;
    dispatch_async(dispatch_get_main_queue(), ^{ [d frameServerDidConnect:peerStr]; });

    dispatch_async(_readQueue, ^{ [self readLoop:fd]; });
}

// Blocking read of exactly `n` bytes. Returns NO on EOF/error.
static BOOL readFully(int fd, void *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = recv(fd, (char *)buf + got, n - got, 0);
        if (r == 0) return NO;
        if (r < 0) { if (errno == EINTR) continue; return NO; }
        got += (size_t)r;
    }
    return YES;
}

- (void)writeBytes:(const void *)bytes length:(size_t)len toFd:(int)fd {
    NSData *copy = [NSData dataWithBytes:bytes length:len];
    dispatch_async(_writeQueue, ^{
        if (_clientFd != fd) return;
        const uint8_t *p = copy.bytes;
        size_t left = copy.length;
        while (left > 0) {
            ssize_t w = send(fd, p, left, 0);
            if (w <= 0) { if (w < 0 && errno == EINTR) continue; return; }
            p += w; left -= (size_t)w;
        }
    });
}

- (void)sendTouchPhase:(uint8_t)phase x:(uint16_t)x y:(uint16_t)y {
    int fd = _clientFd;
    if (fd < 0) return;
    uint8_t msg[6] = { 'T', phase, (uint8_t)(x >> 8), (uint8_t)(x & 0xff), (uint8_t)(y >> 8), (uint8_t)(y & 0xff) };
    [self writeBytes:msg length:sizeof(msg) toFd:fd];
}

- (void)readLoop:(int)fd {
    uint8_t header[4];
    NSMutableData *body = [NSMutableData data];
    while (_running && _clientFd == fd) {
        if (!readFully(fd, header, 4)) break;
        uint32_t len = ((uint32_t)header[0] << 24) | ((uint32_t)header[1] << 16) | ((uint32_t)header[2] << 8) | header[3];
        if (len == 0 || len > kMaxMessageBytes) break;
        body.length = len;
        if (!readFully(fd, body.mutableBytes, len)) break;

        const uint8_t *p = body.bytes;
        uint8_t type = p[0];
        id<FrameServerDelegate> d = self.delegate;
        if (type == 'J') {
            NSData *jpeg = [body subdataWithRange:NSMakeRange(1, len - 1)];
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [d frameServerDidReceiveJPEG:jpeg done:^{ dispatch_semaphore_signal(sem); }];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            uint8_t ack = 1;
            [self writeBytes:&ack length:1 toFd:fd];
        } else if (type == 'F' && len >= 6) {
            uint32_t rate = ((uint32_t)p[1] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 8) | p[4];
            [d frameServerDidReceiveAudioFormat:rate channels:p[5]];
        } else if (type == 'A' && len > 1) {
            [d frameServerDidReceiveAudio:[body subdataWithRange:NSMakeRange(1, len - 1)]];
        }
    }
    if (_clientFd == fd) {
        [self dropClient];
        id<FrameServerDelegate> d = self.delegate;
        dispatch_async(dispatch_get_main_queue(), ^{ [d frameServerDidDisconnect]; });
    }
}

+ (NSString *)wifiAddress {
    NSString *result = nil;
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) == 0) {
        for (struct ifaddrs *p = list; p; p = p->ifa_next) {
            if (p->ifa_addr && p->ifa_addr->sa_family == AF_INET && [@(p->ifa_name) isEqualToString:@"en0"]) {
                result = @(inet_ntoa(((struct sockaddr_in *)p->ifa_addr)->sin_addr));
                break;
            }
        }
        freeifaddrs(list);
    }
    return result;
}

@end
