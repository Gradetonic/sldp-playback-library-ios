#import <Foundation/Foundation.h>
#import <CoreAudioTypes/CoreAudioTypes.h>

@interface Flac_Reader : NSObject
-(id) initWithBuffer:(const uint8_t *)buffer  buffer_size:(uint32_t)buffer_size;
-(bool) processHeader;
@property int sampleRate;
@property int channels;
@property AudioChannelLayoutTag channelLayout;
@property int bps;
@property AudioFormatFlags flags;
@property int framesPerPacket;

@end

