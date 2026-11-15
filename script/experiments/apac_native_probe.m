/* APAC feasibility probe. Builds independently of the application; macOS 26+.
 * Input is the explicit 12-channel float WAVE emitted by verify_truehd_objects.py.
 * This transports a speaker render, not the original Dolby object metadata.
 * SPDX-License-Identifier: MIT */
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <math.h>

static void require(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"APACProbe" reason:message userInfo:nil];
}
static void tick(void) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}
static void json(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(data.bytes, 1, data.length, stdout); puts("");
}
static uint32_t u32(const uint8_t *p) { uint32_t n; memcpy(&n,p,4); return CFSwapInt32LittleToHost(n); }
static uint16_t u16(const uint8_t *p) { uint16_t n; memcpy(&n,p,2); return CFSwapInt16LittleToHost(n); }

static NSDictionary *capabilities(void) {
    AudioFormatID format = kAudioFormatAPAC;
    UInt32 size = 0;
    OSStatus s = AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders, sizeof(format), &format, &size);
    return @{@"os":NSProcessInfo.processInfo.operatingSystemVersionString,
             @"apacEncoderQueryStatus":@(s), @"apacEncoderCount":@(size/sizeof(AudioClassDescription)),
             @"hardwareAtmosVerified":@NO, @"originalObjectMetadataTransported":@NO};
}

static NSArray *configurations(void) API_AVAILABLE(macos(26.0));
static NSArray *configurations(void) {
    NSMutableArray *results=[NSMutableArray array];
    for(NSNumber *channels in @[@2,@6,@12]) {
        AudioChannelLayoutTag tag=channels.intValue==12 ? kAudioChannelLayoutTag_Atmos_7_1_4
            : channels.intValue==6 ? kAudioChannelLayoutTag_MPEG_5_1_A : kAudioChannelLayoutTag_Stereo;
        AudioChannelLayout layout={.mChannelLayoutTag=tag};
        for(NSNumber *hint in @[@NO,@YES]) {
            NSMutableDictionary *settings=[@{AVFormatIDKey:@(kAudioFormatAPAC),AVSampleRateKey:@48000,AVNumberOfChannelsKey:channels,
                AVChannelLayoutKey:[NSData dataWithBytes:&layout length:sizeof(layout)],AVEncoderBitRateKey:@768000,
                AVEncoderDynamicRangeControlConfigurationKey:@(AVAudioDynamicRangeControlConfiguration_Movie),AVEncoderASPFrequencyKey:@75} mutableCopy];
            if(hint.boolValue) settings[AVEncoderContentSourceKey]=@(AVAudioContentSource_AV_Spatial_Offline);
            AVAssetWriter *writer=[[AVAssetWriter alloc] initWithContentType:UTTypeMPEG4Movie];
            NSString *inputError=@"";
            @try { (void)[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:settings]; }
            @catch(NSException *e) { inputError=e.reason; }
            [results addObject:@{@"channels":channels,@"publicSpatialOfflineHint":hint,
                @"canApply":@([writer canApplyOutputSettings:settings forMediaType:AVMediaTypeAudio]),@"inputError":inputError}];
        }
    }
    return results;
}

