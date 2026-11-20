// JoeWebBridge — implementation. See the header for the
// contract. Every WebKit class is resolved through the
// Objective-C runtime (NSClassFromString after a dlopen of
// the on-system framework); no WebKit header is imported and
// no WebKit symbol is linked. Selectors that exist only on
// WebKit classes are built with NSSelectorFromString and
// invoked through objc_msgSend with explicit signatures.
//
// ARC is assumed (the XcodeGen project's default): no
// explicit retain/release anywhere below.

#import "JoeWebBridge.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// MARK: - Runtime class resolution

static Class JoeWKClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (cls == Nil) {
        // The framework ships on the system but is not in
        // the SDK's link surface; pull it in explicitly.
        // Once-only: a failed dlopen simply leaves the class
        // missing, which +webKitAvailable reports. The three
        // paths are the community-proven set (AIOStreamsTVOS,
        // research 2026-11-19): standard, private, and the
        // Safari staged framework.
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            if (dlopen("/System/Library/Frameworks/WebKit.framework/WebKit",
                       RTLD_NOW | RTLD_GLOBAL) == NULL) {
                if (dlopen("/System/Library/PrivateFrameworks/WebKit.framework/WebKit",
                           RTLD_NOW | RTLD_GLOBAL) == NULL) {
                    dlopen("/System/Library/StagedFrameworks/Safari/WebKit.framework/WebKit",
                           RTLD_NOW | RTLD_GLOBAL);
                }
            }
        });
        cls = NSClassFromString(name);
    }
    return cls;
}

static id JoeMsgId0(id obj, SEL sel) {
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}
static void JoeMsgVoidId(id obj, SEL sel, id arg) {
    ((void (*)(id, SEL, id))objc_msgSend)(obj, sel, arg);
}
static void JoeMsgVoidBool(id obj, SEL sel, BOOL arg) {
    ((void (*)(id, SEL, BOOL))objc_msgSend)(obj, sel, arg);
}
static void JoeMsgVoidInsets(id obj, SEL sel, UIEdgeInsets arg) {
    ((void (*)(id, SEL, UIEdgeInsets))objc_msgSend)(obj, sel, arg);
}
static void JoeMsgVoidSizeSize(id obj, SEL sel, CGSize a, CGSize b) {
    ((void (*)(id, SEL, CGSize, CGSize))objc_msgSend)(obj, sel, a, b);
}

// MARK: - Cookie store access

static id JoeCookieStore(void) {
    Class storeClass = JoeWKClass(@"WKWebsiteDataStore");
    if (storeClass == Nil) { return nil; }
    id dataStore = JoeMsgId0(storeClass,
                             NSSelectorFromString(@"defaultDataStore"));
    if (dataStore == nil) { return nil; }
    return JoeMsgId0(dataStore, NSSelectorFromString(@"httpCookieStore"));
}

// MARK: - Window-level remote-press routing

@interface UIWindow (JoePressRouting)
+ (void)joe_installPressRouting;
- (void)joe_sendEvent:(UIEvent *)event;
@end

// The consumer block registered through
// +setRemotePressConsumer: (nil = nobody is routing).
// Written and read on the main thread only: registration
// happens from SwiftUI appear/disappear, sendEvent arrives
// on the main run loop.
static BOOL (^JoeRemotePressConsumer)(NSInteger pressType) = nil;

@implementation JoeWebBridge

+ (BOOL)webKitAvailable {
    return JoeWKClass(@"WKWebView") != Nil
        && JoeWKClass(@"WKWebViewConfiguration") != Nil
        && JoeWKClass(@"WKWebsiteDataStore") != Nil;
}

+ (void)setRemotePressConsumer:
    (BOOL (^)(NSInteger pressType))consumer {
    JoeRemotePressConsumer = [consumer copy];
    if (consumer != nil) {
        [UIWindow joe_installPressRouting];
    }
}

