import SwiftUI

// MARK: - YT Probe web layer
//
// Copied from JoeTV's JoeYtWeb.swift (the player/door web
// layer, itself carried from the Sony proof) with probe-only
// additions marked PROBE. The containment rule is unchanged:
// JoeWebBridge (ObjC) is mechanics only; no WebKit type or
// symbol appears in Swift. Cookie VALUES are never logged,
// shown or sent anywhere — presence only.

enum ProbeJS {
    /// Desktop Chrome UA (JoeTV player surfaces 0/1 today).
    static let desktopChromeUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// Desktop SAFARI UA (JoeTV's door UA; probe item P-1's
    /// candidate for the player surfaces).
    static let safariUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    /// Mobile Safari UA (iPhone) — Probe 6's identity.
    static let mobileUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.7 Mobile/15E148 Safari/604.1"

    /// The watchmax CSS injection (Sony-proven, verbatim
    /// from JoeTV). ⛔ #page-manager must NEVER enter the
    /// hide-list (ancestor of #movie_player).
    static let injectWatchmaxCSS = """
        (function(){
          if (document.getElementById('tvbyt-max-css')) { return 'already'; }
          var s = document.createElement('style');
          s.id = 'tvbyt-max-css';
          s.textContent = 'html,body{overflow:hidden!important;background:#000!important}'
            + '#movie_player{position:fixed!important;left:0!important;top:0!important;width:100vw!important;height:100vh!important;z-index:2147483647!important;background:#000!important}'
            + '#masthead-container,#secondary,#below,#comments,#related,#footer{display:none!important}';
          document.head.appendChild(s);
          window.dispatchEvent(new Event('resize'));
          return 'injected';
        })()
        """

    /// State poll — verbatim from JoeTV (the #movie_player
    /// API is authoritative; the element corroborates; the
    /// .ytp-error text and the pin check ride along).
    static let poll = """
        (function(){
          var v = document.querySelector('video');
          var p = document.getElementById('movie_player');
          var err = '';
          var e = document.querySelector('.ytp-error');
          if (e) { err = (e.innerText || '').slice(0, 120); }
          var pin = 0;
          if (p) {
            var r = p.getBoundingClientRect();
            if (Math.abs(r.width - window.innerWidth) < 2
                && Math.abs(r.height - window.innerHeight) < 2) { pin = 1; }
          }
          var state = -99, vid = '', t = 0, d = 0, api = 0;
          try {
            if (p && p.getPlayerState) {
              api = 1;
              state = p.getPlayerState();
              if (p.getCurrentTime) { t = p.getCurrentTime() || 0; }
              if (p.getDuration) { d = p.getDuration() || 0; }
              if (p.getVideoData) {
                var vd = p.getVideoData();
                vid = (vd && (vd.video_id || vd.videoId)) || '';
              }
            }
          } catch (ex) { api = 0; state = -99; }
          if (v) {
            if (!(d > 0) && isFinite(v.duration)) { d = v.duration; }
            if (!t && isFinite(v.currentTime)) { t = v.currentTime; }
          }
          var playing, ended, paused;
          if (api) {
            playing = (state === 1);
            ended = (state === 0);
            paused = (state === 2);
          } else {
            playing = !!(v && !v.paused && !v.ended && v.readyState > 2);
            ended = !!(v && v.ended);
            paused = !!(v && v.paused);
          }
          return JSON.stringify({
            has: !!v, api: api, state: state, vid: vid,
            playing: playing, paused: paused, ended: ended,
            muted: !!(v && v.muted),
            t: t, d: d,
            pin: pin, err: err, url: location.href
          });
        })()
        """

    /// Play/pause toggle — the exact payload the production
    /// remote path evaluates (window press consumer →
    /// togglePlay). Through the player object first.
    static let togglePlay = """
        (function(){
          var p = document.getElementById('movie_player');
          try {
            if (p && p.getPlayerState) {
              if (p.getPlayerState() === 1) { p.pauseVideo(); return 'pause'; }
              p.playVideo(); return 'play';
            }
          } catch (ex) {}
          var v = document.querySelector('video');
          if (!v) { return 'novideo'; }
          if (v.paused) { v.play(); return 'play'; }
          v.pause(); return 'pause';
        })()
        """

