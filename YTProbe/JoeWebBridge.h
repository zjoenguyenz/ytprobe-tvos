// JoeWebBridge — the CONTAINED runtime bridge to the WebKit
// framework that ships on every tvOS system but is excluded
// from the tvOS SDK (Apple HIG: web views are "Not supported
// in tvOS"). Design: TVB-YOUTUBE-TVOS-DESIGN-PLAN §2.2.
//
// This header is the ONLY surface Swift sees. It exposes
// plain Foundation/UIKit types; no WebKit type, symbol or
// header appears anywhere in it. The implementation resolves
// every WebKit class through the Objective-C runtime after a
// dlopen, so the app binary links ZERO WebKit symbols and the
// rest of the app has zero WebKit exposure. If the framework
// or any required class is missing, +webKitAvailable is NO
// and both bridge surfaces (YouTube player, Gold sign-in
// door) render their fail-soft explanation screen instead —
// the chain, the 803 tab and everything else in the app are
// untouched by a bridge failure.
//
// The bridge is MECHANICS ONLY: view hosting, URL loads,
// JavaScript evaluation, a poll timer, cookie-store access
// and remote-press capture. Every policy decision — the
// watchmax payload, the AUTO surface chain, the session
// rules — lives in Swift (JoeYtWeb.swift), where it can be
// reviewed in one place.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class JoeWebHostView;

/// Callbacks from a JoeWebHostView. All callbacks arrive on
/// the main queue (WebKit's own delivery queue; the poll
/// timer is scheduled on the main run loop).
@protocol JoeWebHostDelegate <NSObject>
- (void)joeHost:(JoeWebHostView *)host didPollResult:(nullable NSString *)result;
- (void)joeHostDidFinishLoad:(JoeWebHostView *)host;
- (void)joeHost:(JoeWebHostView *)host didFailLoadWithMessage:(NSString *)message;
- (void)joeHost:(JoeWebHostView *)host didRequestExitForURL:(NSString *)urlString;
/// The web content process died (memory/CPU limit, crash)
/// or stopped responding. tvOS kills it with NO warning to
/// the app (community research 2026-11-19, AIOStreamsTVOS
/// precedent); the Swift layer reloads the current URL and
/// seeks back to its poll-checkpointed position.
- (void)joeHostDidTerminateWebContent:(JoeWebHostView *)host;
@end

/// Navigation policy for a host.
/// - PlayerLockdown: only the locked watch URL (same host,
///   same /watch path, same video id) may navigate; any other
///   main-frame navigation is cancelled and reported as an
///   exit request, so the app leaves the player instead of
///   wandering YouTube's pages (design §2.5).
/// - DoorRoam: the sign-in door may roam the YouTube/Google
///   domains the official sign-in flow needs (design §3.2);
///   anything else is cancelled silently.
typedef NS_ENUM(NSInteger, JoeWebNavigationMode) {
    JoeWebNavigationModePlayerLockdown = 0,
    JoeWebNavigationModeDoorRoam = 1,
};

/// A UIView hosting one runtime-created WKWebView.
@interface JoeWebHostView : UIView

@property (nonatomic, weak, nullable) id<JoeWebHostDelegate> delegate;
@property (nonatomic) JoeWebNavigationMode navigationMode;
/// PlayerLockdown only: the exact watch URL this surface was
/// opened with. Compared by host + path + video id, not by
/// raw string, so YouTube's own consent bounce on the same
/// video still loads.
@property (nonatomic, copy, nullable) NSString *lockedURLString;
/// Marks the host as a playback surface. Playback presses
/// (Select / PlayPause = toggle, Down = next episode) are
/// routed at the WINDOW level — see
/// +setRemotePressConsumer: below — because WebKit's
/// content view is first responder over a playing page and
/// takes the presses itself (community research
/// 2026-11-19, AIOStreamsTVOS AppWindow precedent). This
/// flag now only governs page focus (focusContent).
@property (nonatomic) BOOL playbackPressesEnabled;

/// YT PROBE delta (2026-11-20): page focusability decoupled
/// from playbackPressesEnabled. When YES, the host may
/// become first responder / focused even on non-playback
/// surfaces (the sign-in door needs the remote to reach the
/// page: the owner's 2.0.41 test dead-ended on a passkey
/// page he could not move focus into).
@property (nonatomic) BOOL pageFocusEnabled;

