#import <AppKit/AppKit.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import "NVDolbyVisionSurface.h"
#include <assert.h>
#include <math.h>
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static void pump(double seconds) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    do { [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]]; } while(end.timeIntervalSinceNow>0);
}
static void render(NVDolbyVisionSurface *surface, double pts, uint64_t generation, float value) {
    BOOL prepared=NO;
    for(int i=0;i<100;i++) {
        prepared=[surface prepareWidth:256 height:256];
        if(prepared || !surface.temporarilyUnavailable) break;
        pump(.004);
    }
    assert(prepared);
    glBindFramebuffer(GL_FRAMEBUFFER,surface.framebuffer);
    glViewport(0,0,256,256); glClearColor(value,value,value,1); glClear(GL_COLOR_BUFFER_BIT);
    glBindFramebuffer(GL_FRAMEBUFFER,0);
    assert([surface presentPTS:pts generation:generation]);
    assert([surface.facts[@"currentMetadataSubmitted"] boolValue]);
    assert([surface.facts[@"metadataBytes"] intValue]>20);
    assert([surface.facts[@"surfaceCount"] intValue]<=3);
}
int main(int argc, char **argv) { @autoreleasepool {
    assert(NVDolbyVisionSurface.available);
    [NSApplication sharedApplication];
    CGLPixelFormatAttribute attrs[]={kCGLPFAOpenGLProfile,(CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,kCGLPFAAccelerated,0};
    CGLPixelFormatObj format=NULL; GLint count=0; CGLContextObj context=NULL;
    assert(CGLChoosePixelFormat(attrs,&format,&count)==kCGLNoError);
    assert(CGLCreateContext(format,NULL,&context)==kCGLNoError); CGLReleasePixelFormat(format);
    assert(CGLSetCurrentContext(context)==kCGLNoError);
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,256,256) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO; window.alphaValue=.01;
    NVDolbyVisionSurface *surface=[[NVDolbyVisionSurface alloc] initWithFrame:NSMakeRect(0,0,256,256)];
    window.contentView=surface; [window orderFrontRegardless];
    render(surface,0,1,.1f); NSData *dark=[surface copyPresentedRPU]; assert(dark.length>0);
    NSData *pixels=[surface copyPresentedHalfFloats]; assert(pixels.length==256*256*8);
    const _Float16 *values=pixels.bytes;
    assert(fabs((float)values[0]-.1f)<.0002 && (float)values[3]==1);
    render(surface,1.0/24,1,.9f); NSData *bright=[surface copyPresentedRPU]; assert(bright.length>0);
    assert(![dark isEqualToData:bright]);
    // Paused subtitle/OSD redraws may change pixels without advancing media PTS.
    NSUInteger before=[surface.facts[@"submittedFrames"] unsignedIntegerValue];
    render(surface,1.0/24,1,.1f);
    assert([surface.facts[@"submittedFrames"] unsignedIntegerValue]==before+1);
    assert([[surface copyPresentedRPU] isEqualToData:dark]);
    for(int i=2;i<80;i++) { render(surface,i/24.0,1,(i%2)?.15f:.8f); pump(.003); }
    NSUInteger resets=[surface.facts[@"resets"] unsignedIntegerValue];
    render(surface,.2,2,.1f);
    assert([surface.facts[@"resets"] unsignedIntegerValue]>resets);
    assert([[surface copyPresentedRPU] isEqualToData:dark]);
    pump(.1);
    NSDictionary *facts=surface.facts;
    assert([facts[@"rendererStatus"] intValue]!=2);
    assert(![facts[@"receiverDolbyVisionVerified"] boolValue]);
    if(argc>1) {
        NSString *folder=[NSString stringWithUTF8String:argv[1]];
        [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        [dark writeToFile:[folder stringByAppendingPathComponent:@"dark.rpu"] atomically:YES];
        [bright writeToFile:[folder stringByAppendingPathComponent:@"bright.rpu"] atomically:YES];
        [[NSJSONSerialization dataWithJSONObject:facts options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil] writeToFile:[folder stringByAppendingPathComponent:@"surface.json"] atomically:YES];
    }
    [surface releaseSurface];
    assert(![surface.facts[@"currentMetadataSubmitted"] boolValue]);
    assert(![surface copyPresentedRPU] && ![surface copyPresentedHalfFloats]);
    assert(![surface prepareWidth:16384 height:16384]);
    assert(![surface presentPTS:NAN generation:3]);
    [window orderOut:nil]; window.contentView=nil; surface=nil;
    CGLSetCurrentContext(NULL); CGLReleaseContext(context);
    puts("PASS: payload, content changes, RGB values, bounded pool, paused redraw, seek, reset, failure guards; receiver unverified");
} return 0; }