    /// Startup nudge (JoeTV verbatim): unmute + play before
    /// first play only.
    static let nudgePlay = """
        (function(){
          var v = document.querySelector('video');
          if (!v) { return 'novideo'; }
          if (v.muted) { v.muted = false; }
          if (v.paused) { v.play(); }
          return 'nudged';
        })()
        """

    /// PROBE: the capability snapshot (Probe 1 + every page
    /// probe's opening read). Reports what the page's engine
    /// actually exposes: UA, MediaSource / ManagedMediaSource
    /// presence, and isTypeSupported for the codec set the
    /// research specified.
    static let capability = """
        (function(){
          var ms = typeof window.MediaSource;
          var mms = typeof window.ManagedMediaSource;
          function sup(mime) {
            if (ms === 'undefined' || !window.MediaSource.isTypeSupported) { return 'n/a'; }
            try { return window.MediaSource.isTypeSupported(mime) ? 'yes' : 'no'; }
            catch (e) { return 'err'; }
          }
          return JSON.stringify({
            ua: navigator.userAgent, ms: ms, mms: mms,
            avc: sup('video/mp4; codecs="avc1.640028"'),
            avcAac: sup('video/mp4; codecs="avc1.640028, mp4a.40.2"'),
            aac: sup('audio/mp4; codecs="mp4a.40.2"'),
            vp9: sup('video/webm; codecs="vp09.00.10.08"'),
            hevc: sup('video/mp4; codecs="hev1.1.6.L150"')
          });
        })()
        """

    /// PROBE: leanback (youtube.com/tv) read — the standard
    /// poll fields plus a boot / sign-in-demand scan of the
    /// visible page text (keywords only are reported; the
    /// text itself is the public UI of the page).
    static let leanbackPoll = """
        (function(){
          var v = document.querySelector('video');
          var txt = ((document.body && document.body.innerText) || '').toLowerCase();
          var signin = txt.indexOf('sign in') >= 0 || txt.indexOf('đăng nhập') >= 0;
          var activate = txt.indexOf('youtube.com/activate') >= 0 || txt.indexOf('enter code') >= 0 || txt.indexOf('nhập mã') >= 0;
          var booted = !!document.querySelector('#movie_player') || txt.indexOf('youtube') >= 0;
          var err = '';
          var e = document.querySelector('.ytp-error');
          if (e) { err = (e.innerText || '').slice(0, 120); }
          return JSON.stringify({
            has: !!v,
            playing: !!(v && !v.paused && !v.ended && v.readyState > 2),
            paused: !!(v && v.paused),
            ended: !!(v && v.ended),
            t: v && isFinite(v.currentTime) ? v.currentTime : 0,
            d: v && isFinite(v.duration) ? v.duration : 0,
            booted: booted, signin: signin, activate: activate,
            err: err, url: location.href, title: document.title
          });
        })()
        """

    /// PROBE (Audit G-3): the page's OWN verdict —
    /// ytInitialPlayerResponse.playabilityStatus (status +
    /// reason), read at load and at failure. This is the
    /// discriminator between "YouTube's server refused this
    /// client" (LOGIN_REQUIRED / UNPLAYABLE / bot-check) and
    /// "the engine cannot render media" (status OK, media
    /// stack dead). Public page state only.
    static let playability = """
        (function(){
          var ps = null;
          try {
            var r = window.ytInitialPlayerResponse;
            if (r && r.playabilityStatus) { ps = r.playabilityStatus; }
          } catch (e) {}
          if (!ps) { return JSON.stringify({status: 'absent', reason: ''}); }
          var reason = ps.reason || '';
          if (!reason && ps.errorScreen && ps.errorScreen.playerErrorMessageRenderer) {
            var m = ps.errorScreen.playerErrorMessageRenderer;
            var t = (m.reason && m.reason.simpleText) || '';
            var sub = '';
            try {
              var runs = (m.subreason && m.subreason.runs) || [];
              for (var i = 0; i < runs.length; i++) { sub += runs[i].text || ''; }
            } catch (e) {}
            reason = t + (sub ? ' — ' + sub : '');
          }
          return JSON.stringify({
            status: ps.status || '', reason: String(reason).slice(0, 200)
          });
        })()
        """

