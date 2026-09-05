#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
NS_ASSUME_NONNULL_BEGIN
BOOL PKSetBoolean(id object, NSString *setter, BOOL value);
NSNumber * _Nullable PKGetBoolean(id object, NSString *getter);
BOOL PKMute(WKWebView *view, BOOL muted);
NSNumber * _Nullable PKAudioMuted(WKWebView *view);
BOOL PKInspector(WKWebView *view, NSString *action);
NS_ASSUME_NONNULL_END
