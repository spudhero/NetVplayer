// Research host only. Compile against the pinned upstream public headers.
// The library path is mandatory; this probe never falls back to a product library.
#import <AppKit/AppKit.h>
#import <OpenGL/gl3.h>
#include <dlfcn.h>
#include <math.h>
#include <mach-o/dyld.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>

#define API_LIST(X) \
    X(mpv_create) X(mpv_initialize) X(mpv_set_option_string) \
    X(mpv_get_property) X(mpv_get_property_string) X(mpv_free) \
    X(mpv_request_log_messages) X(mpv_wait_event) X(mpv_command) \
    X(mpv_terminate_destroy) X(mpv_render_context_create) \
    X(mpv_render_context_update) X(mpv_render_context_render) \
    X(mpv_render_context_report_swap) X(mpv_render_context_free)
#define DECLARE(name) static __typeof__(&name) p_##name;
API_LIST(DECLARE)

static void *gl_symbol(void *ctx, const char *name) {
    return dlsym(ctx, name);
}

static NSString *property(mpv_handle *mpv, const char *name) {
    char *value = p_mpv_get_property_string(mpv, name);
    NSString *result = value ? [NSString stringWithUTF8String:value] : @"";
    p_mpv_free(value);
    return result;
}

static double position(mpv_handle *mpv) {
    double value = -1;
    p_mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &value);
    return value;
}

typedef struct {
    mpv_handle *mpv;
    mpv_render_context *render;
    GLuint fbo;
    int width, height, frames, renderErrors;
    int backingWidth, backingHeight;
    bool loaded;
    NSMutableArray *logs;
} Host;

static void draw(Host *h) {
    mpv_opengl_fbo fbo = { (int)h->fbo, h->width, h->height, GL_RGBA8 };
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &fbo },
        { MPV_RENDER_PARAM_INVALID, NULL }
    };
    int result = p_mpv_render_context_render(h->render, params);
    if (result < 0) h->renderErrors++;
    else h->frames++;
    glFinish();
    glBindFramebuffer(GL_READ_FRAMEBUFFER,h->fbo);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,0);
    glBlitFramebuffer(0,0,h->width,h->height,0,0,h->backingWidth,h->backingHeight,
                      GL_COLOR_BUFFER_BIT,GL_NEAREST);
    glFlush();
    p_mpv_render_context_report_swap(h->render);
}

