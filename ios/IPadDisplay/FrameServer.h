#import <Foundation/Foundation.h>

// Listens on a TCP port for the host (ipad-display Electron app) and announces itself on the LAN.
//
// Wire protocol, host -> device: [uint32 BE length][uint8 type][payload]
//   'J'  JPEG frame (device answers with an ack byte 0x01 once it is on screen)
//   'F'  audio format: [uint32 BE sampleRate][uint8 channels]   (PCM s16le follows in 'A')
//   'A'  audio PCM chunk (s16le interleaved)
//   'H'  H.264 decoder config: avcC record (SPS/PPS), sent before the first video frame
//   'V'  H.264 frame: [uint8 flags bit0=keyframe][uint32 BE pts ms][AVCC NAL units, 4-byte length prefixed]
// Device -> host: [uint8 type][payload]
//   0x01 frame ack
//   'T'  touch: [uint8 phase 0=down 1=move 2=up][uint16 BE x][uint16 BE y]  (x,y in 0..65535 of the frame)
//   'S'  two-finger scroll: [int16 BE dx][int16 BE dy]  (points on the frame, positive = content moves right/down)
//   'Z'  pinch: [int16 BE delta]  (delta of scale*1000 since the last message; >0 zoom in)
//   'R'  right click (long press): [uint16 BE x][uint16 BE y]
//   'K'  please send a keyframe (decoder lost sync)
//   'P'  presented: [uint32 BE pts ms] of the video frame just handed to the display (latency probe)
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
// H.264: avcC record, then AVCC frames. Both called on the read queue.
- (void)frameServerDidReceiveVideoConfig:(NSData *)avcC;
- (void)frameServerDidReceiveVideoFrame:(NSData *)avcc keyframe:(BOOL)key pts:(uint32_t)ptsMs;
@end

@interface FrameServer : NSObject
@property (nonatomic, weak) id<FrameServerDelegate> delegate;
@property (nonatomic, readonly) uint16_t port;
- (instancetype)initWithPort:(uint16_t)port;
- (BOOL)start:(NSError **)error;
- (void)stop;
- (void)sendTouchPhase:(uint8_t)phase x:(uint16_t)x y:(uint16_t)y;
- (void)sendScrollDx:(int16_t)dx dy:(int16_t)dy;
- (void)sendZoomDelta:(int16_t)delta;
- (void)sendRightClickX:(uint16_t)x y:(uint16_t)y;
- (void)sendKeyframeRequest;
- (void)sendPresented:(uint32_t)ptsMs;
+ (NSString *)wifiAddress; // IPv4 of en0, or nil
@end
