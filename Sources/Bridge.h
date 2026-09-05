#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> *STApplyPolicy(WKWebView *view, BOOL running);
FOUNDATION_EXPORT BOOL STSetMuted(WKWebView *view, BOOL muted);
FOUNDATION_EXPORT BOOL STGetMuted(WKWebView *view);
FOUNDATION_EXPORT BOOL STInspector(WKWebView *view, NSString *command);
FOUNDATION_EXPORT BOOL STIsInspected(WKWebView *view);
FOUNDATION_EXPORT BOOL STIsPlayingAudio(WKWebView *view);
FOUNDATION_EXPORT void STCloseWebView(WKWebView *view);
NS_ASSUME_NONNULL_END
