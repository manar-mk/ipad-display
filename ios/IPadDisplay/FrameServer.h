#import <Foundation/Foundation.h>

// Listens on a TCP port for the host (ipad-display Electron app) and announces itself on the LAN.
//
// Wire protocol, host -> device: [uint32 BE length][uint8 type][payload]
//   'J'  JPEG frame (device answers with an ack byte 0x01 once it is on screen)
//   'F'  audio format: [uint32 BE sampleRate][uint8 channels]   (PCM s16le follows in 'A')
//   'A'  audio PCM chunk (s16le interleaved)
// Device -> host: [uint8 type][payload]
//   0x01 frame ack
//   'T'  touch: [uint8 phase 0=down 1=move 2=up][uint16 BE x][uint16 BE y]  (x,y in 0..65535 of the frame)
// Discovery: every 2 s the device broadcasts UDP "IPADDISPLAY <tcpPort>" to 255.255.255.255:7802.
//
// Transport: USB via usbmuxd or plain Wi-Fi; the app does not care which.

@protocol FrameServerDelegate <NSObject>
- (void)frameServerDidConnect:(NSString *)peer;
- (void)frameServerDidDisconnect;
// Called on a background queue. Call `done` once the frame is on screen so the ack is sent.
- (void)frameServerDidReceiveJPEG:(NSData *)jpeg done:(void (^)(void))done;
- (void)frameServerDidReceiveAudioFormat:(uint32_t)sampleRate channels:(uint8_t)channels;
- (void)frameServerDidReceiveAudio:(NSData *)pcm;
@end

@interface FrameServer : NSObject
@property (nonatomic, weak) id<FrameServerDelegate> delegate;
@property (nonatomic, readonly) uint16_t port;
- (instancetype)initWithPort:(uint16_t)port;
- (BOOL)start:(NSError **)error;
- (void)stop;
- (void)sendTouchPhase:(uint8_t)phase x:(uint16_t)x y:(uint16_t)y;
+ (NSString *)wifiAddress; // IPv4 of en0, or nil
@end