    /// PROBE: the extended poll (experience-phase reads).
    /// Everything the base poll returns, plus the transport
    /// research fields: ad state, visibility, element
    /// readiness, the still-watching dialog scan (Team B-2),
    /// MediaSession handler counters (Team B-4), the
    /// oscilloscope's drained SPA-navigation events and
    /// playlist index (Team C-1), and the playback quality
    /// (Team E-P7).
    static let pollX = """
        (function(){
          var v = document.querySelector('video');
          var p = document.getElementById('movie_player');
          var err = '';
          var e = document.querySelector('.ytp-error');
          if (e) { err = (e.innerText || '').slice(0, 120); }
          var state = -99, vid = '', t = 0, d = 0, api = 0, pidx = -1, qual = '';
          try {
            if (p && p.getPlayerState) {
              api = 1;
              state = p.getPlayerState();
              if (p.getCurrentTime) { t = p.getCurrentTime() || 0; }
              if (p.getDuration) { d = p.getDuration() || 0; }
              if (p.getVideoData) {
                var vd = p.getVideoData();
                vid = (vd && (vd.video_id || vd.videoId)) || '';
              }
              if (p.getPlaylistIndex) { pidx = p.getPlaylistIndex(); }
              if (p.getPlaybackQuality) { qual = p.getPlaybackQuality() || ''; }
            }
          } catch (ex) { api = 0; state = -99; }
          if (v) {
            if (!(d > 0) && isFinite(v.duration)) { d = v.duration; }
            if (!t && isFinite(v.currentTime)) { t = v.currentTime; }
          }
          var playing, ended, paused;
          if (api) {
            playing = (state === 1); ended = (state === 0); paused = (state === 2);
          } else {
            playing = !!(v && !v.paused && !v.ended && v.readyState > 2);
            ended = !!(v && v.ended);
            paused = !!(v && v.paused);
          }
          var txt = ((document.body && document.body.innerText) || '').toLowerCase();
          var dialog = txt.indexOf('still watching') >= 0
            || txt.indexOf('vẫn đang xem') >= 0
            || txt.indexOf('are you still watching') >= 0 ? 1 : 0;
          var ad = 0;
          try {
            if (p && p.classList && p.classList.contains('ad-showing')) { ad = 1; }
          } catch (ex) {}
          var ms = window.__probeMS || {play: 0, pause: 0, next: 0, prev: 0};
          var osc = window.__probeOSC || [];
          window.__probeOSC = [];
          return JSON.stringify({
            has: !!v, api: api, state: state, vid: vid,
            playing: playing, paused: paused, ended: ended,
            muted: !!(v && v.muted), t: t, d: d,
            pin: 0, err: err, url: location.href,
            pidx: pidx, qual: qual, ad: ad, dialog: dialog,
            vis: document.visibilityState || '',
            rs: v ? v.readyState : -1,
            msPlay: ms.play, msPause: ms.pause, msNext: ms.next, msPrev: ms.prev,
            osc: osc
          });
        })()
        """

    /// PROBE (Team B-4, SPECULATION): install MediaSession
    /// action handlers that only COUNT invocations — the
    /// poll reads the counters. If tvOS WebKit ever routes a
    /// system media intent into the page, the counters move.
    static let mediaSessionInstall = """
        (function(){
          if (!('mediaSession' in navigator)) { return 'nomediasession'; }
          window.__probeMS = {play: 0, pause: 0, next: 0, prev: 0};
          try {
            navigator.mediaSession.setActionHandler('play', function(){ window.__probeMS.play++; });
            navigator.mediaSession.setActionHandler('pause', function(){ window.__probeMS.pause++; });
            navigator.mediaSession.setActionHandler('nexttrack', function(){ window.__probeMS.next++; });
            navigator.mediaSession.setActionHandler('previoustrack', function(){ window.__probeMS.prev++; });
            return 'installed';
          } catch (e) { return 'err'; }
        })()
        """

