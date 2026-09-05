#import "WebKitBridge.h"
#import <objc/message.h>
// Optional WebKit selectors are isolated here. Each call verifies availability and catches Objective-C exceptions.
BOOL PKSetBoolean(id object, NSString *name, BOOL value) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return NO;
    @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value); return YES; }
    @catch (NSException *exception) { return NO; }
}
NSNumber *PKGetBoolean(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    @try { return @(((BOOL (*)(id, SEL))objc_msgSend)(object, selector)); }
    @catch (NSException *exception) { return nil; }
}
NSNumber *PKAudioMuted(WKWebView *view) {
    SEL getter = NSSelectorFromString(@"_mediaMutedState");
    if (![view respondsToSelector:getter]) return nil;
    @try { return @((((NSUInteger (*)(id, SEL))objc_msgSend)(view, getter) & 1UL) != 0); }
    @catch (NSException *exception) { return nil; }
}
BOOL PKMute(WKWebView *view, BOOL muted) {
    SEL setter = NSSelectorFromString(@"_setPageMuted:");
    SEL getter = NSSelectorFromString(@"_mediaMutedState");
    if (![view respondsToSelector:setter]) return NO;
    @try {
        // Preserve microphone/camera mute bits. Bit zero controls the page's audible output.
        NSUInteger state = [view respondsToSelector:getter] ? ((NSUInteger (*)(id, SEL))objc_msgSend)(view, getter) : 0;
        state = muted ? (state | 1UL) : (state & ~1UL);
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(view, setter, state);
        return YES;
    } @catch (NSException *exception) { return NO; }
}
BOOL PKInspector(WKWebView *view, NSString *action) {
    if (![@[@"show", @"showConsole", @"showResources", @"toggleElementSelection", @"close"] containsObject:action]) return NO;
    SEL getter = NSSelectorFromString(@"_inspector");
    if (![view respondsToSelector:getter]) return NO;
    @try {
        id inspector = ((id (*)(id, SEL))objc_msgSend)(view, getter);
        SEL selector = NSSelectorFromString(action);
        if (![inspector respondsToSelector:selector]) return NO;
        ((void (*)(id, SEL))objc_msgSend)(inspector, selector);
        return YES;
    } @catch (NSException *exception) { return NO; }
}
