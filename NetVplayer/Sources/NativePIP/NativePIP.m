#import "NativePIP.h"
#import <objc/runtime.h>

// Selector declarations describe the runtime ABI, not a linked private class.
@interface NSViewController (NVPIPRuntime)
- (void)setDelegate:(id)delegate;
- (void)setReplacementWindow:(NSWindow *)window;
- (void)setReplacementRect:(NSRect)rect;
- (void)setAspectRatio:(NSSize)size;
- (void)setUserCanResize:(bool)resize;
- (void)setPlaying:(bool)playing;
- (void)presentViewControllerAsPictureInPicture:(NSViewController *)content;
@end

static BOOL signature(Class cls, SEL selector, const char *argument) {
    NSMethodSignature *s = [cls instanceMethodSignatureForSelector:selector];
    return s && s.numberOfArguments == 3 && strcmp(s.methodReturnType, @encode(void)) == 0
        && strcmp([s getArgumentTypeAtIndex:2], argument) == 0;
}
static Class compatibleClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            if (![[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/PIP.framework"] load]) return;
            Class candidate = NSClassFromString(@"PIPViewController");
            if (![candidate isSubclassOfClass:NSViewController.class]) return;
            if (!signature(candidate, @selector(setDelegate:), @encode(id))
                || !signature(candidate, @selector(setReplacementWindow:), @encode(id))
                || !signature(candidate, @selector(setReplacementRect:), @encode(NSRect))
                || !signature(candidate, @selector(setAspectRatio:), @encode(NSSize))
                || !signature(candidate, @selector(setPlaying:), @encode(bool))
                || !signature(candidate, @selector(setUserCanResize:), @encode(bool))
                || !signature(candidate, @selector(presentViewControllerAsPictureInPicture:), @encode(id))
                || !signature(candidate, @selector(dismissViewController:), @encode(id))) return;
            cls = candidate;
        } @catch (__unused NSException *exception) { cls = Nil; }
    });
    return cls;
}

@implementation NVPictureInPicture {
    NSViewController *_controller;
    NSViewController *_content;
    __weak NSWindow *_sourceWindow;
}
+ (BOOL)available { return compatibleClass() != Nil; }
- (BOOL)present:(NSViewController *)content window:(NSWindow *)window rect:(NSRect)rect aspect:(NSSize)aspect playing:(BOOL)playing {
    if (_controller || !NSThread.isMainThread || !compatibleClass()) return NO;
    @try {
        _controller = [[compatibleClass() alloc] init];
        _content = content;
        _sourceWindow = window;
        [_controller setDelegate:self];
        [_controller setReplacementWindow:window];
        [_controller setReplacementRect:rect];
        [_controller setAspectRatio:aspect];
        [_controller setUserCanResize:true];
        [_controller setPlaying:playing];
        [_controller presentViewControllerAsPictureInPicture:content];
        return YES;
    } @catch (__unused NSException *exception) { [self invalidate]; return NO; }
}
- (BOOL)dismiss {
    @try {
        if (!_controller || !_content) return NO;
        [_controller dismissViewController:_content];
        return YES;
    } @catch (__unused NSException *exception) { return NO; }
}
- (void)setPlaying:(BOOL)playing {
    @try { [_controller setPlaying:playing]; } @catch (__unused NSException *exception) { }
}
- (void)invalidate {
    self.eventHandler = nil;
    @try {
        [_controller setDelegate:nil];
        NSWindow *window = _content.view.window;
        if (_controller && _content) [_controller dismissViewController:_content];
        // Failed/late native transitions must not retain an orphan player window.
        if (window && window != _sourceWindow) [window orderOut:nil];
    } @catch (__unused NSException *exception) { }
    _content = nil; _controller = nil; _sourceWindow = nil;
}
- (void)emit:(NSString *)event controller:(id)controller {
    if (controller == _controller && self.eventHandler) self.eventHandler(event);
}
- (BOOL)pipShouldClose:(id)pip { [self emit:@"return" controller:pip]; return NO; }
- (void)pipWillClose:(id)pip { [self emit:@"willClose" controller:pip]; }
- (void)pipDidClose:(id)pip { [self emit:@"closed" controller:pip]; }
- (void)pipActionPlay:(id)pip { [self emit:@"play" controller:pip]; }
- (void)pipActionPause:(id)pip { [self emit:@"pause" controller:pip]; }
- (void)pipActionStop:(id)pip { [self emit:@"stop" controller:pip]; }
@end