    /// PROBE (Team C-1): the advance oscilloscope's event
    /// tap — SPA navigation events land in window.__probeOSC
    /// with page-clock timestamps; the extended poll drains
    /// the array. Installed once per page load.
    static let oscilloscopeInstall = """
        (function(){
          if (window.__probeOSCInstalled) { return 'already'; }
          window.__probeOSCInstalled = true;
          window.__probeOSC = window.__probeOSC || [];
          function push(kind) {
            try {
              window.__probeOSC.push(kind + '@' + Math.round(performance.now()));
            } catch (e) {}
          }
          document.addEventListener('yt-navigate-finish', function(){ push('yt-navigate-finish'); });
          document.addEventListener('yt-page-data-updated', function(){ push('yt-page-data-updated'); });
          return 'installed';
        })()
        """

    /// PROBE (Team B-2): dismiss a still-watching dialog if
    /// one is up — clicks the confirm control from the
    /// selector family the dismissal extensions use. Returns
    /// 'clicked' / 'notfound'. Log-only consequence.
    static let dismissDialog = """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var wanted = ['yes', 'vẫn xem', 'continue watching', 'tiếp tục xem', 'ok'];
          var cands = document.querySelectorAll('button, a, [role="button"]');
          for (var i = 0; i < cands.length; i++) {
            var t = (cands[i].innerText || cands[i].textContent || '').trim().toLowerCase();
            if (wanted.indexOf(t) >= 0 && vis(cands[i])) {
              cands[i].click();
              return 'clicked';
            }
          }
          return 'notfound';
        })()
        """

    /// PROBE (Team E-P7): set a non-default quality through
    /// the player API; the extended poll reads it back, now
    /// and after an advance.
    static let setQuality1080 = """
        (function(){
          var p = document.getElementById('movie_player');
          try {
            if (p && p.setPlaybackQualityRange) {
              p.setPlaybackQualityRange('hd1080');
              return 'set';
            }
          } catch (e) {}
          return 'noapi';
        })()
        """

    // MARK: Door payloads (JoeTV verbatim + PROBE additions)

    /// Which step the door page is on: 'email' | 'password'
    /// | 'challenge' | 'none'. PROBE: the 'challenge' step
    /// (JoeTV fix item D-2) — a visible "Try another way"
    /// control with no credential field up IS the passkey /
    /// verification challenge shape.
    static let doorProbe = """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var pw = document.querySelector('input[name="Passwd"], input[type="password"]');
          if (vis(pw)) { return 'password'; }
          var idn = document.querySelector('input[name="identifier"], input[type="email"]');
          if (vis(idn)) { return 'email'; }
          var cands = document.querySelectorAll('a, button, [role="button"], div[role="link"]');
          for (var i = 0; i < cands.length; i++) {
            var t = (cands[i].innerText || cands[i].textContent || '').trim().toLowerCase();
            if ((t === 'try another way' || t === 'thử cách khác') && vis(cands[i])) {
              return 'challenge';
            }
          }
          return 'none';
        })()
        """

    /// PROBE: capability masking (door-scoped experiment) —
    /// installed at document start in the DOOR's web view
    /// only, so Google feature-detects NO WebAuthn support
    /// and stays on the password path. Removes the WebAuthn
    /// globals; everything else on the page is untouched.
    static let masking = """
        (function(){
          try { delete window.PublicKeyCredential; } catch (e) {}
          try {
            Object.defineProperty(window, 'PublicKeyCredential',
              { value: undefined, configurable: true });
          } catch (e) {}
          if (navigator.credentials) {
            try {
              var reject = function() {
                return Promise.reject(new DOMException('masked', 'NotAllowedError'));
              };
              Object.defineProperty(navigator, 'credentials', {
                value: { get: reject, create: reject },
                configurable: true
              });
            } catch (e) {}
          }
          window.__ytProbeMasked = true;
        })()
        """

    /// PROBE: JS-click the page's "Try another way" control
    /// (JoeTV fix item D-3; the door research's option A —
    /// the same evaluate+click mechanism that advanced the
    /// email step on the owner's TV). Returns 'clicked' or
    /// 'notfound'; fail-soft by construction.
    static let clickTryAnotherWay = """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var cands = document.querySelectorAll('a, button, [role="button"], div[role="link"]');
          for (var i = 0; i < cands.length; i++) {
            var t = (cands[i].innerText || cands[i].textContent || '').trim().toLowerCase();
            if ((t === 'try another way' || t === 'thử cách khác') && vis(cands[i])) {
              cands[i].click();
              return 'clicked';
            }
          }
          return 'notfound';
        })()
        """