+ (void)fetchAllCookiesWithCompletion:
    (void (^)(NSArray<NSDictionary<NSString *, id> *> *))completion {
    id store = JoeCookieStore();
    if (store == nil) {
        completion(@[]);
        return;
    }
    void (^handler)(NSArray *) = [^(NSArray *cookies) {
        NSMutableArray<NSDictionary<NSString *, id> *> *out =
            [NSMutableArray arrayWithCapacity:cookies.count];
        for (NSHTTPCookie *cookie in cookies) {
            NSMutableDictionary<NSString *, id> *entry =
                [NSMutableDictionary dictionary];
            entry[@"name"] = cookie.name ?: @"";
            entry[@"value"] = cookie.value ?: @"";
            entry[@"domain"] = cookie.domain ?: @"";
            entry[@"path"] = cookie.path ?: @"/";
            entry[@"secure"] = @([cookie isSecure]);
            if (cookie.expiresDate != nil) {
                entry[@"expires"] = cookie.expiresDate;
            }
            [out addObject:entry];
        }
        completion(out);
    } copy];
    ((void (*)(id, SEL, id))objc_msgSend)(
        store, NSSelectorFromString(@"getAllCookies:"), handler);
}

+ (void)restoreCookies:(NSArray<NSDictionary<NSString *, id> *> *)cookies
            completion:(void (^)(void))completion {
    id store = JoeCookieStore();
    if (store == nil || cookies.count == 0) {
        completion();
        return;
    }
    // One completion handler per cookie; the caller's
    // completion fires when the last write lands. The
    // countdown is serialized on the main queue: the
    // exactly-once property of the caller's continuation
    // must not rest on which queue WebKit chooses for
    // these handlers (review MINOR, 2026-11-19).
    __block NSUInteger remaining = cookies.count;
    void (^oneDone)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            remaining -= 1;
            if (remaining == 0) { completion(); }
        });
    };
    for (NSDictionary<NSString *, id> *entry in cookies) {
        NSMutableDictionary<NSHTTPCookiePropertyKey, id> *props =
            [NSMutableDictionary dictionary];
        props[NSHTTPCookieName] = entry[@"name"];
        props[NSHTTPCookieValue] = entry[@"value"];
        props[NSHTTPCookieDomain] = entry[@"domain"];
        props[NSHTTPCookiePath] = entry[@"path"] ?: @"/";
        if (entry[@"expires"] != nil) {
            props[NSHTTPCookieExpires] = entry[@"expires"];
        }
        if ([entry[@"secure"] boolValue]) {
            props[NSHTTPCookieSecure] = @"TRUE";
        }
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:props];
        if (cookie == nil) {
            oneDone();
            continue;
        }
        void (^handler)(void) = [oneDone copy];
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            store, NSSelectorFromString(@"setCookie:completionHandler:"),
            cookie, handler);
    }
}

@end

// MARK: - Host view private interface
//
// This class extension MUST sit above JoeWebNavDelegate:
// the delegate messages the three joe_… selectors on its
// typed host pointer, and a class extension is visible
// only from the point it is parsed — declarations placed
// after the delegate's implementation would leave those
// sends with no visible @interface (a clang error).

@class JoeWebNavDelegate;

@interface JoeWebHostView ()
@property (nonatomic, strong, nullable) id webView;
@property (nonatomic, strong) JoeWebNavDelegate *navDelegate;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, copy, nullable) NSString *pollJavaScript;
// YT PROBE deltas (2026-11-20): construction-time MSE flag
// + readwrite redeclarations of the public readonly
// outcome properties.
@property (nonatomic) BOOL mediaSourceSwitchEnabled;
@property (nonatomic, readwrite) NSInteger mediaSourceSwitchOutcome;
@property (nonatomic, copy, readwrite) NSString *mediaSourceSelectorUsed;
@property (nonatomic) BOOL contentModeDesktopEnabled;
@property (nonatomic, readwrite) NSInteger contentModeOutcome;
- (BOOL)joe_allowNavigationAction:(id)navigationAction;
- (void)joe_loadFinished;
- (void)joe_loadFailedWithError:(NSError *)error;
- (void)joe_webContentTerminated;
@end

// MARK: - Navigation delegate (private)
//
// A plain NSObject. WKWebView talks to its navigation
// delegate purely by selector, so this class needs no
// protocol declaration (the protocol itself lives in the
// SDK we cannot import). It forwards to the host view,
// which owns the policy.

@interface JoeWebNavDelegate : NSObject
@property (nonatomic, weak) JoeWebHostView *host;
@end

