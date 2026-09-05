#import "Bridge.h"
#import <objc/message.h>

// Optional WebKit SPI is capability checked and isolated from the browser UI.
static BOOL SetBool(id object, NSString *name, BOOL value) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return NO;
    @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value); return YES; }
    @catch (NSException *exception) { return NO; }
}
static BOOL GetBool(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return NO;
    @try { return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (NSException *exception) { return NO; }
}
NSDictionary<NSString *, NSNumber *> *STApplyPolicy(WKWebView *view, BOOL running) {
    WKPreferences *preferences = view.configuration.preferences;
    preferences.inactiveSchedulingPolicy = running ? WKInactiveSchedulingPolicyNone : WKInactiveSchedulingPolicySuspend;
    SetBool(preferences, @"_setDeveloperExtrasEnabled:", YES);
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSDictionary *switches = @{
        @"DOM timers": @"_setDOMTimersThrottlingEnabled:",
        @"Hidden timers": @"_setHiddenPageDOMTimerThrottlingEnabled:",
        @"Timer escalation": @"_setHiddenPageDOMTimerThrottlingAutoIncreases:",
        @"Process suppression": @"_setPageVisibilityBasedProcessSuppressionEnabled:",
        @"Web process App Nap": @"_setAppNapEnabled:"
    };
    [switches enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *selector, BOOL *stop) {
        result[key] = @(SetBool(preferences, selector, !running));
    }];
    result[@"Window occlusion"] = @(SetBool(view, @"_setWindowOcclusionDetectionEnabled:", !running));
    result[@"Inactive scheduling"] = @YES;
    result[@"Native mute"] = @([view respondsToSelector:NSSelectorFromString(@"_setPageMuted:")]);
    result[@"Inspector"] = @([view respondsToSelector:NSSelectorFromString(@"_inspector")]);
    return result;
}
BOOL STSetMuted(WKWebView *view, BOOL muted) {
    SEL selector = NSSelectorFromString(@"_setPageMuted:");
    if (![view respondsToSelector:selector]) return NO;
    @try {
        NSUInteger state = 0;
        SEL getter = NSSelectorFromString(@"_mediaMutedState");
        if ([view respondsToSelector:getter]) state = ((NSUInteger (*)(id, SEL))objc_msgSend)(view, getter);
        state = muted ? (state | 1UL) : (state & ~1UL);
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(view, selector, state);
        return YES;
    } @catch (NSException *exception) { return NO; }
}
BOOL STGetMuted(WKWebView *view) {
    SEL getter = NSSelectorFromString(@"_mediaMutedState");
    if (![view respondsToSelector:getter]) return NO;
    @try { return (((NSUInteger (*)(id, SEL))objc_msgSend)(view, getter) & 1UL) != 0; }
    @catch (NSException *exception) { return NO; }
}
BOOL STInspector(WKWebView *view, NSString *command) {
    NSSet *allowed = [NSSet setWithArray:@[@"show", @"hide", @"close", @"showConsole", @"showResources", @"toggleElementSelection", @"attach", @"detach"]];
    if (![allowed containsObject:command]) return NO;
    SEL getter = NSSelectorFromString(@"_inspector");
    if (![view respondsToSelector:getter]) return NO;
    @try {
        id inspector = ((id (*)(id, SEL))objc_msgSend)(view, getter);
        SEL selector = NSSelectorFromString(command);
        if (![inspector respondsToSelector:selector]) return NO;
        ((void (*)(id, SEL))objc_msgSend)(inspector, selector);
        return YES;
    } @catch (NSException *exception) { return NO; }
}
BOOL STIsInspected(WKWebView *view) { return GetBool(view, @"_isBeingInspected"); }
BOOL STIsPlayingAudio(WKWebView *view) { return GetBool(view, @"_isPlayingAudio"); }
void STCloseWebView(WKWebView *view) {
    [view stopLoading]; STInspector(view, @"close");
    SEL selector = NSSelectorFromString(@"_close");
    if ([view respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(view, selector);
}