    /// PROBE: after "Try another way", Google lists sign-in
    /// methods; click the password one so the door lands
    /// back on the password step. Text-matched, fail-soft.
    static let clickPasswordMethod = """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var wanted = ['use your password', 'enter your password',
                        'dùng mật khẩu', 'sử dụng mật khẩu', 'nhập mật khẩu'];
          var cands = document.querySelectorAll('a, button, [role="button"], div[role="link"], li, div');
          for (var i = 0; i < cands.length; i++) {
            var t = (cands[i].innerText || cands[i].textContent || '').trim().toLowerCase();
            if (t.length > 60) { continue; }
            for (var j = 0; j < wanted.length; j++) {
              if (t === wanted[j] && vis(cands[i])) {
                cands[i].click();
                return 'clicked';
              }
            }
          }
          return 'notfound';
        })()
        """

    /// PROBE (Audit 2 §3.2 / Team 2 §5 item 3): the
    /// challenge page's candidate-control inventory —
    /// VALUES-FREE by construction: tag, role and visible
    /// label text of clickable controls, and input TYPES
    /// only (never an input's value). This capture is what
    /// the production click payload gets built from.
    static let domInventory = """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var out = [];
          var inputs = document.querySelectorAll('input');
          for (var i = 0; i < inputs.length && out.length < 40; i++) {
            if (vis(inputs[i])) {
              out.push('input[type=' + (inputs[i].type || '?')
                + ',name=' + (inputs[i].name || '?') + ']');
            }
          }
          var cands = document.querySelectorAll('a, button, [role="button"], div[role="link"], li');
          for (var j = 0; j < cands.length && out.length < 40; j++) {
            var t = (cands[j].innerText || cands[j].textContent || '').trim().replace(/\s+/g, ' ').slice(0, 60);
            if (t && vis(cands[j])) {
              out.push(cands[j].tagName.toLowerCase() + ':' + t);
            }
          }
          return JSON.stringify(out);
        })()
        """

    private static func jsLiteral(_ value: String) -> String {
        var out = "'"
        for ch in value {
            switch ch {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out + "'"
    }

    private static func fillField(selector: String, value: String,
                                  nextSelector: String) -> String {
        """
        (function(){
          var el = document.querySelector(\(jsLiteral(selector)));
          if (!el) { return 'nofield'; }
          el.focus();
          var setter = Object.getOwnPropertyDescriptor(
            window.HTMLInputElement.prototype, 'value').set;
          setter.call(el, \(jsLiteral(value)));
          el.dispatchEvent(new Event('input', {bubbles: true}));
          el.dispatchEvent(new Event('change', {bubbles: true}));
          setTimeout(function(){
            var next = document.querySelector(\(jsLiteral(nextSelector)));
            if (next) { next.click(); }
          }, 350);
          return 'filled';
        })()
        """
    }

    static func fillIdentifier(_ email: String) -> String {
        fillField(selector: "input[name=\"identifier\"], input[type=\"email\"]",
                  value: email,
                  nextSelector: "#identifierNext button, #identifierNext")
    }

    static func fillPassword(_ password: String) -> String {
        fillField(selector: "input[name=\"Passwd\"], input[type=\"password\"]",
                  value: password,
                  nextSelector: "#passwordNext button, #passwordNext")
    }
}

// MARK: - Session (copied from JoeYtSession, probe log tag)

/// SAPISID-presence state + the cookie mirror, copied from
/// JoeTV so Probe 4's sign-in persists across probe launches
/// exactly the way production's does. Cookie values never
/// reach the log — presence and counts only.
@MainActor
final class ProbeSession: ObservableObject {
    static let shared = ProbeSession()

    @Published private(set) var signedIn = false
    let bridgeAvailable = JoeWebBridge.webKitAvailable()

    private init() {}

    private struct CookieRecord: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var secure: Bool
        var expires: Date?
    }

    private static var mirrorURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ytprobe-yt-mirror.json")
    }