@interface APACSegments : NSObject <AVAssetWriterDelegate>
@property NSURL *directory;
@property NSMutableArray<NSDictionary *> *segments;
@property NSMutableData *combined;
@property NSError *error;
@end
@implementation APACSegments
- (void)assetWriter:(AVAssetWriter *)writer didOutputSegmentData:(NSData *)data
       segmentType:(AVAssetSegmentType)type segmentReport:(AVAssetSegmentReport *)report {
    @synchronized(self) {
        NSString *name = type == AVAssetSegmentTypeInitialization ? @"init.mp4"
            : [NSString stringWithFormat:@"segment-%04lu.m4s",(unsigned long)self.segments.count];
        NSError *error = nil;
        if (![data writeToURL:[self.directory URLByAppendingPathComponent:name] options:NSDataWritingWithoutOverwriting error:&error]) {
            self.error = error; return;
        }
        [self.combined appendData:data];
        if (type != AVAssetSegmentTypeInitialization) {
            AVAssetSegmentTrackReport *track = report.trackReports.firstObject;
            double duration = CMTimeGetSeconds(track.duration);
            double pts = CMTimeGetSeconds(track.earliestPresentationTimeStamp);
            if (!isfinite(duration) || duration <= 0 || !isfinite(pts)) {
                self.error = [NSError errorWithDomain:@"APACProbe" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Missing segment timing report"}];
                return;
            }
            [self.segments addObject:@{@"file":name,@"pts":@(pts),@"duration":@(duration),@"bytes":@(data.length)}];
        }
    }
}
@end

static void finishWriter(AVAssetWriter *writer, AVAssetWriterInput *input, CMTime end) {
    [writer endSessionAtSourceTime:end]; [input markAsFinished];
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{dispatch_semaphore_signal(done);}];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:30]; BOOL finished=NO;
    while(deadline.timeIntervalSinceNow>0) {
        if(dispatch_semaphore_wait(done,DISPATCH_TIME_NOW)==0) { finished=YES; break; } tick();
    }
    require(finished && writer.status==AVAssetWriterStatusCompleted,writer.error.description ?: @"Writer finish timeout");
}

static int64_t frames(CMTime time) {
    require(CMTIME_IS_NUMERIC(time),@"Missing numeric audio time");
    CMTime scaled=CMTimeConvertScale(time,48000,kCMTimeRoundingMethod_RoundHalfAwayFromZero);
    require(fabs(CMTimeGetSeconds(CMTimeSubtract(time,scaled)))<1e-9,@"Audio time is not on the 48 kHz sample grid");
    return scaled.value;
}

static CMTime trim(CMSampleBufferRef sample, CFStringRef key) {
    CFTypeRef value=CMGetAttachment(sample,key,NULL);
    if(!value) return kCMTimeZero;
    require(CFGetTypeID(value)==CFDictionaryGetTypeID(),@"Invalid packet trim attachment");
    CMTime time=CMTimeMakeFromDictionary(value);
    require(frames(time)>=0,@"Negative packet trim"); return time;
}

