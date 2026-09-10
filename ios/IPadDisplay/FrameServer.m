#import "FrameServer.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <unistd.h>
#import <errno.h>

static const uint32_t kMaxFrameBytes = 16 * 1024 * 1024;

@implementation FrameServer {
    int _listenFd;
    int _clientFd;
    dispatch_queue_t _acceptQueue;
    dispatch_queue_t _readQueue;
    dispatch_source_t _acceptSource;
    BOOL _running;
}

- (instancetype)initWithPort:(uint16_t)port {
    if ((self = [super init])) {
        _port = port;
        _listenFd = -1;
        _clientFd = -1;
        _acceptQueue = dispatch_queue_create("ipaddisplay.accept", DISPATCH_QUEUE_SERIAL);
        _readQueue = dispatch_queue_create("ipaddisplay.read", DISPATCH_QUEUE_SERIAL);
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
    return YES;
}

- (BOOL)fail:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{NSLocalizedDescriptionKey: @(strerror(errno))}];
    return NO;
}

- (void)stop {
    _running = NO;
    if (_acceptSource) { dispatch_source_cancel(_acceptSource); _acceptSource = nil; }
    if (_listenFd >= 0) { close(_listenFd); _listenFd = -1; }
    [self dropClient];
}

- (void)dropClient {
    int fd = _clientFd;
    _clientFd = -1;
    if (fd >= 0) { shutdown(fd, SHUT_RDWR); close(fd); }
}

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

- (void)readLoop:(int)fd {
    uint8_t header[4];
    NSMutableData *frame = [NSMutableData data];
    while (_running && _clientFd == fd) {
        if (!readFully(fd, header, 4)) break;
        uint32_t len = ((uint32_t)header[0] << 24) | ((uint32_t)header[1] << 16) | ((uint32_t)header[2] << 8) | header[3];
        if (len == 0 || len > kMaxFrameBytes) break;
        frame.length = len;
        if (!readFully(fd, frame.mutableBytes, len)) break;

        // Hand the frame to the delegate; wait until it is on screen, then ack.
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        NSData *copy = [frame copy];
        [self.delegate frameServerDidReceiveJPEG:copy done:^{ dispatch_semaphore_signal(sem); }];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

        uint8_t ack = 1;
        if (send(fd, &ack, 1, 0) != 1) break;
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