    func refresh() async {
        signedIn = await Self.fetchPresence()
    }

    func ensureSession() async {
        await refresh()
        if !signedIn {
            await restoreFromMirror()
            await refresh()
        }
    }

    func mirrorNow() async {
        let cookies = await Self.fetchAllCookies()
        let records = cookies
            .map { Self.record(from: $0) }
            .filter {
                $0.domain.contains("youtube.com")
                    || $0.domain.contains("google.com")
            }
        guard records.contains(where: { $0.name == "SAPISID" }) else { return }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: Self.mirrorURL, options: .atomic)
            DiagLog.write("probe", "session mirror saved cookies=\(records.count)")
        }
    }

    private func restoreFromMirror() async {
        guard let data = try? Data(contentsOf: Self.mirrorURL),
              let records = try? JSONDecoder().decode([CookieRecord].self,
                                                      from: data),
              !records.isEmpty else { return }
        let dicts = records.map { Self.dictionary(from: $0) }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            JoeWebBridge.restoreCookies(dicts) { cont.resume() }
        }
        DiagLog.write("probe", "session mirror restored cookies=\(records.count)")
    }

    /// Sendable BY CONSTRUCTION (the JoeTV run #16/#17
    /// lesson): the bridge's [String: Any] dictionaries are
    /// mapped to this struct INSIDE the bridge completion;
    /// only snapshots cross the continuation.
    private struct CookieSnapshot: Sendable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var secure: Bool
        var expires: Date?
    }

    private static func fetchAllCookies() async -> [CookieSnapshot] {
        await withCheckedContinuation {
            (cont: CheckedContinuation<[CookieSnapshot], Never>) in
            JoeWebBridge.fetchAllCookies { entries in
                cont.resume(returning: entries.compactMap(Self.snapshot(from:)))
            }
        }
    }

    nonisolated private static func snapshot(from entry: [String: Any]) -> CookieSnapshot? {
        guard let name = entry["name"] as? String,
              let value = entry["value"] as? String,
              let domain = entry["domain"] as? String else { return nil }
        return CookieSnapshot(
            name: name,
            value: value,
            domain: domain,
            path: (entry["path"] as? String) ?? "/",
            secure: (entry["secure"] as? NSNumber)?.boolValue ?? false,
            expires: entry["expires"] as? Date)
    }

    /// The session's cookie header for the probe's own
    /// beacon/history experiments (Team D P-1/P-6): built
    /// from the live store, values in memory only — the
    /// caller logs the cookie COUNT, never the header.
    func cookieHeader() async -> (header: String, count: Int)? {
        let cookies = await Self.fetchAllCookies()
        let mine = cookies.filter {
            $0.domain.contains("youtube.com") || $0.domain.contains("google.com")
        }
        guard mine.contains(where: { $0.name == "SAPISID" }) else { return nil }
        return (mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
                mine.count)
    }

    /// E-P3's timed read: the raw presence answer, exposed
    /// for the door probe's +0/+700 ms/+2 s series.
    func fetchPresencePublic() async -> Bool {
        await Self.fetchPresence()
    }

    private static func fetchPresence() async -> Bool {
        let cookies = await fetchAllCookies()
        return cookies.contains {
            $0.name == "SAPISID" && $0.domain.contains("youtube.com")
        }
    }

    private static func record(from snapshot: CookieSnapshot) -> CookieRecord {
        CookieRecord(
            name: snapshot.name,
            value: snapshot.value,
            domain: snapshot.domain,
            path: snapshot.path,
            secure: snapshot.secure,
            expires: snapshot.expires)
    }

    private static func dictionary(from record: CookieRecord) -> [String: Any] {
        var entry: [String: Any] = [
            "name": record.name,
            "value": record.value,
            "domain": record.domain,
            "path": record.path,
            "secure": NSNumber(value: record.secure),
        ]
        if let expires = record.expires { entry["expires"] = expires }
        return entry
    }
}

// MARK: - Bridge controller (copied from JoeWebController)