// Fragmented AVAssetWriter output retains packet padding. Materialize the
// reader's exact end trim as the last packet's presentation duration, without
// re-encoding or deleting compressed packets. A reader timeRange alone would
// only mask the defect in the verifier; the final full-file read uses no range.
static NSDictionary *remuxTimed(NSURL *source, APACSegments *segments, int64_t sourceFrames) {
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:source options:nil];
    AVAssetTrack *track=[asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    require(track!=nil,@"Missing encoded APAC track");
    AVAssetReader *reader=[[AVAssetReader alloc] initWithAsset:asset error:nil];
    reader.timeRange=CMTimeRangeMake(kCMTimeZero,CMTimeMake(sourceFrames,48000));
    AVAssetReaderTrackOutput *output=[[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:nil];
    [reader addOutput:output]; require([reader startReading],reader.error.description);
    AVAssetWriter *writer=[[AVAssetWriter alloc] initWithContentType:UTTypeMPEG4Movie];
    writer.outputFileTypeProfile=AVFileTypeProfileMPEG4AppleHLS;
    writer.preferredOutputSegmentInterval=CMTimeMake(76800,48000); writer.initialSegmentStartTime=kCMTimeZero;
    writer.delegate=segments;
    AVAssetWriterInput *input=[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:nil
        sourceFormatHint:(__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject];
    require([writer canAddInput:input],@"Cannot add APAC passthrough input"); [writer addInput:input];
    require([writer startWriting],writer.error.description); [writer startSessionAtSourceTime:kCMTimeZero];
    int64_t priming=0,tail=0,packetCount=0; BOOL sawTail=NO;
    CMSampleBufferRef sample;
    while((sample=[output copyNextSampleBuffer])) {
        @try {
            CMItemCount count=CMSampleBufferGetNumSamples(sample);
            if(!count) continue; // Reader drain and empty-media markers carry no packets.
            require(!sawTail && count>0 && count<=4096,@"Unexpected packet sequence after end trim");
            int64_t leading=frames(trim(sample,kCMSampleBufferAttachmentKey_TrimDurationAtStart));
            require(!leading || packetCount==0,@"Unexpected midstream priming"); priming+=leading;
            CMTime endTrim=trim(sample,kCMSampleBufferAttachmentKey_TrimDurationAtEnd);
            tail=frames(endTrim);
            if(tail) {
                CMTime pts=CMSampleBufferGetOutputPresentationTimeStamp(sample);
                CMSampleTimingInfo *timing=calloc((size_t)count,sizeof(*timing)); require(timing!=NULL,@"Timing allocation failed");
                CMSampleBufferRef modified=NULL;
                @try {
                    for(CMItemCount i=0;i<count;i++) require(CMSampleBufferGetSampleTimingInfo(sample,i,&timing[i])==noErr,@"Missing packet timing");
                    timing[count-1].duration=CMTimeSubtract(timing[count-1].duration,endTrim);
                    require(frames(timing[count-1].duration)>0,@"End trim exceeds the last packet");
                    require(CMSampleBufferCreateCopyWithNewTiming(NULL,sample,count,timing,&modified)==noErr,@"Cannot update last packet timing");
                } @finally { free(timing); }
                CFRelease(sample); sample=modified;
                CMRemoveAttachment(sample,kCMSampleBufferAttachmentKey_TrimDurationAtEnd);
                require(CMSampleBufferSetOutputPresentationTimeStamp(sample,pts)==noErr,@"Cannot preserve packet output PTS");
                sawTail=YES;
            }
            NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];
            while(!input.readyForMoreMediaData && writer.status==AVAssetWriterStatusWriting && deadline.timeIntervalSinceNow>0) tick();
            require(input.readyForMoreMediaData,writer.error.description ?: @"Passthrough backpressure timeout");
            require([input appendSampleBuffer:sample],writer.error.description); packetCount+=count;
        } @finally { CFRelease(sample); }
    }
    require(reader.status==AVAssetReaderStatusCompleted,reader.error.description);
    require(packetCount*1024-priming-tail==sourceFrames && tail<1024,@"Unexpected APAC priming or packet count");
    finishWriter(writer,input,CMTimeMake(sourceFrames,48000));
    require(!segments.error && segments.segments.count>0,segments.error.description ?: @"No timed output segments");
    return @{@"primingFrames":@(priming),@"lastPacketPaddingFrames":@(tail),@"packetCount":@(packetCount),
        @"reencoded":@NO,@"finalDecodeTimeRangeRestricted":@NO};
}

static NSDictionary *decodeFile(NSURL *url, NSURL *directory, AudioChannelLayout *layout) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    require(track != nil, @"Encoded output has no audio track");
    CMAudioFormatDescriptionRef encoded = (__bridge CMAudioFormatDescriptionRef)track.formatDescriptions.firstObject;
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(encoded);
    require(asbd && asbd->mFormatID == kAudioFormatAPAC && asbd->mChannelsPerFrame == 12,
            @"Native reader did not identify 12-channel APAC");
    size_t layoutSize = 0;
    const AudioChannelLayout *encodedLayout = CMAudioFormatDescriptionGetChannelLayout(encoded, &layoutSize);
    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    require(reader != nil, error.description);
    NSDictionary *settings = @{AVFormatIDKey:@(kAudioFormatLinearPCM), AVLinearPCMBitDepthKey:@32,
        AVLinearPCMIsFloatKey:@YES, AVLinearPCMIsNonInterleaved:@NO, AVLinearPCMIsBigEndianKey:@NO,
        AVChannelLayoutKey:[NSData dataWithBytes:layout length:sizeof(*layout)]};
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    [reader addOutput:output];
    require([reader startReading], reader.error.description);
    NSURL *pcmURL = [directory URLByAppendingPathComponent:@"decoded.f32"];
    FILE *file = fopen(pcmURL.fileSystemRepresentation,"wx"); require(file != NULL,@"Cannot create decoded.f32");
    uint64_t frames = 0; double energy[12] = {0}, peak = 0, firstPTS = NAN, endPTS = NAN;
    @try {
        CMSampleBufferRef sample;
        while ((sample = [output copyNextSampleBuffer])) {
            @try {
                CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
                size_t bytes = CMBlockBufferGetDataLength(block);
                require(bytes % (12*sizeof(float)) == 0,@"Unexpected decoded PCM size");
                NSMutableData *data = [NSMutableData dataWithLength:bytes];
                require(CMBlockBufferCopyDataBytes(block,0,bytes,data.mutableBytes) == noErr,@"Cannot read PCM");
                const float *p = data.bytes;
                size_t count = bytes/(12*sizeof(float));
                double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
                require(isfinite(pts),@"Missing decoded PTS");
                if (!isfinite(firstPTS)) firstPTS = pts;
                if (isfinite(endPTS)) require(fabs(pts-endPTS) < 1.0/asbd->mSampleRate,@"Decoded PTS discontinuity");
                endPTS = pts+(double)count/asbd->mSampleRate;
                for (size_t n=0;n<count;n++) for (int c=0;c<12;c++) {
                    double v = p[n*12+c]; require(isfinite(v),@"Non-finite decoded sample");
                    energy[c] += v*v; peak = fmax(peak,fabs(v));
                }
                require(fwrite(data.bytes,1,bytes,file) == bytes,@"Cannot write decoded PCM");
                frames += count;
            } @finally { CFRelease(sample); }
        }
    } @finally { fclose(file); }
    require(reader.status == AVAssetReaderStatusCompleted,reader.error.description);
    NSMutableArray *energies = [NSMutableArray array];
    for(int c=0;c<12;c++) [energies addObject:@(energy[c])];
    return @{@"frames":@(frames),@"sampleRate":@(asbd->mSampleRate),@"channels":@(asbd->mChannelsPerFrame),
        @"encodedLayoutTag":@(encodedLayout ? encodedLayout->mChannelLayoutTag : 0),
        @"firstPTS":@(firstPTS),@"endPTS":@(endPTS),@"assetDuration":@(CMTimeGetSeconds(asset.duration)),@"peak":@(peak),@"energy":energies,
        @"allFinite":@YES,@"file":@"decoded.f32"};
}