static void pump(Host *h, double seconds) {
    double deadline = NSDate.timeIntervalSinceReferenceDate + seconds;
    do {
        for (;;) {
            mpv_event *event = p_mpv_wait_event(h->mpv, 0);
            if (event->event_id == MPV_EVENT_NONE) break;
            if (event->event_id == MPV_EVENT_FILE_LOADED) h->loaded = true;
            if (event->event_id == MPV_EVENT_LOG_MESSAGE && h->logs.count < 1200) {
                mpv_event_log_message *log = event->data;
                [h->logs addObject:[NSString stringWithFormat:@"%s: %s", log->prefix, log->text]];
            }
        }
        if (h->render && (p_mpv_render_context_update(h->render) & MPV_RENDER_UPDATE_FRAME)) draw(h);
        NSEvent *event;
        while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:nil
                                            inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:event];
        [NSApp updateWindows];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
    } while (NSDate.timeIntervalSinceReferenceDate < deadline);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 6) {
            fprintf(stderr, "usage: host LIBRARY API MEDIA OUTPUT_DIRECTORY SUBTITLE_OR_DASH\n");
            return 2;
        }
        NSString *out = [NSString stringWithUTF8String:argv[4]];
        if ([NSFileManager.defaultManager fileExistsAtPath:out]) return 3;
        [NSFileManager.defaultManager createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableDictionary *report = [@{@"schema":@1, @"api":[NSString stringWithUTF8String:argv[2]],
            @"library":[NSString stringWithUTF8String:argv[1]], @"sample":[[NSString stringWithUTF8String:argv[3]] lastPathComponent],
            @"dolbyVisionSignalSent":@NO, @"felReconstructionVerified":@NO} mutableCopy];
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!library) { fprintf(stderr, "%s\n", dlerror()); return 4; }
#define LOAD(name) p_##name = dlsym(library, #name); if (!p_##name) return 5;
        API_LIST(LOAD)
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSOpenGLPixelFormatAttribute attributes[] = {
            NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
            NSOpenGLPFAAccelerated, NSOpenGLPFAColorSize, 24, 0
        };
        NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
        if (!format) return 6;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(120,120,640,360)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        window.title = @"NetVplayer isolated render API research";
        NSOpenGLView *view = [[NSOpenGLView alloc] initWithFrame:window.contentView.bounds pixelFormat:format];
        NSView *root = [[NSView alloc] initWithFrame:window.contentView.bounds];
        window.contentView = root;
        [root addSubview:view];
        NSTextField *overlay = [NSTextField labelWithString:@"Host overlay · render API research"];
        overlay.frame = NSMakeRect(15,320,520,25);
        overlay.textColor = NSColor.whiteColor;
        overlay.drawsBackground = YES;
        overlay.backgroundColor = NSColor.blackColor;
        [root addSubview:overlay];
        [view.openGLContext makeCurrentContext];
        void *gl = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_NOW|RTLD_LOCAL);
        Host h = { .mpv=p_mpv_create(), .width=640, .height=360, .logs=[NSMutableArray array] };
        if (!h.mpv) return 7;
        const char *options[][2] = {
            {"config","no"}, {"vo","libmpv"}, {"ao","null"}, {"hwdec","no"},
            {"keep-open","yes"}, {"osd-level","0"}, {"sub-auto","no"},
            {"target-prim","bt.709"}, {"target-trc","srgb"}, {"target-peak","203"},
            {"tone-mapping","bt.2390"}, {"dither-depth","no"}, {"fbo-format","rgba32f"}
        };
        NSMutableArray *optionErrors = [NSMutableArray array];
        for (unsigned i=0; i<sizeof(options)/sizeof(options[0]); i++) {
            int code = p_mpv_set_option_string(h.mpv, options[i][0], options[i][1]);
            if (code<0) [optionErrors addObject:@{@"name":@(options[i][0]), @"code":@(code)}];
        }
        report[@"optionErrors"] = optionErrors;
        int initialized = p_mpv_initialize(h.mpv);
        report[@"initializeCode"] = @(initialized);
        if (initialized<0) return 8;
        p_mpv_request_log_messages(h.mpv, "v");
        report[@"mpvVersion"] = property(h.mpv,"mpv-version");
        report[@"ffmpegVersion"] = property(h.mpv,"ffmpeg-version");
        mpv_opengl_init_params init = { gl_symbol, gl };
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_API_TYPE, (void *)argv[2]},
            {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &init},
            {MPV_RENDER_PARAM_INVALID, NULL}
        };
        int created = p_mpv_render_context_create(&h.render,h.mpv,params);
        report[@"renderContextCreateCode"] = @(created);
        GLuint texture=0;
        if (created>=0 && strcmp(argv[2],"opengl")==0) {
            glGenTextures(1,&texture); glBindTexture(GL_TEXTURE_2D,texture);
            glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,640,360,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
            glGenFramebuffers(1,&h.fbo); glBindFramebuffer(GL_FRAMEBUFFER,h.fbo);
            glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
            report[@"framebufferComplete"] = @(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE);
            [window orderFrontRegardless]; [NSApp activateIgnoringOtherApps:YES];
            [view.openGLContext update];
            NSRect backing = [view convertRectToBacking:view.bounds];
            h.backingWidth = (int)backing.size.width; h.backingHeight = (int)backing.size.height;
            const char *load[] = {"loadfile",argv[3],NULL};
            report[@"loadCode"] = @(p_mpv_command(h.mpv,load));
            for (int i=0;i<100 && (!h.loaded || position(h.mpv)<0.15 || h.frames<2);i++) pump(&h,0.05);
            p_mpv_set_option_string(h.mpv,"pause","yes"); pump(&h,0.1);
            double paused = position(h.mpv); pump(&h,0.2);
            report[@"pausedPosition"] = @(paused);
            report[@"pausedClockDelta"] = @(position(h.mpv)-paused);
            // Direct redraw while paused is an explicit render API contract.
            draw(&h);
            glBindFramebuffer(GL_FRAMEBUFFER,h.fbo);
            NSMutableData *pixels = [NSMutableData dataWithLength:640*360*4];
            glReadPixels(0,0,640,360,GL_RGBA,GL_UNSIGNED_BYTE,pixels.mutableBytes);
            [pixels writeToFile:[out stringByAppendingPathComponent:@"frame.rgba"] atomically:YES];
            report[@"readbackGLError"] = @(glGetError());
            if (strcmp(argv[5],"-")!=0) {
                const char *sub[] = {"sub-add",argv[5],"select","Research sidecar",NULL};
                report[@"subtitleCommandCode"] = @(p_mpv_command(h.mpv,sub)); pump(&h,0.2);
                report[@"subtitleTracks"] = property(h.mpv,"track-list");
                draw(&h); glBindFramebuffer(GL_FRAMEBUFFER,h.fbo);
                glReadPixels(0,0,640,360,GL_RGBA,GL_UNSIGNED_BYTE,pixels.mutableBytes);
                [pixels writeToFile:[out stringByAppendingPathComponent:@"subtitle.rgba"] atomically:YES];
            }
            const char *seek[] = {"seek","5","absolute+exact",NULL};
            report[@"seekCommandCode"] = @(p_mpv_command(h.mpv,seek));
            for(int i=0;i<100 && fabs(position(h.mpv)-5)>0.15;i++) pump(&h,0.03);
            pump(&h,0.15); report[@"seekPosition"] = @(position(h.mpv));
            report[@"activeVO"] = property(h.mpv,"current-vo");
            report[@"fileLoaded"] = @(h.loaded);
            report[@"submittedFrames"] = @(h.frames);
            report[@"renderErrors"] = @(h.renderErrors);
            report[@"sameClientAcrossPauseSubtitleAndSeek"] = @YES;
            const char *stop[] = {"stop",NULL}; p_mpv_command(h.mpv,stop); pump(&h,0.05);
        }
        if (h.render) p_mpv_render_context_free(h.render);
        p_mpv_terminate_destroy(h.mpv);
        if(h.fbo) glDeleteFramebuffers(1,&h.fbo);
        if(texture) glDeleteTextures(1,&texture);
        [window orderOut:nil];
        report[@"logs"] = h.logs;
        NSMutableArray *images = [NSMutableArray array];
        for(uint32_t i=0;i<_dyld_image_count();i++) {
            NSString *path = @(_dyld_get_image_name(i));
            if ([path hasPrefix:@"/opt/homebrew/"] || [path hasPrefix:@"/private/tmp/"])
                [images addObject:path];
        }
        report[@"loadedImages"] = images;
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
        [json writeToFile:[out stringByAppendingPathComponent:@"report.json"] atomically:YES];
        // The OS closes both libraries after all mpv and GL objects are gone.
        return 0;
    }
}