@implementation JoeWebNavDelegate

- (void)webView:(id)webView
    decidePolicyForNavigationAction:(id)navigationAction
                    decisionHandler:(void (^)(NSInteger))decisionHandler {
    // WKNavigationActionPolicy: Cancel = 0, Allow = 1
    // (Download = 2 exists on newer systems and is NOT a
    // cancel — passing it here would be a live bug, so the
    // pair is written out in full).
    BOOL allow = [self.host joe_allowNavigationAction:navigationAction];
    decisionHandler(allow ? 1 : 0);
}

- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    [self.host joe_loadFinished];
}

- (void)webView:(id)webView
    didFailNavigation:(id)navigation
            withError:(NSError *)error {
    [self.host joe_loadFailedWithError:error];
}

- (void)webView:(id)webView
    didFailProvisionalNavigation:(id)navigation
                       withError:(NSError *)error {
    [self.host joe_loadFailedWithError:error];
}

// Private WKNavigationDelegate callbacks (selectors
// verified in shipped tvOS code, AIOStreamsTVOS — research
// 2026-11-19): WebKit invokes them by respondsToSelector,
// no protocol registration needed. tvOS ends the web
// content process under memory/CPU pressure with NO other
// warning; the host forwards both to Swift, which reloads
// the current URL and seeks back to the checkpoint.
- (void)_webView:(id)webView
    webContentProcessDidTerminateWithReason:(NSInteger)reason {
    (void)webView; (void)reason;
    [self.host joe_webContentTerminated];
}

- (void)_webViewWebProcessDidBecomeUnresponsive:(id)webView {
    (void)webView;
    [self.host joe_webContentTerminated];
}

@end

// MARK: - Host view

@implementation JoeWebHostView

- (instancetype)initWithFrame:(CGRect)frame {
    return [self initWithFrame:frame mediaSourceSwitch:NO contentModeDesktop:NO];
}

// YT PROBE delta (2026-11-20): the MSE flag must be set
// BEFORE joe_buildWebView runs — the web view copies its
// configuration at creation, so a preference set afterwards
// would never reach the page.
- (instancetype)initWithFrame:(CGRect)frame
           mediaSourceSwitch:(BOOL)enabled
          contentModeDesktop:(BOOL)contentMode {
    self = [super initWithFrame:frame];
    if (self) {
        _navigationMode = JoeWebNavigationModePlayerLockdown;
        _mediaSourceSwitchEnabled = enabled;
        _mediaSourceSwitchOutcome = 0;
        _mediaSourceSelectorUsed = @"";
        _contentModeDesktopEnabled = contentMode;
        _contentModeOutcome = 0;
        _navDelegate = [[JoeWebNavDelegate alloc] init];
        _navDelegate.host = self;
        [self joe_buildWebView];
    }
    return self;
}

+ (instancetype)hostViewWithMediaSourceSwitch:(BOOL)enabled {
    return [[self alloc] initWithFrame:CGRectZero
                     mediaSourceSwitch:enabled
                    contentModeDesktop:NO];
}

+ (instancetype)hostViewWithMediaSourceSwitch:(BOOL)mse
                          contentModeDesktop:(BOOL)contentMode {
    return [[self alloc] initWithFrame:CGRectZero
                     mediaSourceSwitch:mse
                    contentModeDesktop:contentMode];
}

- (void)dealloc {
    [_pollTimer invalidate];
    if (_webView != nil) {
        JoeMsgVoidId(_webView,
                     NSSelectorFromString(@"setNavigationDelegate:"), nil);
        ((void (*)(id, SEL))objc_msgSend)(
            _webView, NSSelectorFromString(@"stopLoading"));
    }
}