/// The NSObject delegate between JoeWebHostView (ObjC) and
/// the Swift models — JoeTV's JoeWebController verbatim in
/// shape. Nonisolated class (the ObjC delegate requirements
/// must be); every host-touching wrapper is @MainActor.
final class ProbeWebController: NSObject, JoeWebHostDelegate {
    weak var host: JoeWebHostView?

    var onPoll: (@MainActor (String?) -> Void)?
    var onFinishLoad: (@MainActor () -> Void)?
    var onFailLoad: (@MainActor (String) -> Void)?
    var onTerminated: (@MainActor () -> Void)?
    var onExitURL: (@MainActor (String) -> Void)?

    @MainActor
    func load(url: String, userAgent: String?, lockedURL: String?) {
        host?.lockedURLString = lockedURL
        host?.loadURLString(url, userAgent: userAgent)
    }

    @MainActor
    func relock(url: String) {
        host?.lockedURLString = url
    }

    @MainActor
    func evaluate(_ js: String) {
        host?.evaluateJavaScript(js, completion: nil)
    }

    @MainActor
    func evaluateForResult(_ js: String,
                           completion: @escaping @MainActor (String?) -> Void) {
        host?.evaluateJavaScript(js) { result in
            Task { @MainActor in completion(result) }
        }
    }

    @MainActor
    func startPolling(js: String, interval: Double = 2.0) {
        host?.startPolling(withInterval: interval, javaScript: js)
    }

    @MainActor
    func stopPoll() {
        host?.stopPolling()
    }

    /// PROBE: install a document-start script on this host
    /// (door masking). Must be called before the first load.
    @MainActor
    func installDocumentStartScript(_ js: String) {
        host?.addDocumentStartScript(js)
    }

    /// PROBE: re-assert page focus (door focus handover).
    @MainActor
    func focusPage() {
        host?.focusContent()
    }

    // MARK: JoeWebHostDelegate

    func joeHost(_ host: JoeWebHostView, didPollResult result: String?) {
        let callback = onPoll
        Task { @MainActor in callback?(result) }
    }

    func joeHostDidFinishLoad(_ host: JoeWebHostView) {
        let callback = onFinishLoad
        Task { @MainActor in callback?() }
    }

    func joeHost(_ host: JoeWebHostView, didFailLoadWithMessage message: String) {
        let callback = onFailLoad
        Task { @MainActor in callback?(message) }
    }

    func joeHostDidTerminateWebContent(_ host: JoeWebHostView) {
        let callback = onTerminated
        Task { @MainActor in callback?() }
    }

    func joeHost(_ host: JoeWebHostView, didRequestExitForURL url: String) {
        let callback = onExitURL
        Task { @MainActor in callback?(url) }
    }
}

// MARK: - SwiftUI host (JoeTV's JoeWebView + probe flags)

struct ProbeWebView: UIViewRepresentable {
    let controller: ProbeWebController
    let navigationMode: JoeWebNavigationMode
    let playbackPresses: Bool
    /// PROBE deltas: the MSE switch attempt is a
    /// construction-time choice (factory), page focus is a
    /// plain property.
    var mediaSourceSwitch: Bool = false
    var contentModeDesktop: Bool = false
    var pageFocus: Bool = false

    func makeUIView(context: Context) -> JoeWebHostView {
        let host = (mediaSourceSwitch || contentModeDesktop)
            ? JoeWebHostView.hostView(withMediaSourceSwitch: mediaSourceSwitch,
                                      contentModeDesktop: contentModeDesktop)
            : JoeWebHostView(frame: .zero)
        host.navigationMode = navigationMode
        host.playbackPressesEnabled = playbackPresses
        host.pageFocusEnabled = pageFocus
        host.delegate = controller
        controller.host = host
        return host
    }

    func updateUIView(_ uiView: JoeWebHostView, context: Context) {}

    static func dismantleUIView(_ uiView: JoeWebHostView, coordinator: ()) {
        uiView.stopPolling()
        uiView.delegate = nil
    }
}

/// One poll read, decoded from ProbeJS.poll's JSON (JoeTV's
/// JoeYtPollState, shared by the page probes).
struct ProbePollState: Decodable {
    let has: Bool
    let api: Int
    let state: Int
    let vid: String
    let playing: Bool
    let paused: Bool
    let ended: Bool
    let muted: Bool
    let t: Double
    let d: Double
    let pin: Int
    let err: String
    let url: String
}