/// YT PROBE delta (2026-11-20): factory for a host whose web
/// view is built with the private MediaSource preference
/// switch ATTEMPTED (see mediaSourceSwitchOutcome). The flag
/// must be known BEFORE the web view is created — the
/// configuration is copied at creation — so it arrives at
/// construction time, not as a later property set.
+ (instancetype)hostViewWithMediaSourceSwitch:(BOOL)enabled;

/// YT PROBE delta (2026-11-20, research Team 5 §3): the
/// PUBLIC lever on the same MediaSource policy —
/// WKWebpagePreferences.preferredContentMode = desktop,
/// installed as the configuration's defaultWebpagePreferences
/// (WebKit changeset 244197: the private preference is the
/// legacy form of this policy). Probe 1 pulls the levers
/// separately: neither / private only / content-mode only /
/// both.
+ (instancetype)hostViewWithMediaSourceSwitch:(BOOL)mse
                          contentModeDesktop:(BOOL)contentMode;

/// Outcome of the content-mode lever: 0 = not requested,
/// 1 = applied, 2 = unavailable on this system.
@property (nonatomic, readonly) NSInteger contentModeOutcome;

/// Outcome of the MediaSource switch attempt, readable after
/// construction: 0 = not requested, 1 = applied (a private
/// setter responded), 2 = no candidate setter exists on this
/// system, 3 = a setter responded but the value did not
/// stick (read back OFF).
@property (nonatomic, readonly) NSInteger mediaSourceSwitchOutcome;
/// The exact selector that accepted the switch, when one
/// did ("" when none / not requested). Probe evidence, not
/// a secret.
@property (nonatomic, copy, readonly) NSString *mediaSourceSelectorUsed;

/// YT PROBE delta (2026-11-20): adds a WKUserScript at
/// document start to this host's web view. Scripts added
/// after creation apply to SUBSEQUENT navigations, so the
/// caller installs before its first load. Used by the door
/// probe's capability masking and by nothing else.
- (void)addDocumentStartScript:(NSString *)source;

- (void)loadURLString:(NSString *)urlString userAgent:(nullable NSString *)userAgent;
- (void)evaluateJavaScript:(NSString *)js
                completion:(nullable void (^)(NSString * _Nullable result))completion;
/// Starts (or restarts) the poll: every `interval` seconds the
/// host evaluates `js` and reports the stringified result to
/// the delegate. One timer per host; starting again replaces.
- (void)startPollingWithInterval:(NSTimeInterval)interval javaScript:(NSString *)js;
- (void)stopPolling;
/// Re-asserts first responder (player surfaces: after a load
/// and whenever an overlay above the player closes).
- (void)focusContent;
@end

/// Store-level bridge services (no view needed): the default
/// — persistent — website data store's cookie store.
@interface JoeWebBridge : NSObject

/// YES when the on-system WebKit framework loads and exposes
/// the classes both surfaces need.
+ (BOOL)webKitAvailable;

/// Every cookie in the default store, as dictionaries with
/// name / value / domain / path / secure (NSNumber) and an
/// optional expires (NSDate). Used ONLY for the SAPISID
/// presence check and for writing the app's own cookie mirror
/// (the owner's own session, in his own app's sandbox —
/// design §3.3). Cookie values are never logged, shown or
/// sent anywhere by this layer or its callers.
+ (void)fetchAllCookiesWithCompletion:
    (void (^)(NSArray<NSDictionary<NSString *, id> *> *cookies))completion;

/// Writes cookies (same dictionary shape) back into the
/// default store — the mirror restore, called before a page
/// loads when the store has lost the session.
+ (void)restoreCookies:(NSArray<NSDictionary<NSString *, id> *> *)cookies
            completion:(void (^)(void))completion;

/// Window-level remote-press routing (community research
/// 2026-11-19): the first call installs a swizzle on
/// -[UIWindow sendEvent:] (idempotent). For every presses
/// event, the consumer is asked about each ENDED press
/// (UIPressType value); it returns YES to consume that
/// press (the event is then swallowed) or NO to let UIKit
/// deliver it normally (focus engine, buttons, the page).
/// MENU IS NEVER OFFERED to the consumer — it always
/// delivers, so SwiftUI's .onExitCommand exit path can
/// never be starved. Pass nil to unregister (the player
/// registers on appear and unregisters on disappear, so at
/// most one consumer exists at a time).
+ (void)setRemotePressConsumer:
    (nullable BOOL (^)(NSInteger pressType))consumer;
@end

NS_ASSUME_NONNULL_END