// The configuration mirrors the Sony WebView settings the
// watchmax proof ran under (design §2.2): JavaScript on, DOM
// storage on (WebKit's store default), the PERSISTENT
// (default) website data store — never a non-persistent one —
// and media playback without a user gesture.
- (void)joe_buildWebView {
    Class configClass = JoeWKClass(@"WKWebViewConfiguration");
    Class webViewClass = JoeWKClass(@"WKWebView");
    if (configClass == Nil || webViewClass == Nil) {
        self.webView = nil;
        return;
    }
    id config = [[configClass alloc] init];
    Class storeClass = JoeWKClass(@"WKWebsiteDataStore");
    if (storeClass != Nil) {
        id dataStore = JoeMsgId0(storeClass,
                                 NSSelectorFromString(@"defaultDataStore"));
        if (dataStore != nil) {
            JoeMsgVoidId(config,
                         NSSelectorFromString(@"setWebsiteDataStore:"),
                         dataStore);
        }
    }
    id preferences = JoeMsgId0(config, NSSelectorFromString(@"preferences"));
    if (preferences != nil) {
        JoeMsgVoidBool(preferences,
                       NSSelectorFromString(@"setJavaScriptEnabled:"), YES);
        // YT PROBE delta (2026-11-20) — THE MSE SWITCH.
        // tvOS WebKit ships with the MediaSource API OFF by
        // default (WebKit WebPreferences.yaml: MediaSource
        // defaults false on COCOA non-MAC), and YouTube's
        // desktop player is an MSE player — this is the
        // prime suspect for "Your browser can't play this
        // video". WKPreferencesPrivate declares the private
        // _mediaSourceEnabled property; WebKit changeset
        // 244197 documents the mechanism. The probe tries
        // the candidate setter spellings in order and
        // records exactly which one the system accepted
        // (or that none exists), then reads the value back.
        if (self.mediaSourceSwitchEnabled) {
            NSArray<NSString *> *candidates = @[
                @"_setMediaSourceEnabled:",
                @"set_mediaSourceEnabled:",
            ];
            BOOL applied = NO;
            for (NSString *name in candidates) {
                SEL setter = NSSelectorFromString(name);
                if ([preferences respondsToSelector:setter]) {
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(
                        preferences, setter, YES);
                    self.mediaSourceSelectorUsed = name;
                    applied = YES;
                    break;
                }
            }
            if (!applied) {
                // Last resort: KVC reaches the same storage
                // through whichever setter exists.
                @try {
                    [preferences setValue:@YES
                                   forKey:@"_mediaSourceEnabled"];
                    self.mediaSourceSelectorUsed = @"KVC:_mediaSourceEnabled";
                    applied = YES;
                } @catch (NSException *exception) {
                    (void)exception;
                }
            }
            if (!applied) {
                self.mediaSourceSwitchOutcome = 2;
            } else {
                // Read back: a setter that exists but does
                // not stick is a different fact than one that
                // works, and the probe exists to tell them
                // apart.
                BOOL stuck = NO;
                SEL getter = NSSelectorFromString(@"_mediaSourceEnabled");
                if ([preferences respondsToSelector:getter]) {
                    stuck = ((BOOL (*)(id, SEL))objc_msgSend)(
                        preferences, getter);
                }
                self.mediaSourceSwitchOutcome = stuck ? 1 : 3;
            }
        }
    }
    // Memory mitigation (community research 2026-11-19):
    // a desktop watch page is heavy and tvOS kills the web
    // content process under memory pressure with no warning.
    // Reporting devicePixelRatio = 1 at document start (the
    // AIOStreamsTVOS bridge-script trick) cuts the page's
    // raster/artwork memory. Installed as a document-start
    // user script on the configuration's content controller.
    Class uccClass = JoeWKClass(@"WKUserContentController");
    Class scriptClass = JoeWKClass(@"WKUserScript");
    if (uccClass != Nil && scriptClass != Nil) {
        id ucc = [[uccClass alloc] init];
        NSString *dprSource =
            @"Object.defineProperty(window,'devicePixelRatio',"
             "{get:function(){return 1;}});";
        // WKUserScriptInjectionTimeAtDocumentStart = 0.
        id script = [scriptClass alloc];
        script = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(
            script,
            NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:"),
            dprSource, (NSInteger)0, NO);
        if (script != nil) {
            JoeMsgVoidId(ucc, NSSelectorFromString(@"addUserScript:"),
                         script);
        }
        JoeMsgVoidId(config,
                     NSSelectorFromString(@"setUserContentController:"),
                     ucc);
    }
    // YT PROBE delta (2026-11-20): the content-mode lever.
    // WKWebpagePreferences (public class where WebKit is a
    // real SDK; here runtime-resolved like everything else)
    // with preferredContentMode = 2 (WKContentModeDesktop),
    // set as the configuration's defaultWebpagePreferences
    // BEFORE the web view is created.
    if (self.contentModeDesktopEnabled) {
        Class pagePrefsClass = JoeWKClass(@"WKWebpagePreferences");
        SEL setDefaultSel =
            NSSelectorFromString(@"setDefaultWebpagePreferences:");
        if (pagePrefsClass != Nil
            && [config respondsToSelector:setDefaultSel]) {
            id pagePrefs = [[pagePrefsClass alloc] init];
            SEL cmSel = NSSelectorFromString(@"setPreferredContentMode:");
            if (pagePrefs != nil && [pagePrefs respondsToSelector:cmSel]) {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(
                    pagePrefs, cmSel, (NSInteger)2);
                JoeMsgVoidId(config, setDefaultSel, pagePrefs);
                self.contentModeOutcome = 1;
            } else {
                self.contentModeOutcome = 2;
            }
        } else {
            self.contentModeOutcome = 2;
        }
    }
    SEL mediaSel =
        NSSelectorFromString(@"setMediaTypesRequiringUserActionForPlayback:");
    if ([config respondsToSelector:mediaSel]) {
        // WKAudiovisualMediaTypeNone = 0: nothing requires a
        // user gesture, so autoplay-with-sound can start.
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(config, mediaSel,
                                                      (NSUInteger)0);
    }
    // YT PROBE delta: the legacy configuration switch
    // beside the modern one (JoeTV fix item P-4) — guarded,
    // harmless where the modern property superseded it.
    SEL legacySel = NSSelectorFromString(@"setMediaPlaybackRequiresUserAction:");
    if ([config respondsToSelector:legacySel]) {
        JoeMsgVoidBool(config, legacySel, NO);
    }
    SEL inlineSel = NSSelectorFromString(@"setAllowsInlineMediaPlayback:");
    if ([config respondsToSelector:inlineSel]) {
        JoeMsgVoidBool(config, inlineSel, YES);
    }
    // alloc ONLY — the designated initializer
    // (initWithFrame:configuration:) is invoked on the
    // uninitialised object via msgSend below. A plain
    // -init first would initialise the web view with a
    // default configuration and then re-run the designated
    // initializer on a live object.
    id webView = [webViewClass alloc];
    webView = ((id (*)(id, SEL, CGRect, id))objc_msgSend)(
        webView, NSSelectorFromString(@"initWithFrame:configuration:"),
        self.bounds, config);
    if (webView == nil) {
        self.webView = nil;
        return;
    }
    JoeMsgVoidId(webView, NSSelectorFromString(@"setNavigationDelegate:"),
                 self.navDelegate);
    SEL gesturesSel =
        NSSelectorFromString(@"setAllowsBackForwardNavigationGestures:");
    if ([webView respondsToSelector:gesturesSel]) {
        JoeMsgVoidBool(webView, gesturesSel, NO);
    }
    // Inspectable from a Mac's Safari Develop menu — the
    // community bridge sets it and it is the only practical
    // way to debug the live watch page (research 2026-11-19).
    SEL inspectSel = NSSelectorFromString(@"setInspectable:");
    if ([webView respondsToSelector:inspectSel]) {
        JoeMsgVoidBool(webView, inspectSel, YES);
    }
    ((UIView *)webView).autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    ((UIView *)webView).frame = self.bounds;
    ((UIView *)webView).backgroundColor = UIColor.blackColor;
    [self addSubview:(UIView *)webView];
    self.webView = webView;
    self.backgroundColor = UIColor.blackColor;
    [self joe_applySafeAreaFix];
}