/// The extended poll read (ProbeJS.pollX).
struct ProbePollXState: Decodable {
    let has: Bool
    let api: Int
    let state: Int
    let vid: String
    let playing: Bool
    let paused: Bool
    let ended: Bool
    let muted: Bool
    let t: Double
    let d: Double
    let pin: Int
    let err: String
    let url: String
    let pidx: Int
    let qual: String
    let ad: Int
    let dialog: Int
    let vis: String
    let rs: Int
    let msPlay: Int
    let msPause: Int
    let msNext: Int
    let msPrev: Int
    let osc: [String]
}

/// The page's own playability verdict (ProbeJS.playability).
struct ProbePlayability: Decodable {
    let status: String
    let reason: String
}

/// Probe 5's leanback read.
struct ProbeLeanbackState: Decodable {
    let has: Bool
    let playing: Bool
    let paused: Bool
    let ended: Bool
    let t: Double
    let d: Double
    let booted: Bool
    let signin: Bool
    let activate: Bool
    let err: String
    let url: String
    let title: String
}

/// Probe 1's capability snapshot.
struct ProbeCapability: Decodable {
    let ua: String
    let ms: String
    let mms: String
    let avc: String
    let avcAac: String
    let aac: String
    let vp9: String
    let hevc: String

    /// One log line / screen line for the snapshot.
    var summary: String {
        "MediaSource=\(ms) ManagedMS=\(mms) avc1.640028=\(avc) "
            + "avc+aac=\(avcAac) aac=\(aac) vp9=\(vp9) hevc=\(hevc)"
    }
}

/// The fixed probe targets (from JoeTV's bundled
/// tvb-yt.json, read 2026-11-20): Bằng Chứng Thép II is the
/// FREE series whose ep 1 failed on the owner's TV tonight;
/// Bang Phái Phong Vân is the GOLD series for Probe 8.
enum ProbeTargets {
    static let freePlaylist = "PLirxsEkduv0OUx8lnnxuEINhMJQfhGffr"
    static let freeEp1 = "bms2MLaZrkY"
    static let freeEp2 = "1PC3-CC4ZVM"
    static let goldEp1 = "f-ZSFRsMW_4"
    static let goldPlaylist = "PLL5Bckb3vh10"
    /// All 30 episode ids of the free series, in playlist
    /// order (from the same bundled data) — the ground truth
    /// for the /next panel completeness check (Team C-6).
    static let freeEpisodes: [String] = [
        "bms2MLaZrkY", "1PC3-CC4ZVM", "s7jOhdFKLUs", "w8F5VEvN6FU",
        "r6DSWwx5W6U", "ay5qp4tywUo", "vRm6ekVRqE4", "8R8JR6FWTtE",
        "6vE_nR_Gv_I", "ctKILFpKjcI", "W_dxwmVlwdk", "GCBm37ltrzE",
        "D6YDgVH44CQ", "LMabyBi4m68", "jG05r04hXa0", "v0Fj-8_BNbQ",
        "frr40wc5DOA", "-lIsckJ0Rxo", "rP-V9JI00QA", "iJ-49Bm9Ccc",
        "d0GbGlP_cto", "bwG5S550FFM", "dwsgrRG3TQI", "W58UcndZrBk",
        "bxv5ptmFTiY", "OKLgms6Xbqs", "n4fS-DOlZX0", "0Pd5GMi4XoE",
        "PbmNmHO3O1I", "fK0H76fef8E",
    ]
    static func goldWatchURL(_ videoID: String) -> String {
        "https://www.youtube.com/watch?v=\(videoID)&list=\(goldPlaylist)"
    }

    static func watchURL(_ videoID: String) -> String {
        "https://www.youtube.com/watch?v=\(videoID)&list=\(freePlaylist)"
    }
    static func mobileWatchURL(_ videoID: String) -> String {
        "https://m.youtube.com/watch?v=\(videoID)&list=\(freePlaylist)"
    }
    static func embedURL(_ videoID: String) -> String {
        "https://www.youtube.com/embed/\(videoID)?autoplay=1&rel=0"
    }
}