static NSDictionary *encode(NSString *source, NSString *destination) API_AVAILABLE(macos(26.0));
static NSDictionary *encode(NSString *source, NSString *destination) {
    NSURL *directory = [NSURL fileURLWithPath:destination isDirectory:YES];
    require(![NSFileManager.defaultManager fileExistsAtPath:destination],@"Output directory already exists");
    NSError *error = nil;
    require([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error],error.description);
    NSData *wave = [NSData dataWithContentsOfFile:source options:NSDataReadingMappedIfSafe error:&error];
    require(wave.length >= 12 && !memcmp(wave.bytes,"RIFF",4) && !memcmp((uint8_t *)wave.bytes+8,"WAVE",4),@"Expected RIFF WAVE");
    const uint8_t *pcm = NULL; size_t pcmBytes = 0; uint32_t rate = 0; BOOL validFormat = NO;
    for(size_t offset=12; offset+8<=wave.length;) {
        const uint8_t *chunk = (const uint8_t *)wave.bytes+offset;
        uint32_t bytes = u32(chunk+4); require(bytes <= wave.length-offset-8,@"Truncated WAVE chunk");
        if(!memcmp(chunk,"fmt ",4)) {
            const uint8_t *f = chunk+8;
            static const uint8_t floatGUID[16] = {3,0,0,0,0,0,16,0,128,0,0,170,0,56,155,113};
            require(bytes>=40 && u16(f)==0xfffe && u16(f+2)==12 && u16(f+12)==48 && u16(f+14)==32
                    && u16(f+16)>=22 && u16(f+18)==32 && u32(f+20)==0x2d63f && !memcmp(f+24,floatGUID,16),
                    @"Expected 12-channel float32 extensible WAVE with explicit FL FR FC LFE BL BR SL SR TFL TFR TBL TBR mask");
            rate = u32(f+4); validFormat = YES;
        } else if(!memcmp(chunk,"data",4)) { pcm = chunk+8; pcmBytes = bytes; }
        offset += 8+(size_t)bytes+(bytes&1);
    }
    require(validFormat && pcm && pcmBytes && pcmBytes%48==0 && rate==48000,@"Expected nonempty 48 kHz PCM");
    uint64_t totalFrames = pcmBytes/48;
    require(totalFrames <= (uint64_t)rate*120,@"This in-memory feasibility probe accepts at most 120 seconds");
    AudioChannelLayout layout = {.mChannelLayoutTag=kAudioChannelLayoutTag_Atmos_7_1_4};
    NSData *layoutData = [NSData dataWithBytes:&layout length:sizeof(layout)];
    NSDictionary *settings = @{AVFormatIDKey:@(kAudioFormatAPAC),AVSampleRateKey:@(rate),AVNumberOfChannelsKey:@12,
        AVChannelLayoutKey:layoutData,AVEncoderBitRateKey:@768000,
        // macOS 26.6.2 AVAssetWriter rejects the public non-Apple source values
        // 33...42. Omit this optional hint; do not label our input Apple content.
        AVEncoderDynamicRangeControlConfigurationKey:@(AVAudioDynamicRangeControlConfiguration_Movie),AVEncoderASPFrequencyKey:@75};
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithContentType:UTTypeMPEG4Movie];
    require([writer canApplyOutputSettings:settings forMediaType:AVMediaTypeAudio],@"System cannot apply APAC encoder settings");
    writer.outputFileTypeProfile = AVFileTypeProfileMPEG4AppleHLS;
    writer.preferredOutputSegmentInterval = CMTimeMake(76800,48000); // 75 x 1024 frames; ASP aligned.
    writer.initialSegmentStartTime = kCMTimeZero;
    NSURL *intermediate=[directory URLByAppendingPathComponent:@"encoder-output" isDirectory:YES];
    require([NSFileManager.defaultManager createDirectoryAtURL:intermediate withIntermediateDirectories:NO attributes:nil error:&error],error.description);
    APACSegments *segments = [APACSegments new]; segments.directory=intermediate;
    segments.segments=[NSMutableArray array]; segments.combined=[NSMutableData data]; writer.delegate=segments;
    AudioStreamBasicDescription format = {.mSampleRate=rate,.mFormatID=kAudioFormatLinearPCM,
        .mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,.mBytesPerPacket=48,.mFramesPerPacket=1,
        .mBytesPerFrame=48,.mChannelsPerFrame=12,.mBitsPerChannel=32};
    CMAudioFormatDescriptionRef description = NULL;
    require(CMAudioFormatDescriptionCreate(NULL,&format,sizeof(layout),&layout,0,NULL,NULL,&description)==noErr,@"Cannot create PCM format");
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:settings sourceFormatHint:description];
    input.expectsMediaDataInRealTime = NO; require([writer canAddInput:input],@"Cannot add encoder input"); [writer addInput:input];
    require([writer startWriting],writer.error.description); [writer startSessionAtSourceTime:kCMTimeZero];
    NSDate *start = NSDate.date;
    @try {
        // WAVE uses back before side; Apple's Atmos tag uses side before rear.
        const int order[12]={0,1,2,3,6,7,4,5,8,9,10,11};
        for(uint64_t frame=0;frame<totalFrames;) {
            @autoreleasepool {
                NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
                while(!input.readyForMoreMediaData && writer.status==AVAssetWriterStatusWriting && deadline.timeIntervalSinceNow>0) tick();
                require(input.readyForMoreMediaData,writer.error.description ?: @"Encoder backpressure timeout");
                size_t count = MIN((uint64_t)4096,totalFrames-frame), bytes=count*48;
                CMBlockBufferRef block=NULL; CMSampleBufferRef sample=NULL;
                require(CMBlockBufferCreateWithMemoryBlock(NULL,NULL,bytes,NULL,NULL,0,bytes,kCMBlockBufferAssureMemoryNowFlag,&block)==noErr,@"PCM allocation failed");
                char *data=NULL; require(CMBlockBufferGetDataPointer(block,0,NULL,NULL,&data)==noErr,@"PCM mapping failed");
                const float *sourcePCM=(const float *)pcm+frame*12; float *dest=(float *)data;
                for(size_t n=0;n<count;n++) for(int c=0;c<12;c++) {
                    float v=sourcePCM[n*12+order[c]]; require(isfinite(v),@"Non-finite input PCM"); dest[n*12+c]=v;
                }
                CMSampleTimingInfo timing={CMTimeMake(1,rate),CMTimeMake(frame,rate),kCMTimeInvalid}; size_t sampleSize=48;
                OSStatus status=CMSampleBufferCreateReady(NULL,block,description,count,1,&timing,1,&sampleSize,&sample);
                CFRelease(block); require(status==noErr,@"Cannot create PCM sample");
                BOOL appended=[input appendSampleBuffer:sample]; CFRelease(sample); require(appended,writer.error.description);
                frame+=count;
            }
        }
        finishWriter(writer,input,CMTimeMake(totalFrames,rate));
    } @finally { CFRelease(description); }
    double encoderSeconds=-start.timeIntervalSinceNow;
    require(!segments.error && segments.segments.count>0,segments.error.description ?: @"No output segments");
    NSURL *encodedURL=[intermediate URLByAppendingPathComponent:@"combined.mp4"];
    require([segments.combined writeToURL:encodedURL options:NSDataWritingWithoutOverwriting error:&error],error.description);
    NSArray *originalSegments=[segments.segments copy];
    segments=[APACSegments new]; segments.directory=directory; segments.segments=[NSMutableArray array]; segments.combined=[NSMutableData data];
    NSDate *remuxStart=NSDate.date;
    NSDictionary *packetTiming=remuxTimed(encodedURL,segments,(int64_t)totalFrames);
    double remuxSeconds=-remuxStart.timeIntervalSinceNow;
    NSURL *combinedURL=[directory URLByAppendingPathComponent:@"combined.mp4"];
    require([segments.combined writeToURL:combinedURL options:NSDataWritingWithoutOverwriting error:&error],error.description);
    NSMutableArray *presentation=[NSMutableArray array]; int64_t previous=0;
    int64_t priming=[packetTiming[@"primingFrames"] longLongValue];
    for(NSDictionary *coded in segments.segments) {
        int64_t rawStart=llround([coded[@"pts"] doubleValue]*rate),rawEnd=rawStart+llround([coded[@"duration"] doubleValue]*rate);
        int64_t startFrame=MAX(0,rawStart-priming),endFrame=MIN((int64_t)totalFrames,rawEnd-priming);
        require(startFrame==previous && endFrame>startFrame,@"Discontinuous presentation segments"); previous=endFrame;
        NSMutableDictionary *s=[coded mutableCopy]; s[@"codedPTS"]=coded[@"pts"]; s[@"codedDuration"]=coded[@"duration"];
        s[@"pts"]=@((double)startFrame/rate); s[@"duration"]=@((double)(endFrame-startFrame)/rate);
        s[@"presentationFrames"]=@(endFrame-startFrame); [presentation addObject:s];
    }
    require(previous==(int64_t)totalFrames,@"HLS presentation duration differs from source");
    segments.segments=presentation;
    double maxDuration=0; for(NSDictionary *s in segments.segments) maxDuration=fmax(maxDuration,[s[@"duration"] doubleValue]);
    NSMutableString *playlist=[NSMutableString stringWithFormat:@"#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:%d\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"init.mp4\"\n",(int)ceil(maxDuration)];
    for(NSDictionary *s in segments.segments) [playlist appendFormat:@"#EXTINF:%.9f,\n%@\n",[s[@"duration"] doubleValue],s[@"file"]];
    [playlist appendString:@"#EXT-X-ENDLIST\n"];
    require([playlist writeToURL:[directory URLByAppendingPathComponent:@"audio.m3u8"] atomically:NO encoding:NSUTF8StringEncoding error:&error],error.description);
    NSDate *decodeStart=NSDate.date;
    NSDictionary *decoded=decodeFile(combinedURL,directory,&layout);
    double decodeSeconds=-decodeStart.timeIntervalSinceNow;
    int64_t tailPadding=[decoded[@"frames"] longLongValue]-(int64_t)totalFrames;
    require(tailPadding==0,@"Final full-file APAC decode has extra or missing frames");
    require(fabs([decoded[@"firstPTS"] doubleValue])<1.0/rate,@"Unexpected APAC start timestamp");
    require(fabs([decoded[@"assetDuration"] doubleValue]-(double)totalFrames/rate)<1.0/rate,@"Final APAC asset duration differs from source");
    return @{@"capabilities":capabilities(),@"inputFrames":@(totalFrames),@"sampleRate":@(rate),
        @"inputChannelOrder":@[@"FL",@"FR",@"FC",@"LFE",@"BL",@"BR",@"SL",@"SR",@"TFL",@"TFR",@"TBL",@"TBR"],
        @"apacChannelOrder":@[@"FL",@"FR",@"FC",@"LFE",@"SL",@"SR",@"BL",@"BR",@"TFL",@"TFR",@"TBL",@"TBR"],
        @"encoderSeconds":@(encoderSeconds),@"remuxSeconds":@(remuxSeconds),@"packetTiming":packetTiming,
        @"encoderSegmentsBeforeTimingFix":originalSegments,@"nativeDecodeSeconds":@(decodeSeconds),@"segments":segments.segments,@"decoded":decoded,
        @"sourceDuration":@((double)totalFrames/rate),@"nativeDecodedTailPaddingFrames":@(tailPadding),
        @"nativeDecodedFrameCountExact":@((BOOL)(tailPadding==0)),
        @"configuredBitRate":@768000,@"contentSource":@"system default; public non-Apple hint rejected by AVAssetWriter",@"drcConfiguration":@3,@"aspIntervalPackets":@75,
        @"applicationPlaybackIntegrated":@NO,@"originalObjectMetadataTransported":@NO,@"hardwareAtmosVerified":@NO};
}