// The safe-area trap (VERIFIED in shipped tvOS code,
// research 2026-11-19): without these private calls WebKit
// lays the page out inside the tvOS safe area but draws
// from the screen's left edge, leaving a dead strip. All
// three are guarded; a missing selector simply skips.
- (void)joe_applySafeAreaFix {
    if (self.webView == nil) { return; }
    SEL insetsSel =
        NSSelectorFromString(@"_setUnobscuredSafeAreaInsets:");
    if ([self.webView respondsToSelector:insetsSel]) {
        JoeMsgVoidInsets(self.webView, insetsSel, UIEdgeInsetsZero);
    }
    SEL obscuredSel = NSSelectorFromString(@"_setObscuredInsets:");
    if ([self.webView respondsToSelector:obscuredSel]) {
        JoeMsgVoidInsets(self.webView, obscuredSel, UIEdgeInsetsZero);
    }
    SEL layoutSel = NSSelectorFromString(
        @"_overrideLayoutParametersWithMinimumLayoutSize:maximumUnobscuredSizeOverride:");
    if ([self.webView respondsToSelector:layoutSel]) {
        CGSize size = self.bounds.size;
        if (size.width <= 0 || size.height <= 0) {
            size = UIScreen.mainScreen.bounds.size;
        }
        JoeMsgVoidSizeSize(self.webView, layoutSel, size, size);
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    ((UIView *)self.webView).frame = self.bounds;
    [self joe_applySafeAreaFix];
}

// MARK: Loading + evaluation

- (void)loadURLString:(NSString *)urlString
            userAgent:(nullable NSString *)userAgent {
    if (self.webView == nil) {
        [self.delegate joeHost:self
            didFailLoadWithMessage:@"webview-unavailable"];
        return;
    }
    JoeMsgVoidId(self.webView,
                 NSSelectorFromString(@"setCustomUserAgent:"), userAgent);
    NSURL *url = [NSURL URLWithString:urlString];
    if (url == nil) {
        [self.delegate joeHost:self
            didFailLoadWithMessage:@"bad-url"];
        return;
    }
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    JoeMsgVoidId(self.webView, NSSelectorFromString(@"loadRequest:"),
                 request);
}

- (void)evaluateJavaScript:(NSString *)js
                completion:(void (^)(NSString * _Nullable))completion {
    if (self.webView == nil) {
        if (completion != nil) { completion(nil); }
        return;
    }
    void (^handler)(id, NSError *) = [^(id result, NSError *error) {
        NSString *string = nil;
        if ([result isKindOfClass:[NSString class]]) {
            string = (NSString *)result;
        } else if ([result isKindOfClass:[NSNumber class]]) {
            string = [(NSNumber *)result stringValue];
        }
        if (completion != nil) { completion(string); }
    } copy];
    ((void (*)(id, SEL, id, id))objc_msgSend)(
        self.webView,
        NSSelectorFromString(@"evaluateJavaScript:completionHandler:"),
        js, handler);
}

// MARK: Poll

- (void)startPollingWithInterval:(NSTimeInterval)interval
                      javaScript:(NSString *)js {
    [self stopPolling];
    self.pollJavaScript = js;
    __weak JoeWebHostView *weakSelf = self;
    self.pollTimer = [NSTimer
        scheduledTimerWithTimeInterval:interval
                               repeats:YES
                                 block:^(NSTimer *timer) {
        JoeWebHostView *strongSelf = weakSelf;
        if (strongSelf == nil) {
            [timer invalidate];
            return;
        }
        [strongSelf evaluateJavaScript:strongSelf.pollJavaScript
                            completion:^(NSString *result) {
            [strongSelf.delegate joeHost:strongSelf didPollResult:result];
        }];
    }];
}

- (void)stopPolling {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

// MARK: Navigation policy (called by the nav delegate)

- (BOOL)joe_allowNavigationAction:(id)navigationAction {
    id targetFrame = JoeMsgId0(navigationAction,
                               NSSelectorFromString(@"targetFrame"));
    BOOL isMainFrame = YES;
    if (targetFrame != nil) {
        isMainFrame = ((BOOL (*)(id, SEL))objc_msgSend)(
            targetFrame, NSSelectorFromString(@"isMainFrame"));
    }
    if (!isMainFrame) { return YES; }
    id request = JoeMsgId0(navigationAction,
                           NSSelectorFromString(@"request"));
    NSURL *url = JoeMsgId0(request, NSSelectorFromString(@"URL"));
    if (url == nil) { return NO; }
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if ([scheme isEqualToString:@"about"]) { return YES; }
    NSString *host = url.host.lowercaseString ?: @"";

    if (self.navigationMode == JoeWebNavigationModeDoorRoam) {
        // The official sign-in flow roams YouTube + Google
        // (design §3.2). Ancillary Google domains ride the
        // google.com / gstatic.com / googleapis.com suffixes.
        return [host isEqualToString:@"youtube.com"]
            || [host hasSuffix:@".youtube.com"]
            || [host isEqualToString:@"google.com"]
            || [host hasSuffix:@".google.com"]
            || [host isEqualToString:@"gstatic.com"]
            || [host hasSuffix:@".gstatic.com"]
            || [host isEqualToString:@"googleapis.com"]
            || [host hasSuffix:@".googleapis.com"]
            || [host isEqualToString:@"googleusercontent.com"]
            || [host hasSuffix:@".googleusercontent.com"];
    }

    // PlayerLockdown: the watch page for THE locked video
    // may load, and YouTube's own consent interstitial
    // (consent.youtube.com — the bounce that can precede a
    // watch page) may load with it. Anything else is an
    // exit request — the app returns to the detail screen
    // rather than wandering the site (design §2.5).
    if ([host isEqualToString:@"consent.youtube.com"]) {
        return YES;
    }
    BOOL onYouTube = [host isEqualToString:@"youtube.com"]
        || [host hasSuffix:@".youtube.com"]
        || [host isEqualToString:@"youtu.be"];
    if (onYouTube && self.lockedURLString != nil) {
        NSString *lockedVideo =
            [self joe_videoIdFromWatchURLString:self.lockedURLString];
        NSString *targetVideo =
            [self joe_videoIdFromWatchURLString:url.absoluteString];
        if (lockedVideo != nil && targetVideo != nil
            && [lockedVideo isEqualToString:targetVideo]) {
            return YES;
        }
    }
    [self.delegate joeHost:self
        didRequestExitForURL:url.absoluteString ?: @""];
    return NO;
}

- (nullable NSString *)joe_videoIdFromWatchURLString:(NSString *)string {
    NSURLComponents *components =
        [NSURLComponents componentsWithString:string];
    if (components == nil) { return nil; }
    if (![components.path isEqualToString:@"/watch"]) { return nil; }
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"v"]) { return item.value; }
    }
    return nil;
}

