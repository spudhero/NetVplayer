#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#include "../runtime/mpv/audio/out/avfoundation_eac3.h"

static bool malformed_packets_are_rejected(const uint8_t *burst)
{
    uint8_t changed[NV_EAC3_BURST_BYTES];
    struct nv_eac3_packet original, swapped, rejected;
    if (!nv_eac3_unpack(burst, sizeof(changed), &original)) return false;
    if (nv_eac3_unpack(burst, sizeof(changed) - 1, &rejected)) return false;
    for (size_t i = 0; i < sizeof(changed); i++) changed[i] = burst[i ^ 1];
    if (!nv_eac3_unpack(changed, sizeof(changed), &swapped) ||
        original.size != swapped.size || memcmp(original.data, swapped.data, original.size)) return false;
    for (int field = 0; field < 4; field++) {
        memcpy(changed, burst, sizeof(changed));
        switch (field) {
        case 0: changed[0] = changed[1] = 0; break; // missing sync preamble
        case 1: changed[4] = changed[5] = 0xff; break; // wrong IEC data type
        case 2: changed[6] = changed[7] = 0xff; break; // oversized / odd payload
        case 3: changed[8] = changed[9] = 0; break; // broken codec sync frame
        }
        if (nv_eac3_unpack(changed, sizeof(changed), &rejected)) return false;
    }
    return true;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if(argc!=4) {fprintf(stderr,"usage: roundtrip IEC61937_FILE ORIGINAL_MEDIA joc|plain\n");return 2;}
        FILE *input=fopen(argv[1],"rb");
        if(!input)return 3;
        uint8_t burst[NV_EAC3_BURST_BYTES];
        AVFormatContext *demux=NULL;
        if(avformat_open_input(&demux,argv[2],NULL,NULL)<0)return 4;
        if(avformat_find_stream_info(demux,NULL)<0)return 5;
        int track=av_find_best_stream(demux,AVMEDIA_TYPE_AUDIO,-1,-1,NULL,0);
        AVPacket *raw=av_packet_alloc();
        int count=0;
        while(fread(burst,1,sizeof(burst),input)==sizeof(burst)) {
            struct nv_eac3_packet packet;
            if(!nv_eac3_unpack(burst,sizeof(burst),&packet)) {puts("Invalid burst");return 6;}
            if(!malformed_packets_are_rejected(burst)) {puts("Malformed packet accepted or endian roundtrip failed");return 10;}
            while(av_read_frame(demux,raw)>=0 && raw->stream_index!=track)av_packet_unref(raw);
            if(raw->size!=packet.size || memcmp(raw->data,packet.data,packet.size)) {puts("Payload differs");return 7;}
            av_packet_unref(raw);
            bool joc=false;
            CMAudioFormatDescriptionRef fmt=nv_eac3_format(&packet, &joc);
            if(!fmt) {puts("Invalid format");return 8;}
            if(joc != !strcmp(argv[3],"joc")) {puts("JOC cookie differs from expected source");return 11;}
            const AudioStreamBasicDescription *asbd=CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
            size_t cookieSize=0;CMAudioFormatDescriptionGetMagicCookie(fmt,&cookieSize);
            if(count==0)printf("Native EAC3: rate=%.0f channels=%u frames=%u cookie=%zu bytes\n",asbd->mSampleRate,asbd->mChannelsPerFrame,asbd->mFramesPerPacket,cookieSize);
            CFRelease(fmt);count++;
        }
        printf("Verified byte-identical complete compressed packets: %d\n",count);
        av_packet_free(&raw);avformat_close_input(&demux);fclose(input);return count?0:9;
    }
}
