// HDMV research host only. Public libmpv API; no product runtime replacement.
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
    X(mpv_get_property) X(mpv_get_property_string) X(mpv_free) X(mpv_free_node_contents) \
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
    int fileLoads, endFiles, playbackRestarts, droppedLogs;
    double started;
    bool loaded;
    NSMutableArray *logs;
} Host;

static void draw(Host *h) {
    mpv_opengl_fbo fbo = { (int)h->fbo, h->width, h->height, GL_RGBA8 };
    int flip = 1;
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &fbo },
        { MPV_RENDER_PARAM_FLIP_Y, &flip },
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
            if (event->event_id == MPV_EVENT_FILE_LOADED) { h->loaded = true; h->fileLoads++; }
            if (event->event_id == MPV_EVENT_END_FILE) h->endFiles++;
            if (event->event_id == MPV_EVENT_PLAYBACK_RESTART) h->playbackRestarts++;
            if (event->event_id == MPV_EVENT_LOG_MESSAGE && h->logs.count < 20000) {
                mpv_event_log_message *log = event->data;
                [h->logs addObject:[NSString stringWithFormat:@"%.6f %s: %s", NSDate.timeIntervalSinceReferenceDate-h->started, log->prefix, log->text]];
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

static id node_value(mpv_node *n) {
    switch (n->format) {
        case MPV_FORMAT_STRING: return n->u.string ? @(n->u.string) : @"";
        case MPV_FORMAT_FLAG: return @(n->u.flag != 0);
        case MPV_FORMAT_INT64: return @(n->u.int64);
        case MPV_FORMAT_DOUBLE: return isfinite(n->u.double_) ? @(n->u.double_) : NSNull.null;
        case MPV_FORMAT_NODE_ARRAY: {
            NSMutableArray *out = [NSMutableArray array];
            for (int i=0;i<n->u.list->num;i++) [out addObject:node_value(&n->u.list->values[i])];
            return out;
        }
        case MPV_FORMAT_NODE_MAP: {
            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            for (int i=0;i<n->u.list->num;i++) out[@(n->u.list->keys[i])] = node_value(&n->u.list->values[i]);
            return out;
        }
        default: return NSNull.null;
    }
}

static NSDictionary *snapshot(Host *h, NSString *name, NSString *out) {
    NSMutableDictionary *result = [@{@"name":name,
        @"wallSeconds":@(NSDate.timeIntervalSinceReferenceDate-h->started),
        @"renderedFrames":@(h->frames), @"renderErrors":@(h->renderErrors),
        @"fileLoads":@(h->fileLoads), @"endFiles":@(h->endFiles),
        @"playbackRestarts":@(h->playbackRestarts)} mutableCopy];
    const char *props[] = {"time-pos","duration","pause","eof-reached","idle-active",
        "disc-menu-active","edition","edition-list","chapter","chapter-list","angle",
        "aid","sid","secondary-sid","track-list","current-vo","video-params","audio-params"};
    for (unsigned i=0;i<sizeof(props)/sizeof(props[0]);i++) {
        mpv_node node = {0};
        int code = p_mpv_get_property(h->mpv,props[i],MPV_FORMAT_NODE,&node);
        result[@(props[i])] = code >= 0 ? node_value(&node) : @{@"error":@(code)};
        if (code >= 0) p_mpv_free_node_contents(&node);
    }
    if (h->render && h->fbo) {
        draw(h);
        glBindFramebuffer(GL_FRAMEBUFFER,h->fbo);
        NSMutableData *pixels = [NSMutableData dataWithLength:h->width*h->height*4];
        glReadPixels(0,0,h->width,h->height,GL_RGBA,GL_UNSIGNED_BYTE,pixels.mutableBytes);
        NSString *file = [name stringByAppendingString:@".rgba"];
        [pixels writeToFile:[out stringByAppendingPathComponent:file] atomically:YES];
        result[@"pixels"] = file;
        result[@"glError"] = @(glGetError());
    }
    return result;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 5) {
            fprintf(stderr,"usage: host LIBRARY DISC_PATH SCENARIO_JSON NEW_OUTPUT_DIRECTORY\n");
            return 2;
        }
        NSString *out = @(argv[4]);
        if ([NSFileManager.defaultManager fileExistsAtPath:out]) return 3;
        NSData *input = [NSData dataWithContentsOfFile:@(argv[3])];
        NSDictionary *scenario = input ? [NSJSONSerialization JSONObjectWithData:input options:0 error:nil] : nil;
        if (![scenario[@"steps"] isKindOfClass:NSArray.class]) return 2;
        [NSFileManager.defaultManager createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableDictionary *report = [@{@"schema":@1, @"scope":@"isolated public libmpv OpenGL host",
            @"productMenuAcceptancePassed":@NO, @"realDiscMatrixPassed":@NO,
            @"library":@(argv[1]), @"scenario":scenario} mutableCopy];
        void *library = dlopen(argv[1], RTLD_NOW|RTLD_LOCAL);
        if (!library) { fprintf(stderr,"%s\n",dlerror()); return 4; }
#define LOAD(name) p_##name = dlsym(library,#name); if (!p_##name) return 5;
        API_LIST(LOAD)
#undef LOAD
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSOpenGLPixelFormatAttribute attributes[] = {NSOpenGLPFAOpenGLProfile,
            NSOpenGLProfileVersion3_2Core,NSOpenGLPFAAccelerated,NSOpenGLPFAColorSize,24,0};
        NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
        if (!format) return 6;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100,120,640,360)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable
            backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        window.title = @"HDMV public API research";
        NSOpenGLView *view = [[NSOpenGLView alloc] initWithFrame:window.contentView.bounds pixelFormat:format];
        window.contentView = view;
        [view.openGLContext makeCurrentContext];
        void *gl = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL",RTLD_NOW|RTLD_LOCAL);
        Host h = {.mpv=p_mpv_create(),.width=640,.height=360,.logs=[NSMutableArray array],
                  .started=NSDate.timeIntervalSinceReferenceDate};
        if (!h.mpv) return 7;
        const char *options[][2] = {{"config","no"},{"vo","libmpv"},{"ao","null"},
            {"hwdec","no"},{"keep-open","yes"},{"osd-level","0"},{"sub-auto","no"},
            {"osc","no"},{"ytdl","no"},{"cache","no"},
            {"disc-menu","yes"},{"bluray-device",argv[2]},
            {"target-prim","bt.709"},{"target-trc","srgb"},{"dither-depth","no"}};
        NSMutableArray *optionErrors = [NSMutableArray array];
        for (unsigned i=0;i<sizeof(options)/sizeof(options[0]);i++) {
            int code = p_mpv_set_option_string(h.mpv,options[i][0],options[i][1]);
            if (code<0) [optionErrors addObject:@{@"name":@(options[i][0]),@"code":@(code)}];
        }
        report[@"optionErrors"] = optionErrors;
        for (NSString *key in scenario[@"options"]) {
            int code=p_mpv_set_option_string(h.mpv,key.UTF8String,[scenario[@"options"][key] UTF8String]);
            if(code<0) [optionErrors addObject:@{@"name":key,@"code":@(code)}];
        }
        report[@"initializeCode"] = @(p_mpv_initialize(h.mpv));
        p_mpv_request_log_messages(h.mpv,"debug");
        report[@"mpvVersion"] = property(h.mpv,"mpv-version");
        report[@"ffmpegVersion"] = property(h.mpv,"ffmpeg-version");
        mpv_opengl_init_params init = {gl_symbol,gl};
        mpv_render_param params[] = {{MPV_RENDER_PARAM_API_TYPE,"opengl"},
            {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,&init},{MPV_RENDER_PARAM_INVALID,NULL}};
        int created = p_mpv_render_context_create(&h.render,h.mpv,params);
        report[@"renderContextCreateCode"] = @(created);
        GLuint texture=0;
        NSMutableArray *steps = [NSMutableArray array];
        if (created>=0) {
            glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);
            glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,640,360,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
            glGenFramebuffers(1,&h.fbo);glBindFramebuffer(GL_FRAMEBUFFER,h.fbo);
            glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
            report[@"framebufferComplete"] = @(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE);
            [window orderFrontRegardless];[NSApp activateIgnoringOtherApps:YES];[view.openGLContext update];
            NSRect backing = [view convertRectToBacking:view.bounds];
            h.backingWidth=backing.size.width;h.backingHeight=backing.size.height;
            const char *load[] = {"loadfile","bd://",NULL};
            report[@"loadCode"] = @(p_mpv_command(h.mpv,load));
            for (NSDictionary *step in scenario[@"steps"]) {
                NSMutableDictionary *record = [NSMutableDictionary dictionary];
                NSArray *command = step[@"command"];
                if (command) {
                    if (command.count>16) return 2;
                    const char *args[17]={0};
                    for(NSUInteger i=0;i<command.count;i++) args[i]=[command[i] UTF8String];
                    record[@"command"] = command;
                    record[@"code"] = @(p_mpv_command(h.mpv,args));
                }
                double seconds = step[@"wait"] ? [step[@"wait"] doubleValue] : 0.5;
                pump(&h,fmin(fmax(seconds,0),30));
                NSString *name=step[@"name"];
                if (!name || [name containsString:@"/"] || [name containsString:@".."]) return 2;
                record[@"snapshot"] = snapshot(&h,name,out);
                [steps addObject:record];
            }
            const char *stop[]={"stop",NULL};
            report[@"stopCode"]=@(p_mpv_command(h.mpv,stop));pump(&h,0.1);
        }
        report[@"steps"]=steps;report[@"logs"]=h.logs;
        report[@"logsTruncated"]=@(h.logs.count>=20000);
        report[@"fileLoads"]=@(h.fileLoads);report[@"endFiles"]=@(h.endFiles);
        report[@"renderErrors"]=@(h.renderErrors);
        NSMutableArray *images=[NSMutableArray array];
        for(uint32_t i=0;i<_dyld_image_count();i++) {
            NSString *path=@(_dyld_get_image_name(i));
            if([path hasPrefix:@"/opt/homebrew/"]||[path hasPrefix:@"/private/tmp/"]) [images addObject:path];
        }
        report[@"loadedImages"]=images;
        if(h.render) p_mpv_render_context_free(h.render);
        p_mpv_terminate_destroy(h.mpv);
        if(h.fbo) glDeleteFramebuffers(1,&h.fbo);
        if(texture) glDeleteTextures(1,&texture);
        [window orderOut:nil];
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
        if(!json || ![json writeToFile:[out stringByAppendingPathComponent:@"report.json"] atomically:YES]) return 9;
        return 0;
    }
}