- (void)joe_loadFinished {
    [self.delegate joeHostDidFinishLoad:self];
}

- (void)joe_loadFailedWithError:(NSError *)error {
    // NSURLErrorCancelled (-999) rides along whenever a load
    // is superseded by the next one (surface step-down, next
    // episode) — it is not a failure and must not step the
    // AUTO chain down by itself; the poll's no-play timeout
    // owns that decision.
    if (error != nil && error.code == -999) { return; }
    [self.delegate joeHost:self
        didFailLoadWithMessage:error.localizedDescription ?: @"load-error"];
}

- (void)joe_webContentTerminated {
    [self.delegate joeHostDidTerminateWebContent:self];
}

// MARK: Page focus + remote presses
//
// Playback presses are routed at the WINDOW level (see
// +setRemotePressConsumer: on JoeWebBridge below): WebKit's
// content view is first responder over a playing page and
// takes the presses itself, so a hosting-view pressesEnded
// never sees them (community research 2026-11-19,
// AIOStreamsTVOS). What remains here is page FOCUS: the
// page takes focus through its internal WKContentView
// subview, re-asserted after every load and whenever an
// overlay above the player closes — an overlay that took
// focus does not hand it back by itself.

// YT PROBE delta (2026-11-20): focusability is
// playbackPressesEnabled OR pageFocusEnabled — the door
// (JoeTV fix item D-1) needs the page focusable with
// playback presses off.
- (BOOL)joe_focusable {
    return self.playbackPressesEnabled || self.pageFocusEnabled;
}