static void seek(AVPlayer *player, double seconds) {
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    __block BOOL completed=NO;
    [player seekToTime:CMTimeMakeWithSeconds(seconds,48000) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero
        completionHandler:^(BOOL value) { completed=value; dispatch_semaphore_signal(done); }];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20]; BOOL finished=NO;
    while(deadline.timeIntervalSinceNow>0) {
        if(dispatch_semaphore_wait(done,DISPATCH_TIME_NOW)==0) { finished=YES; break; } tick();
    }
    require(finished && completed,@"Native seek failed or timed out");
    require(fabs(CMTimeGetSeconds(player.currentTime)-seconds)<.03,@"Native seek position mismatch");
}

static NSDictionary *play(NSString *address, int64_t sourceFrames) {
    NSURL *url=[NSURL URLWithString:address];
    require([url.scheme isEqual:@"http"] && [url.host isEqual:@"127.0.0.1"],@"Playback probe accepts only its loopback HTTP fixture server");
    AVPlayerItem *item=[AVPlayerItem playerItemWithURL:url];
    AVPlayer *player=[AVPlayer playerWithPlayerItem:item]; player.muted=YES;
    player.automaticallyWaitsToMinimizeStalling=NO;
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:30];
    while(item.status==AVPlayerItemStatusUnknown && deadline.timeIntervalSinceNow>0) tick();
    require(item.status==AVPlayerItemStatusReadyToPlay,item.error.description ?: @"Native item did not become ready");
    double sourceDuration=(double)sourceFrames/48000,itemDuration=CMTimeGetSeconds(item.duration);
    require(sourceDuration>3.4 && isfinite(itemDuration) && fabs(itemDuration-sourceDuration)<.001,
            @"Native HLS item duration differs from source by at least 1 ms");
    [player play]; deadline=[NSDate dateWithTimeIntervalSinceNow:20];
    while(CMTimeGetSeconds(player.currentTime)<2.1 && item.status!=AVPlayerItemStatusFailed && deadline.timeIntervalSinceNow>0) tick();
    double advanced=CMTimeGetSeconds(player.currentTime);
    require(advanced>=2.1 && item.status!=AVPlayerItemStatusFailed,item.error.description ?: @"Native playback did not advance across a segment boundary");
    [player pause]; double paused=CMTimeGetSeconds(player.currentTime);
    NSDate *pauseUntil=[NSDate dateWithTimeIntervalSinceNow:.15]; while(pauseUntil.timeIntervalSinceNow>0) tick();
    require(fabs(CMTimeGetSeconds(player.currentTime)-paused)<.03,@"Native pause did not hold position");
    seek(player,3.25); seek(player,.25);
    [player play]; deadline=[NSDate dateWithTimeIntervalSinceNow:10];
    while(CMTimeGetSeconds(player.currentTime)<.8 && deadline.timeIntervalSinceNow>0 && item.status!=AVPlayerItemStatusFailed) tick();
    require(CMTimeGetSeconds(player.currentTime)>=.8 && item.status!=AVPlayerItemStatusFailed,@"Native playback failed after seek");
    [player pause];
    __block BOOL ended=NO;
    id observer=[NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { ended=YES; }];
    @try {
        seek(player,sourceDuration-.1); [player play]; deadline=[NSDate dateWithTimeIntervalSinceNow:10];
        while(!ended && deadline.timeIntervalSinceNow>0 && item.status!=AVPlayerItemStatusFailed) tick();
        // AVPlayer's extrapolated clock at asynchronous EOF notification can
        // overshoot item.duration. Exact media bounds are verified separately
        // by the unrestricted full-file decode and the native item duration.
        require(ended && item.status!=AVPlayerItemStatusFailed,@"Native HLS did not reach end after the near-end seek");
    } @finally { [NSNotificationCenter.defaultCenter removeObserver:observer]; }
    [player pause];
    AVPlayerItemAccessLogEvent *access=item.accessLog.events.lastObject;
    NSMutableDictionary *result=[@{@"readyToPlay":@YES,@"muted":@(player.muted),@"advancedSeconds":@(advanced),
        @"pauseHeld":@YES,@"exactSeekSeconds":@[@3.25,@.25],@"resumedAfterSeek":@YES,
        @"itemDuration":@(itemDuration),@"sourceDuration":@(sourceDuration),@"itemDurationErrorSeconds":@(itemDuration-sourceDuration),
        @"itemDurationMatchesSourceWithin1ms":@YES,@"nearEndSeekSeconds":@(sourceDuration-.1),
        @"endNotificationReceived":@(ended),@"endCallbackClockSeconds":@(CMTimeGetSeconds(player.currentTime)),
        @"endCallbackClockErrorSeconds":@(CMTimeGetSeconds(player.currentTime)-sourceDuration),@"errorLogEvents":@(item.errorLog.events.count),
        @"hardwareAtmosVerified":@NO,@"headTrackingVerified":@NO} mutableCopy];
    if(access) { result[@"segmentsDownloaded"]=@(access.numberOfMediaRequests); result[@"stalls"]=@(access.numberOfStalls); }
    require(!item.error && item.errorLog.events.count==0,item.error.description ?: @"Native HLS error log is nonempty");
    [player replaceCurrentItemWithPlayerItem:nil]; return result;
}

int main(int argc,const char **argv) {
    @autoreleasepool { @try {
        if(argc==2 && !strcmp(argv[1],"--capabilities")) { json(capabilities()); return 0; }
        if(argc==4 && !strcmp(argv[1],"--play")) { json(play(@(argv[2]),atoll(argv[3]))); return 0; }
        if(argc==2 && !strcmp(argv[1],"--configurations")) {
            if(@available(macOS 26.0,*)) { json(@{@"capabilities":capabilities(),@"configurations":configurations()}); return 0; }
        }
        require(argc==4 && !strcmp(argv[1],"--encode"),@"Usage: apac_native_probe --capabilities | --configurations | --play LOOPBACK_URL SOURCE_FRAMES | --encode INPUT.wav NEW_OUTPUT_DIRECTORY");
        if(@available(macOS 26.0,*)) { json(encode(@(argv[2]),@(argv[3]))); return 0; }
        require(NO,@"APAC platform encoding requires macOS 26 or later");
    } @catch(NSException *error) { json(@{@"success":@NO,@"error":error.reason ?: error.name,@"capabilities":capabilities()}); return 1; } }
}
