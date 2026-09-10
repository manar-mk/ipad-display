#import <Foundation/Foundation.h>

// Listens on a TCP port for the host (ipad-display Electron app).
// Wire protocol: [4-byte big-endian length][JPEG bytes] ... ; after each displayed
// frame the device writes one byte (0x01) back as an ack. The host never sends the
// next frame before the ack, so a slow iPad simply gets a lower frame rate.
//
// Transport: USB via usbmuxd (host runs `iproxy 7801 7801`) or plain Wi-Fi (host
// connects to this iPad's IP). The app does not care which one.

@protocol FrameServerDelegate <NSObject>
- (void)frameServerDidConnect:(NSString *)peer;
- (void)frameServerDidDisconnect;
// Called on a background queue. Call `done` once the frame is on screen so the ack is sent.
- (void)frameServerDidReceiveJPEG:(NSData *)jpeg done:(void (^)(void))done;
@end

@interface FrameServer : NSObject
@property (nonatomic, weak) id<FrameServerDelegate> delegate;
@property (nonatomic, readonly) uint16_t port;
- (instancetype)initWithPort:(uint16_t)port;
- (BOOL)start:(NSError **)error;
- (void)stop;
+ (NSString *)wifiAddress; // IPv4 of en0, or nil
@end