- (BOOL)canBecomeFirstResponder {
    return [self joe_focusable];
}

- (BOOL)canBecomeFocused {
    return [self joe_focusable];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window != nil && [self joe_focusable]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self focusContent];
        });
    }
}

- (void)focusContent {
    if (![self joe_focusable] || self.webView == nil) {
        return;
    }
    UIView *content = [self joe_contentViewIn:(UIView *)self.webView];
    if (content != nil) {
        [content becomeFirstResponder];
    } else if ([self.webView respondsToSelector:@selector(becomeFirstResponder)]) {
        [(UIView *)self.webView becomeFirstResponder];
    }
}

- (nullable UIView *)joe_contentViewIn:(UIView *)root {
    for (UIView *sub in root.subviews) {
        if ([NSStringFromClass(sub.class)
                hasPrefix:@"WKContentView"]) {
            return sub;
        }
        UIView *found = [self joe_contentViewIn:sub];
        if (found != nil) { return found; }
    }
    return nil;
}

// YT PROBE delta (2026-11-20): document-start user script
// on the ALREADY-BUILT web view's configuration content
// controller. WebKit applies scripts added after creation
// to subsequent navigations — callers install before their
// first load (the door probe's masking does exactly that).
- (void)addDocumentStartScript:(NSString *)source {
    if (self.webView == nil || source == nil) { return; }
    id config = JoeMsgId0(self.webView, NSSelectorFromString(@"configuration"));
    id ucc = config != nil
        ? JoeMsgId0(config, NSSelectorFromString(@"userContentController"))
        : nil;
    Class scriptClass = JoeWKClass(@"WKUserScript");
    if (ucc == nil || scriptClass == Nil) { return; }
    id script = [scriptClass alloc];
    script = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(
        script,
        NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:"),
        source, (NSInteger)0, YES);
    if (script != nil) {
        JoeMsgVoidId(ucc, NSSelectorFromString(@"addUserScript:"), script);
    }
}

