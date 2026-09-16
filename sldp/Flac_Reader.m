
#import <Foundation/Foundation.h>
#import "Flac_Reader.h"
#import "SldpBitstreamReader.h"

@implementation Flac_Reader {
    SldpBitStreamReader* _reader;
}

- (id)initWithBuffer:(const uint8_t *)buffer  buffer_size:(uint32_t)buffer_size {
    _reader = [[SldpBitStreamReader alloc] initWithBuffer:buffer buffer_size:buffer_size];
    return self;
}


static const int FLAC_SAMPLE_RATES[16] =
{ 0,
    88200, 176400, 192000,
    8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000,
    0, 0, 0, 0 };


static const int32_t FLAC_BLOCKSIZE[16] = {
    0,    192,
    576, 1152, 2304, 4608, // 144 * (2 ^ x)
    0, // Uncommon size, 8 bit
    0, // Uncommon size, 16 bit
    256, 512, 1024, 2048, 4096, 8192, 16384, 32768 // 2 ^ x
};


static const int8_t FLAC_SAMPLE_SIZE[] = { 0, 8, 12, 0, 16, 20, 24, 32 };


- (bool)processHeader {
    uint32_t sync_code;
    uint32_t variable_size;
    
    if (![_reader read_n_bits:15 value:&sync_code]) return false;
    if (sync_code != 0x7ffc) return false;
    
    if (![_reader read_n_bits:1 value:&variable_size]) return false;
    
    uint32_t blocksize_idx, samplerate_idx;
    
    /* block size and sample rate codes */
    if (![_reader read_n_bits:4 value:&blocksize_idx]) return false;
    if (![_reader read_n_bits:4 value:&samplerate_idx]) return false;
    
    uint32_t ch_mode;
    if (![_reader read_n_bits:4 value:&ch_mode]) return false;
    
    AudioChannelLayoutTag layout = [self layoutToCoreAudioTag: ch_mode];
    self.channelLayout = layout;
    int channels = [self channelCount:ch_mode];
    self.channels = channels;
    
    uint32_t bps_idx;
    if (![_reader read_n_bits:3 value:&bps_idx]) return false;
    uint8_t bps = FLAC_SAMPLE_SIZE[bps_idx];
    self.bps = bps;
    
    uint32_t reserved;
    if (![_reader read_n_bits:1 value:&reserved]) return false;
    
    /* sample or frame count */
    int64_t count;
    if (![_reader read_utf8:&count]) return false;
    
    /* blocksize */
    int blockSize = [self getBlockSizeByIdx: blocksize_idx];
    if (blockSize <= 0) {
        return false;
    }
    self.framesPerPacket = blockSize;
    
    int sampleRate = [self getSampleRateByIdx: samplerate_idx];
    if (sampleRate <= 0) {
        return false;
    }
    self.sampleRate = sampleRate;
    [self setFlags];
    // Finally goes frame header 8-bit CRC, just ignore it
    
    return true;
}

-(AudioChannelLayoutTag) layoutToCoreAudioTag: (uint8_t) layout {
    /*
     Value    Channels
     0b0000    1 channel: mono
     0b0001    2 channels: left, right
     0b0010    3 channels: left, right, center
     0b0011    4 channels: front left, front right, back left, back right
     0b0100    5 channels: front left, front right, front center, back/surround left, back/surround right
     0b0101    6 channels: front left, front right, front center, LFE, back/surround left, back/surround right
     0b0110    7 channels: front left, front right, front center, LFE, back center, side left, side right
     0b0111    8 channels: front left, front right, front center, LFE, back left, back right, side left, side right
     0b1000    2 channels: left, right; stored as left-side stereo
     0b1001    2 channels: left, right; stored as side-right stereo
     0b1010    2 channels: left, right; stored as mid-side stereo
     0b1011 - 0b1111    Reserved     */
    
    switch (layout) {
        case 0b0000:
            return kAudioChannelLayoutTag_Mono;
        case 0b0001:
            return kAudioChannelLayoutTag_Stereo;
        case 0b0010:
            return kAudioChannelLayoutTag_WAVE_3_0;     // 3 channels, L R C
        case 0b0011:
            return kAudioChannelLayoutTag_WAVE_4_0_A;   // 4 channels, L R Ls Rs
        case 0b0100:
            return kAudioChannelLayoutTag_WAVE_5_0_A;   // 5 channels, L R C Ls Rs
        case 0b0101:
            return kAudioChannelLayoutTag_WAVE_5_1_A;   // 6 channels, L R C LFE Ls Rs
        case 0b0110:
            return kAudioChannelLayoutTag_WAVE_6_1;     // 7 channels, L R C LFE Cs Ls Rs
        case 0b0111:
            return kAudioChannelLayoutTag_WAVE_7_1;     // 8 channels, L R C LFE Rls Rrs Ls Rs
        case 0b1000:
        case 0b1001:
        case 0b1010: // Should we care about these types difference? I suppose it's decoder's duty
            return kAudioChannelLayoutTag_Stereo;
        default:
            return kAudioChannelLayoutTag_Unknown;
    }
}

-(int)channelCount: (uint8_t) layout {
    if (layout <= 7) return layout + 1;
    return 2;
}


-(int)getSampleRateByIdx: (int) samplerate_idx {
    uint32_t x;
    if (samplerate_idx < 12) {
        return FLAC_SAMPLE_RATES[samplerate_idx];
    }
    if (samplerate_idx == 12) { //Uncommon sample rate in kHz, stored as an 8-bit number
        if (![_reader read_n_bits:8 value:&x]) return -1;
        return x * 1000;
    }
    if (samplerate_idx == 13) { //Uncommon sample rate in Hz, stored as a 16-bit number
        if (![_reader read_n_bits:16 value:&x]) return -1;
        return x;
    }
    if (samplerate_idx == 14) { //Uncommon sample rate in Hz divided by 10, stored as a 16-bit number
        if (![_reader read_n_bits:16 value:&x]) return -1;
        return x * 10;
    }
    return 0;

}

-(int)getBlockSizeByIdx: (int) blocksize_idx {
    uint32_t blockSize;

    if (blocksize_idx == 6) { //Uncommon block size minus 1, stored as an 8-bit number
        if (![_reader read_n_bits:8 value:&blockSize]) return -1;
        return blockSize + 1;
    }
    if (blocksize_idx == 7) { //Uncommon block size minus 1, stored as a 16-bit number
        if (![_reader read_n_bits:16 value:&blockSize]) return -1;
        return blockSize + 1;
    }
    return FLAC_BLOCKSIZE[blocksize_idx];
}


-(void)setFlags {
    switch (self.bps) {
        case 16:
            self.flags = kAppleLosslessFormatFlag_16BitSourceData;
            break;
        case 20:
            self.flags = kAppleLosslessFormatFlag_20BitSourceData;
            break;
        case 24:
            self.flags = kAppleLosslessFormatFlag_24BitSourceData;
            break;
        case 32:
            self.flags = kAppleLosslessFormatFlag_32BitSourceData;
            break;
            
    }
}

@end