@end

// MARK: - UIWindow press routing (implementation)
//
// Installed once, on the first consumer registration:
// -[UIWindow sendEvent:] is exchanged with joe_sendEvent:.
// The routing mirrors the shipped AIOStreamsTVOS pattern
// (research 2026-11-19): presses are decided BEFORE UIKit
// hands them to WebKit's first-responder content view.
// Only ENDED presses are offered (the app's remote model
// acts on release, like pressesEnded did); an event is
// swallowed only when a consumer exists and consumes every
// ended press in it. Menu is never offered — it always
// delivers, so .onExitCommand can never be starved.

@implementation UIWindow (JoePressRouting)

+ (void)joe_installPressRouting {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(
            UIWindow.class, @selector(sendEvent:));
        Method routing = class_getInstanceMethod(
            UIWindow.class, @selector(joe_sendEvent:));
        if (original != NULL && routing != NULL) {
            method_exchangeImplementations(original, routing);
        }
    });
}

- (void)joe_sendEvent:(UIEvent *)event {
    BOOL (^consumer)(NSInteger) = JoeRemotePressConsumer;
    if (consumer != nil && event.type == UIEventTypePresses
        && [event isKindOfClass:[UIPressesEvent class]]) {
        // Presses ride the UIPressesEvent SUBCLASS of
        // UIEvent, and allPresses is declared on the
        // subclass, not the base class (reading it on a
        // UIEvent * was CI run #18's only error). The
        // class check keeps the routing semantics
        // identical — the same press set is iterated —
        // and a presses-type event that is somehow not
        // the subclass simply delivers untouched below
        // instead of raising on the missing property.
        NSSet<UIPress *> *allPresses =
            ((UIPressesEvent *)event).allPresses;
        // Pass 1: Menu anywhere in the event delivers the
        // whole event untouched — checked BEFORE any press
        // is offered, so the invariant never depends on the
        // (unordered) set's iteration order (review MINOR,
        // 2026-11-19).
        BOOL hasMenu = NO;
        for (UIPress *press in allPresses) {
            if (press.type == UIPressTypeMenu) { hasMenu = YES; break; }
        }
        if (!hasMenu) {
            BOOL sawEnded = NO;
            BOOL allConsumed = YES;
            for (UIPress *press in allPresses) {
                if (press.phase != UIPressPhaseEnded) { continue; }
                sawEnded = YES;
                if (!consumer((NSInteger)press.type)) {
                    allConsumed = NO;
                    break;
                }
            }
            if (sawEnded && allConsumed) {
                return; // swallowed: the consumer handled it
            }
        }
    }
    // After the exchange, this selector IS the original
    // -[UIWindow sendEvent:] — deliver normally.
    [self joe_sendEvent:event];
}

@end
