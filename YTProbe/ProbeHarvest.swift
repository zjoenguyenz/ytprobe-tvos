import SwiftUI
import JavaScriptCore

// MARK: - Probe 20 — HARVEST: read what the signed-in page
// was already given (FL-351, round 3)
//
// The research wave's final ranking (FL351-CREATIVE-
// PANEL-FINAL-20261121.md) after Probe 19 convicted the
// whole InnerTube ladder (TV family capped at itag 135,
// web_embedded + TV bearer = HTTP 400 on both targets,
// playbackContext variants = census 135 + byte-check
// 403) and the PC census (P20-0) killed the relay:
//
//   P20-1 · HARVEST ★ the lead cell (Approach H).
//           Sign in ONCE through the Probe 4 door; the
//           door's WebView session (default data store)
//           then loads the DESKTOP watch page per target
//           with the Mac Safari UA, and this probe reads
//           ytInitialPlayerResponse.streamingData — the
//           subtree Probes 2/2b/2c never read (they read
//           only playabilityStatus from the same object).
//           Up to 3 loads per video before declaring
//           anything absent (the manifest is documented
//           intermittent). If the census tops itag 135
//           or an HLS manifest exists: fetch the manifest
//           (variant ladder logged), byte-check the best
//           format (solver when ciphered) and/or the top
//           HLS variant's first segment.
//   P20-2 · A-RECONCILIATION (Approach A). Probe 19's
//           P19-2 cell — the full yt-dlp web_embedded
//           ritual — but authenticated with the DOOR
//           COOKIES (Cookie header + SAPISIDHASH, the
//           Probe 12 auth material) instead of the OAuth
//           bearer that drew HTTP 400. One cell: it
//           either proves the recipe or convicts the
//           cookie family for good.
//   P20-3 · O CONTINGENCY (Approach O). In the SAME
//           signed-in watch page P20-1 just harvested,
//           evaluate a fetch to /player from the page's
//           own context (the page's ytcfg INNERTUBE
//           context + key, credentials included) and
//           read back status + census. Runs per target
//           immediately after that target's P20-1 read,
//           while the page is still loaded.
//   P20-5 · R STAGE 1 (Approach R, presence ONLY).
//           The WebView BotGuard mint chain (the Probe
//           13 phase-1B machinery, copied verbatim):
//           /tv scrape → tv_config challenge → BotGuard
//           inside a WKWebView → GenerateIT →
//           obtainPoToken. This cell STOPS at the token:
//           presence YES/NO + length + elapsed. NO SABR
//           fetch, no playback attempt — it only decides
//           whether an R stage 2 is worth designing.
//   P20-4 does NOT exist (killed by the P20-0 census).
//
// Identity: ONE door sign-in feeds every cell. Cookies
// never leave the WebView store except as the P20-2
// Cookie/SAPISIDHASH headers (in memory only). Cookie /
// token / stream-URL VALUES are never logged — presence,
// counts and lengths only, like every probe before this.
//
// Per-probe copy precedent: the solver harness, cipher
// handling, player-JS acquisition and byte-check are
// copied from ClientRaceProbeModel (Probe 19); the mint
// chain from SabrProbeModel (Probe 13B); the session
// auth material is Probe 12's ProbeAuthSession, reused
// as-is. Earlier probes are untouched.

@MainActor
final class HarvestProbeModel: ObservableObject {
    @Published var lines: [String] = []
    @Published var verdict = ""
    @Published var running = false
    @Published var needsDoor = false

    /// The page surface P20-1/P20-3 run in — the view
    /// hosts it (a WKWebView only executes in the
    /// hierarchy). Default data store = the door's
    /// store, so the door sign-in IS this page's session.
    let pageController = ProbeWebController()

    /// The mint surface for P20-5 (Probe 13B pattern).
    let mintController = ProbeWebController()

    private var started = false
    private var cellPrefix = ""
    private var seenPlayerHash: String?

    // The two targets (unchanged since Probe 18).
    private static let cappedVid = "4rdOxL9mqVk"   // Nhân Chứng ep 1 — census capped at 135
    private static let controlVid = "f-ZSFRsMW_4"  // Probe 16's Gold ep — tv_samsung gave 137
    private static let safariUA = ProbeJS.safariUA

    // MARK: Entry points (view-driven)

    /// On appear: if the door session already exists,
    /// run at once; otherwise ask for the door first.
    func start() {
        guard !started else { return }
        started = true
        Task {
            if await sessionReady() {
                await run()
            } else {
                needsDoor = true
                log("=== PROBE 20 — chưa có phiên đăng nhập cửa (Probe 4) ===")
                log("Mở cửa đăng nhập bằng nút trên màn hình, đăng nhập xong probe tự chạy. Mọi ô sẽ KHÔNG KẾT ÁN ĐƯỢC nếu không có phiên.")
            }
        }
    }

    /// The door cover was dismissed: re-check and run.
    func doorDismissed() {
        Task {
            if await sessionReady() {
                needsDoor = false
                started = true
                await run()
            } else {
                log("door: vẫn chưa thấy phiên đăng nhập (SAPISID) — đăng nhập chưa xong hoặc bị huỷ. Bấm 'Mở cửa đăng nhập' để thử lại.")
            }
        }
    }

    func rerun() {
        guard !running else { return }
        Task { await run() }
    }

    /// The door session exists when the Probe 12 auth
    /// material can be built (SAPISID present in the
    /// default store). Logs presence + cookie count.
    private func sessionReady() async -> Bool {
        await ProbeSession.shared.ensureSession()
        guard let material = await ProbeAuthSession.authMaterial() else {
            log("session: KHÔNG có SAPISID trong store — chưa đăng nhập cửa")
            return false
        }
        log("session: phiên cửa CÓ — SAPISID present, \(material.count) cookie youtube/google trong store (chỉ ghi số lượng)")
        return true
    }

    private func log(_ message: String) {
        DiagLog.write("P20", cellPrefix + message)
        lines.append(cellPrefix + message)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }

    private func evaluatePage(_ js: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            pageController.evaluateForResult(js) { result in
                cont.resume(returning: result)
            }
        }
    }

    private func evaluateMint(_ js: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            mintController.evaluateForResult(js) { result in
                cont.resume(returning: result)
            }
        }
    }

    // MARK: The normalised offer (P20-1 / P20-2 / P20-3 feed it)

    private struct OfferFormat {
        var itag: Int
        var mimeType: String
        var bitrate: Int
        var width: Int
        var height: Int
        var url: String?
        var cipher: String?
        /// Presence flags for the census counts/notes.
        /// On the page path only the best AVC's real
        /// url/cipher cross the JS bridge, but every
        /// format's KIND does — counts must read these
        /// flags, never url/cipher (review finding 1).
        /// On the P20-2 JSON path they mirror url/cipher.
        var hasDirectURL = false
        var hasCipher = false

        var isVideo: Bool { mimeType.hasPrefix("video/") }
        var isAvc: Bool { mimeType.lowercased().contains("avc1") }
    }

    private struct OfferFacts {
        var token = "KHÔNG KẾT ÁN ĐƯỢC"
        var detail = ""
        var ok = false
        var hasHLS = false
        var hlsMaxHeight = 0
        var hlsByteOK = false
        var bestAvcItag = 0
        var bestAvcHeight = 0
        var byteOK = false

        /// Did this offer beat the capped title's
        /// itag-135 ceiling? (Only meaningful on the
        /// capped target.)
        var beatsCeiling: Bool {
            (ok && bestAvcHeight > 480 && byteOK)
                || (hasHLS && hlsMaxHeight > 480 && hlsByteOK)
        }
    }

    /// Everything after an offer lands, for all three
    /// extraction cells: the mandatory census outputs +
    /// the two proof legs (HLS ladder + segment
    /// byte-check; best-AVC byte-check through the
    /// solver when ciphered). `hlsURL` rides in memory
    /// only — the log sees its host, never the URL.
    private func processOffer(playability: String, reason: String,
                              formats: [OfferFormat], hlsURL: String?,
                              sabr: Bool, userAgent: String,
                              videoId: String) async -> OfferFacts {
        var facts = OfferFacts()
        let direct = formats.filter { $0.hasDirectURL }.count
        let ciphered = formats.filter { $0.hasCipher }.count
        log("player: playability=\(playability) reason=\(reason.isEmpty ? "-" : reason) "
            + "hlsManifest=\(hlsURL != nil ? "YES" : "no") formats=\(formats.count) "
            + "directURL=\(direct) ciphered=\(ciphered) serverAbr(SABR)=\(sabr ? "YES" : "no")")

        guard playability == "OK" else {
            facts.token = "UNPLAYABLE"
            facts.detail = "UNPLAYABLE — playability=\(playability)\(reason.isEmpty ? "" : " — \(reason)")"
            return facts
        }
        facts.ok = true

        // FULL census — every format line + the sorted
        // itag array on one line (Probe 18/19 discipline).
        let mapped: [SabrPlayerFormat] = formats.map { format in
            SabrPlayerFormat(itag: format.itag, mimeType: format.mimeType,
                             bitrate: format.bitrate, width: format.width,
                             height: format.height, lastModified: 0, xtags: "")
        }
        let census = mapped.map { $0.itag }.sorted()
        log("player: census đầy đủ (\(formats.count) format) = \(census)")
        for format in formats {
            let dims = format.isVideo ? " \(format.width)x\(format.height)" : ""
            let urlNote = format.hasDirectURL ? "url=CÓ" : "url=không"
            let cipherNote = format.hasCipher ? " ciphered=CÓ" : ""
            log("player: fmt itag \(format.itag) \"\(format.mimeType)\"\(dims) bitrate \(format.bitrate) \(urlNote)\(cipherNote)")
        }

        // Highest AVC = the byte-check target: height
        // first, bitrate breaks the tie. When any AVC
        // format actually carries a url/cipher (the
        // page path attaches them to exactly one), the
        // pool is restricted to the carriers so the
        // byte-check always runs on a format whose URL
        // we hold (review finding 1).
        let avcCarriers = formats.indices.filter {
            formats[$0].isVideo && formats[$0].isAvc
                && (formats[$0].url != nil || formats[$0].cipher != nil)
        }
        let avcPool = avcCarriers.isEmpty
            ? formats.indices.filter { formats[$0].isVideo && formats[$0].isAvc }
            : avcCarriers
        let avcIndex = avcPool
            .max { a, b in
                formats[a].height != formats[b].height
                    ? formats[a].height < formats[b].height
                    : formats[a].bitrate < formats[b].bitrate
            }
        if let avcIndex {
            facts.bestAvcItag = formats[avcIndex].itag
            facts.bestAvcHeight = formats[avcIndex].height
            log("player: AVC cao nhất — itag \(facts.bestAvcItag) (\(formats[avcIndex].width)x\(formats[avcIndex].height), bitrate \(formats[avcIndex].bitrate))")
        } else {
            log("player: census KHÔNG có format AVC nào")
        }

        // Proof leg 1 — HLS: rendition ladder + a Range
        // byte-check on the TOP variant's first segment.
        if let hlsURL, let manifestURL = URL(string: hlsURL) {
            facts.hasHLS = true
            log("hls: manifest có mặt (host \(manifestURL.host ?? "?")) — đọc thang rendition…")
            let ladder = await fetchLadder(url: manifestURL, userAgent: userAgent)
            if ladder.isEmpty {
                log("hls: manifest tải về nhưng KHÔNG parse được rendition nào (hoặc tải lỗi)")
            } else {
                let heights = ladder.map { $0.height }.sorted(by: >)
                facts.hlsMaxHeight = heights.first ?? 0
                log("hls: thang rendition — \(ladder.count) mức, heights (cao→thấp) = \(heights)")
                if let top = ladder.max(by: { $0.height < $1.height }) {
                    let check = await byteCheckHLSTopVariant(manifestURL: manifestURL,
                                                               variantPath: top.path,
                                                               userAgent: userAgent)
                    facts.hlsByteOK = check.ok
                    log("hls: byte-check variant cao nhất (\(top.height)p) — \(check.note)")
                }
            }
        }

        // Proof leg 2 — the highest AVC format must
        // deliver real bytes (solver first when the
        // format is ciphered or carries an n parameter).
        if let avcIndex {
            let best = formats[avcIndex]
            var raw: [String: Any] = [:]
            if let url = best.url { raw["url"] = url }
            if let cipher = best.cipher { raw["signatureCipher"] = cipher }
            let byteOutcome = await byteCheckTarget(itag: best.itag, raw: raw,
                                                    userAgent: userAgent, videoId: videoId)
            switch byteOutcome {
            case .ok(let status, let bytes):
                facts.byteOK = true
                log("byte-check: itag \(best.itag) — HTTP \(status), nhận \(bytes) bytes — \(status == 206 ? "đúng kỳ vọng 206" : "server trả \(status) thay vì 206 nhưng byte vẫn chảy đủ")")
            case .failed(let why):
                if facts.hasHLS, facts.hlsByteOK {
                    log("byte-check: itag \(best.itag) KHÔNG qua — \(why.detail) (ô vẫn có bằng chứng HLS byte-check ở trên)")
                } else {
                    facts.token = why.token
                    facts.detail = why.detail
                    return facts
                }
            }
        } else if !facts.hasHLS {
            facts.token = "KHÔNG KẾT ÁN ĐƯỢC"
            facts.detail = "KHÔNG KẾT ÁN ĐƯỢC — playability OK nhưng census không có AVC để byte-check và không có HLS"
            return facts
        }

        // No byte proof of any kind = NO playable
        // verdict (review finding 2: the HLS-only path
        // used to fall through to ĐẠT-480 with neither
        // leg proven). An offer only earns ĐẠT-* when
        // at least one leg delivered real bytes.
        if !facts.byteOK && !facts.hlsByteOK {
            facts.token = "KHÔNG KẾT ÁN ĐƯỢC"
            facts.detail = "KHÔNG KẾT ÁN ĐƯỢC — playability OK, census tới itag \(facts.bestAvcItag)/\(facts.bestAvcHeight)p\(facts.hasHLS ? ", HLS max \(facts.hlsMaxHeight)p" : ", không có HLS") — nhưng không đường nào chứng minh được byte (byte-check AVC lẫn segment HLS đều không qua)"
            return facts
        }

        // Cell verdict from the facts.
        let hdViaHLS = facts.hasHLS && facts.hlsMaxHeight > 480 && facts.hlsByteOK
        let hdViaAvc = facts.bestAvcHeight > 480 && facts.byteOK
        if hdViaHLS {
            facts.token = "ĐẠT-HD"
            facts.detail = "ĐẠT-HD — HLS có mức \(facts.hlsMaxHeight)p, byte-check segment đầu OK; AVC cao nhất itag \(facts.bestAvcItag) \(facts.bestAvcHeight)p, byte-check \(facts.byteOK ? "OK" : "không qua (xem log)")"
        } else if hdViaAvc {
            facts.token = "ĐẠT-HD"
            facts.detail = "ĐẠT-HD — AVC itag \(facts.bestAvcItag) \(facts.bestAvcHeight)p qua byte-check; HLS \(facts.hasHLS ? "max \(facts.hlsMaxHeight)p" : "không có")"
        } else if facts.ok {
            facts.token = "ĐẠT-480"
            facts.detail = "ĐẠT-480 — phát được nhưng không gì trên 480p: AVC cao nhất itag \(facts.bestAvcItag) \(facts.bestAvcHeight)p (byte-check \(facts.byteOK ? "OK" : "không qua")), HLS \(facts.hasHLS ? "max \(facts.hlsMaxHeight)p, segment byte-check \(facts.hlsByteOK ? "OK" : "không qua")" : "không có")"
        }
        return facts
    }

    // MARK: HLS ladder + top-variant segment byte-check

    private struct LadderVariant {
        var height: Int
        var bandwidth: Int
        var path: String
    }

    private func fetchLadder(url: URL, userAgent: String) async -> [LadderVariant] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        var ladder: [LadderVariant] = []
        var pending: (height: Int, bandwidth: Int)?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                var height = 0
                var bandwidth = 0
                if let range = line.range(of: "RESOLUTION=") {
                    let rest = line[range.upperBound...]
                    let firstField = rest.split(separator: ",").first.map(String.init) ?? ""
                    let dims = firstField.split(separator: "x")
                    if dims.count == 2 { height = Int(dims[1]) ?? 0 }
                }
                if let range = line.range(of: "BANDWIDTH=") {
                    let rest = line[range.upperBound...]
                    let firstField = rest.split(separator: ",").first.map(String.init) ?? ""
                    bandwidth = Int(firstField) ?? 0
                }
                pending = (height, bandwidth)
            } else if !line.isEmpty, !line.hasPrefix("#"), let info = pending {
                ladder.append(LadderVariant(height: info.height,
                                            bandwidth: info.bandwidth, path: line))
                pending = nil
            }
        }
        return ladder
    }

    /// Fetch the top variant's media playlist, take its
    /// first segment, and Range byte-check it (the task's
    /// "≥1080p variant" proof leg for the HLS branch).
    private func byteCheckHLSTopVariant(manifestURL: URL, variantPath: String,
                                        userAgent: String) async -> (ok: Bool, note: String) {
        guard let variantURL = URL(string: variantPath, relativeTo: manifestURL) else {
            return (false, "URL variant không hợp lệ")
        }
        var request = URLRequest(url: variantURL)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let text = String(data: data, encoding: .utf8) else {
            return (false, "tải playlist của variant lỗi")
        }
        let segmentLine = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let segmentLine, let segmentURL = URL(string: segmentLine, relativeTo: variantURL) else {
            return (false, "playlist của variant không có segment nào đọc được")
        }
        let check = await byteCheck(url: segmentURL, userAgent: userAgent)
        if check.status == 0 {
            return (false, "segment đầu lỗi mạng, không có HTTP response")
        }
        guard (check.status == 200 || check.status == 206), check.bytes == 1024 else {
            return (false, "segment đầu HTTP \(check.status), nhận \(check.bytes)/1024 bytes (kỳ vọng 206 + đủ 1024)")
        }
        return (true, "segment đầu HTTP \(check.status), nhận \(check.bytes) bytes — đúng kỳ vọng")
    }

    // MARK: The page summariser (shared by P20-1 and P20-3)
    //
    // One JS function, inlined into every page payload
    // that needs it (each evaluateJavaScript is its own
    // script — self-contained payloads only, the door's
    // rule). It reduces a player response to the compact
    // shape Swift consumes: playability + verbatim
    // reason, streamingData presence, the HLS manifest
    // URL (in memory only — Swift logs its host, never
    // the URL), the SABR marker, the full census (itag /
    // mime / dims / bitrate / url-kind per format) and
    // the best AVC format's url / signatureCipher for
    // the native byte-check. No other format's URL
    // crosses the bridge.

    private static let summariserJS = """
        function __p20Summarize(r) {
          var out = {status: '', reason: '', sd: false, hls: null, sabr: false,
                     formats: [], bestUrl: null, bestCipher: null};
          try {
            var ps = r.playabilityStatus || {};
            out.status = ps.status || '';
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
            out.reason = String(reason).slice(0, 200);
            var sd = r.streamingData;
            if (sd) {
              out.sd = true;
              if (sd.hlsManifestUrl) { out.hls = sd.hlsManifestUrl; }
              out.sabr = !!sd.serverAbrStreamingUrl;
              var all = (sd.formats || []).concat(sd.adaptiveFormats || []);
              var best = null;
              for (var j = 0; j < all.length; j++) {
                var f = all[j];
                var kind = f.url ? 'url' : (f.signatureCipher ? 'cipher' : 'none');
                out.formats.push({itag: f.itag || 0, mime: f.mimeType || '',
                  w: f.width || 0, h: f.height || 0, br: f.bitrate || 0, kind: kind});
                var mime = f.mimeType || '';
                if (mime.indexOf('video/') === 0 && mime.indexOf('avc1') >= 0) {
                  if (!best || (f.height || 0) > best.height
                      || ((f.height || 0) === best.height && (f.bitrate || 0) > best.bitrate)) {
                    best = {itag: f.itag || 0, height: f.height || 0, bitrate: f.bitrate || 0,
                            url: f.url || null, cipher: f.signatureCipher || null};
                  }
                }
              }
              if (best) { out.bestUrl = best.url; out.bestCipher = best.cipher; out.bestItag = best.itag; }
            }
          } catch (e) {
            out.error = String((e && e.message) || e).slice(0, 120);
          }
          return out;
        }
        """

    /// Decode one page summary (from P20-1's read or
    /// P20-3's fetch) into the normalised offer inputs.
    /// Returns nil when the summary itself is unreadable.
    private func decodePageSummary(_ summary: [String: Any])
        -> (playability: String, reason: String, formats: [OfferFormat],
            hlsURL: String?, sabr: Bool, sdPresent: Bool)? {
        guard let status = summary["status"] as? String else { return nil }
        let reason = summary["reason"] as? String ?? ""
        let sdPresent = (summary["sd"] as? Bool) ?? false
        let sabr = (summary["sabr"] as? Bool) ?? false
        let hlsURL = summary["hls"] as? String
        let rawFormats = summary["formats"] as? [[String: Any]] ?? []
        var formats: [OfferFormat] = rawFormats.map { raw in
            let kind = raw["kind"] as? String ?? "none"
            return OfferFormat(itag: (raw["itag"] as? NSNumber)?.intValue ?? 0,
                               mimeType: raw["mime"] as? String ?? "",
                               bitrate: (raw["br"] as? NSNumber)?.intValue ?? 0,
                               width: (raw["w"] as? NSNumber)?.intValue ?? 0,
                               height: (raw["h"] as? NSNumber)?.intValue ?? 0,
                               url: nil, cipher: nil,
                               hasDirectURL: kind == "url",
                               hasCipher: kind == "cipher")
        }
        // Only the best AVC format's url/cipher crossed
        // the bridge; reattach them to THAT format —
        // identified by the itag the JS itself picked
        // (bestItag), so a height+bitrate tie can never
        // attach one format's URL to another's itag
        // (review finding 1). Fallback: recompute.
        let bestUrl = summary["bestUrl"] as? String
        let bestCipher = summary["bestCipher"] as? String
        if bestUrl != nil || bestCipher != nil {
            let bestItag = (summary["bestItag"] as? NSNumber)?.intValue ?? 0
            var avcIndex = formats.firstIndex { $0.isVideo && $0.isAvc && $0.itag == bestItag }
            if avcIndex == nil {
                avcIndex = formats.indices.filter { formats[$0].isVideo && formats[$0].isAvc }
                    .max { a, b in
                        formats[a].height != formats[b].height
                            ? formats[a].height < formats[b].height
                            : formats[a].bitrate < formats[b].bitrate
                    }
            }
            if let avcIndex {
                formats[avcIndex].url = bestUrl
                formats[avcIndex].cipher = bestCipher
                formats[avcIndex].hasDirectURL = bestUrl != nil
                formats[avcIndex].hasCipher = bestCipher != nil
            }
        }
        return (status, reason, formats, hlsURL, sabr, sdPresent)
    }

    // MARK: P20-1 — HARVEST

    /// Load the desktop watch page for one target in the
    /// door-session WebView (Mac Safari UA) and read
    /// ytInitialPlayerResponse.streamingData at load.
    /// Up to 3 loads: a later load is only spent when
    /// streamingData is absent or the HLS manifest has
    /// not appeared yet (documented intermittency).
    private func harvestTarget(videoId: String, targetName: String) async -> OfferFacts {
        var facts = OfferFacts()
        var lastSummary: [String: Any]?
        var loadsUsed = 0
        for attempt in 1...3 {
            loadsUsed = attempt
            log("harvest: load #\(attempt) — trang watch desktop (Mac Safari UA), vid \(videoId)")
            pageController.load(url: "https://www.youtube.com/watch?v=\(videoId)",
                                userAgent: Self.safariUA, lockedURL: nil)
            let ready = await waitForPageReady(timeoutSeconds: 40)
            if !ready {
                log("harvest: load #\(attempt) — trang không tới readyState complete trong ~40s (vẫn thử đọc)")
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            let readJS = Self.summariserJS + """
                (function(){
                  var r = null;
                  try { r = window.ytInitialPlayerResponse; } catch (e) {}
                  if (!r) { return JSON.stringify({step: 'no-response'}); }
                  return JSON.stringify({step: 'ok', summary: __p20Summarize(r)});
                })()
                """
            guard let raw = await evaluatePage(readJS),
                  let data = raw.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let step = object["step"] as? String else {
                log("harvest: load #\(attempt) — KHÔNG đọc được ytInitialPlayerResponse (evaluate không đáp hoặc đáp không phải JSON)")
                continue
            }
            if step == "no-response" {
                log("harvest: load #\(attempt) — trang KHÔNG có ytInitialPlayerResponse")
                continue
            }
            guard let summary = object["summary"] as? [String: Any] else {
                log("harvest: load #\(attempt) — summary không đọc được")
                continue
            }
            // Keep the BEST summary across loads, not
            // the last (review finding 3): a retry load
            // that comes back without streamingData
            // must not erase a good earlier harvest.
            if summaryRank(summary) >= (lastSummary.map { summaryRank($0) } ?? -1) {
                lastSummary = summary
            }
            let sdPresent = (summary["sd"] as? Bool) ?? false
            let hlsPresent = (summary["hls"] as? String) != nil
            log("harvest: load #\(attempt) — playability=\((summary["status"] as? String) ?? "?") streamingData=\(sdPresent ? "CÓ" : "KHÔNG") hlsManifestUrl=\(hlsPresent ? "CÓ" : "không")")
            if sdPresent && hlsPresent { break }
            if sdPresent && attempt == 3 { break }
            if sdPresent {
                log("harvest: streamingData CÓ nhưng manifest chưa thấy — load lại (tính chập chờn đã ghi trong nghiên cứu)")
            }
        }
        guard let summary = lastSummary,
              let decoded = decodePageSummary(summary) else {
            facts.token = "KHÔNG CÓ STREAMINGDATA"
            facts.detail = "KHÔNG CÓ STREAMINGDATA — sau \(loadsUsed) load, trang không cho đọc được ytInitialPlayerResponse/streamingData nào"
            log("KẾT QUẢ P20-1 [\(targetName)]: \(facts.detail)")
            return facts
        }
        if !decoded.sdPresent {
            facts.token = "KHÔNG CÓ STREAMINGDATA"
            facts.detail = "KHÔNG CÓ STREAMINGDATA — playability=\(decoded.playability)\(decoded.reason.isEmpty ? "" : " — \(decoded.reason)"); streamingData vắng mặt sau \(loadsUsed) load"
            log("KẾT QUẢ P20-1 [\(targetName)]: \(facts.detail)")
            return facts
        }
        facts = await processOffer(playability: decoded.playability, reason: decoded.reason,
                                   formats: decoded.formats, hlsURL: decoded.hlsURL,
                                   sabr: decoded.sabr, userAgent: Self.safariUA,
                                   videoId: videoId)
        log("KẾT QUẢ P20-1 [\(targetName)]: \(facts.detail)")
        return facts
    }

    /// Rank a page summary for best-of-loads retention
    /// (review finding 3): streamingData present beats
    /// absent; HLS present breaks the tie upward.
    private func summaryRank(_ summary: [String: Any]) -> Int {
        let sd = (summary["sd"] as? Bool) ?? false
        let hls = (summary["hls"] as? String) != nil
        return (sd ? 2 : 0) + (hls ? 1 : 0)
    }

    /// Poll document.readyState until 'complete'
    /// (the Probe 13B mint's page-ready pattern).
    private func waitForPageReady(timeoutSeconds: Int) async -> Bool {
        let polls = max(1, timeoutSeconds * 2 / 3)
        for _ in 0..<polls {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if await evaluatePage("document.readyState") == "complete" {
                return true
            }
        }
        return false
    }

    // MARK: P20-3 — in-page fetch (contingency)

    /// From within the signed-in watch page P20-1 just
    /// harvested, fetch /player with the page's own
    /// ytcfg INNERTUBE context + key (credentials
    /// included) and read back status + census. The
    /// fetch is asynchronous in the page: the kickoff
    /// payload stashes its outcome in
    /// window.__probe20Fetch and Swift polls it.
    private func inPageFetchTarget(videoId: String, targetName: String) async -> OfferFacts {
        var facts = OfferFacts()
        guard let videoLiteral = jsonEncodedString(videoId) else {
            facts.detail = "KHÔNG KẾT ÁN ĐƯỢC — không encode được videoId cho payload trang"
            log("KẾT QUẢ P20-3 [\(targetName)]: \(facts.detail)")
            return facts
        }
        let kickoffJS = Self.summariserJS + """
            (function(){
              window.__probe20Fetch = {step: 'starting'};
              window.__probe20FetchCtx = '';
              try {
                var key = '';
                var ctx = null;
                try { key = ytcfg.get('INNERTUBE_API_KEY') || ''; } catch (e) {}
                try { ctx = ytcfg.get('INNERTUBE_CONTEXT') || null; } catch (e) {}
                if (ctx && ctx.client) {
                  window.__probe20FetchCtx = (ctx.client.clientName || '?')
                    + ' ' + (ctx.client.clientVersion || '?');
                }
                if (!key || !ctx) {
                  window.__probe20Fetch = {step: 'no-ytcfg', hasKey: !!key, hasCtx: !!ctx};
                  return 'no-ytcfg';
                }
                var body = {videoId: \(videoLiteral), context: ctx,
                  racyCheckOk: true, contentCheckOk: true,
                  playbackContext: {contentPlaybackContext:
                    {vis: 0, splay: false, lactMilliseconds: '-1'}}};
                fetch('/youtubei/v1/player?key=' + encodeURIComponent(key) + '&prettyPrint=false',
                  {method: 'POST', credentials: 'include',
                   headers: {'Content-Type': 'application/json'},
                   body: JSON.stringify(body)})
                .then(function(r) {
                  return r.text().then(function(t) { return {http: r.status, text: t}; });
                })
                .then(function(res) {
                  var out = {step: 'done', http: res.http, bytes: res.text.length};
                  try { out.summary = __p20Summarize(JSON.parse(res.text)); }
                  catch (e) { out.step = 'badjson'; }
                  window.__probe20Fetch = out;
                })
                .catch(function(e) {
                  window.__probe20Fetch = {step: 'fetch-error',
                    error: String((e && e.message) || e).slice(0, 120)};
                });
                return 'kicked';
              } catch (e) {
                window.__probe20Fetch = {step: 'throw',
                  error: String((e && e.message) || e).slice(0, 120)};
                return 'throw';
              }
            })()
            """
        let kicked = await evaluatePage(kickoffJS)
        log("in-page fetch: kickoff → \(kicked ?? "không đáp")")
        guard kicked == "kicked" || kicked == "no-ytcfg" else {
            facts.detail = "KHÔNG KẾT ÁN ĐƯỢC — payload fetch trong trang không khởi động được (kickoff=\(kicked ?? "nil"))"
            log("KẾT QUẢ P20-3 [\(targetName)]: \(facts.detail)")
            return facts
        }
        var outcome: [String: Any]?
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let raw = await evaluatePage("JSON.stringify(window.__probe20Fetch || {step: 'none'})"),
                  let data = raw.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let step = object["step"] as? String else { continue }
            if step != "starting" && step != "none" {
                outcome = object
                break
            }
        }
        guard let outcome, let step = outcome["step"] as? String else {
            facts.detail = "KHÔNG KẾT ÁN ĐƯỢC — fetch trong trang không báo kết quả sau 30s"
            log("KẾT QUẢ P20-3 [\(targetName)]: \(facts.detail)")
            return facts
        }
        let ctxLabel = await evaluatePage("window.__probe20FetchCtx || ''") ?? ""
        if !ctxLabel.isEmpty {
            log("in-page fetch: context của trang = \(ctxLabel) (đọc từ ytcfg của chính trang)")
        }
        switch step {
        case "no-ytcfg":
            let hasKey = (outcome["hasKey"] as? Bool) ?? false
            let hasCtx = (outcome["hasCtx"] as? Bool) ?? false
            facts.detail = "KHÔNG KẾT ÁN ĐƯỢC — trang không có ytcfg dùng được (INNERTUBE_API_KEY \(hasKey ? "có" : "thiếu"), INNERTUBE_CONTEXT \(hasCtx ? "có" : "thiếu"))"
            log("KẾT QUẢ P20-3 [\(targetName)]: \(facts.detail)")
            return facts
        case "done":
            break
        default:
            let error = outcome["error"] as? String ?? ""
            facts.detail = "KHÔNG KẾT ÁN ĐƯỢC — fetch trong trang dừng ở bước '\(step)'\(error.isEmpty ? "" : " — \(error)")"
            log("KẾT QUẢ P20-3 [\(targetName)]: \(facts.detail)")
            return facts
        }
        let http = (outcome["http"] as? NSNumber)?.intValue ?? -1
        log("in-page fetch: HTTP \(http) · body \((outcome["bytes"] as? NSNumber)?.intValue ?? 0) bytes")
        guard http == 200, let summary = outcome["summary"] as? [String: Any],
              let decoded = decodePageSummary(summary) else {
            facts.detail = "KHÔNG KẾT ÁN ĐƯỢC — fetch trong trang HTTP \(http)\(http == 200 ? " nhưng summary không đọc được" : "")"
            log("KẾT QUẢ P20-3 [\(targetName)]: \(facts.detail)")
            return facts
        }
        if !decoded.sdPresent {
            facts.token = "KHÔNG CÓ STREAMINGDATA"
            facts.detail = "KHÔNG CÓ STREAMINGDATA — fetch trong trang HTTP \(http), playability=\(decoded.playability)\(decoded.reason.isEmpty ? "" : " — \(decoded.reason)"), streamingData vắng mặt"
            log("KẾT QUẢ P20-3 [\(targetName)]: \(facts.detail)")
            return facts
        }
        facts = await processOffer(playability: decoded.playability, reason: decoded.reason,
                                   formats: decoded.formats, hlsURL: decoded.hlsURL,
                                   sabr: decoded.sabr, userAgent: Self.safariUA,
                                   videoId: videoId)
        log("KẾT QUẢ P20-3 [\(targetName)]: \(facts.detail)")
        return facts
    }

    // MARK: Shared text helpers (Probe 19 copies)

    private func fetchText(_ urlString: String, userAgent: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private func fetchTextWithCookie(_ urlString: String, userAgent: String,
                                     cookieHeader: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private func firstRegexCapture(in text: String, pattern: String) -> String? {
        regexCapture(in: text, pattern: pattern, group: 1)
    }

    private func regexCapture(in text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > group,
              let capture = Range(match.range(at: group), in: text) else { return nil }
        return String(text[capture])
    }

    /// JSON-encode one string as a JS-safe literal
    /// (serialise a one-element array, strip the brackets)
    /// — Probe 13B's helper, copied.
    private func jsonEncodedString(_ string: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let text = String(data: data, encoding: .utf8), text.count >= 2 else {
            return nil
        }
        return String(text.dropFirst().dropLast())
    }

    private func jsonEncodedObject(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func decodeBase64Loose(_ string: String) -> Data? {
        var normalised = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while normalised.count % 4 != 0 { normalised += "=" }
        return Data(base64Encoded: normalised)
    }

    // MARK: P20-2 — web_embedded ritual on DOOR COOKIES
    //
    // Probe 19's P19-2 recipe verbatim (per-video embed
    // harvest → thirdParty.embedUrl + visitorData +
    // encryptedHostFlags in contentPlaybackContext),
    // with exactly ONE variable changed: the identity.
    // The OAuth bearer (HTTP 400 on both targets in
    // Probe 19) is replaced by the door session's
    // cookies — Cookie header + SAPISIDHASH Authorization
    // (Probe 12's ProbeAuthSession material). The embed
    // page itself is also fetched WITH the session
    // cookies, as yt-dlp does when it holds a session.

    private func ladderClients() -> [ProbeClientSpec] {
        (try? JSONDecoder().decode(
            [ProbeClientSpec].self,
            from: Data(ProbeClientLadder.bundledJSON.utf8))) ?? []
    }

    private func standardKey() -> String? {
        ladderClients().first(where: { $0.name == "TVHTML5" })?.apiKey
    }

    /// WEB_EMBEDDED_PLAYER per yt-dlp master (Probe 19's
    /// spec, identical).
    private static func webEmbeddedSpec(apiKey: String?) -> ProbeClientSpec {
        ProbeClientSpec(
            name: "WEB_EMBEDDED",
            clientName: "WEB_EMBEDDED_PLAYER",
            clientVersion: "2.20260708.00.00",
            clientNumber: "56",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",
            apiKey: apiKey,
            deviceMake: nil,
            deviceModel: nil,
            osName: nil,
            osVersion: nil,
            androidSdkVersion: nil)
    }

    private func harvestEmbedFactsWithCookies(videoId: String, userAgent: String,
                                              cookieHeader: String)
        async -> (visitorData: String?, encryptedHostFlags: String?) {
        guard let html = await fetchTextWithCookie("https://www.youtube.com/embed/\(videoId)",
                                                   userAgent: userAgent,
                                                   cookieHeader: cookieHeader) else {
            log("embed: tải trang /embed/\(videoId) (có cookie cửa) THẤT BẠI — ô chạy thiếu visitor/flags")
            return (nil, nil)
        }
        let visitor = firstRegexCapture(in: html, pattern: "\"visitorData\"\\s*:\\s*\"([^\"]+)\"")
        let flags = firstRegexCapture(in: html, pattern: "\"encryptedHostFlags\"\\s*:\\s*\"([^\"]+)\"")
        log("embed: trang embed \(html.utf8.count) bytes (có cookie cửa) — visitorData \(visitor.map { "CÓ (len \($0.count))" } ?? "KHÔNG THẤY"), encryptedHostFlags \(flags.map { "CÓ (len \($0.count))" } ?? "KHÔNG THẤY") (không ghi giá trị)")
        return (visitor, flags)
    }

    /// The /player call for P20-2: Probe 19's callPlayer
    /// shape with the bearer replaced by the door
    /// session's Cookie + SAPISIDHASH headers.
    private func callPlayerCookies(spec: ProbeClientSpec, videoId: String,
                                   cookieHeader: String, sapisidHash: String,
                                   visitorData: String?, encryptedHostFlags: String?)
        async -> (http: Int, json: [String: Any]?, ms: Int) {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false&key=\(spec.apiKey ?? "")") else {
            return (0, nil, 0)
        }
        var clientContext: [String: Any] = [
            "clientName": spec.clientName,
            "clientVersion": spec.clientVersion,
            "hl": "en",
            "gl": "US",
            "userAgent": spec.userAgent,
        ]
        if let visitorData { clientContext["visitorData"] = visitorData }
        let context: [String: Any] = [
            "client": clientContext,
            "thirdParty": ["embedUrl": "https://www.reddit.com/"],
        ]
        var contentPlayback: [String: Any] = ["html5Preference": "HTML5_PREF_WANTS"]
        if let encryptedHostFlags { contentPlayback["encryptedHostFlags"] = encryptedHostFlags }
        let body: [String: Any] = [
            "videoId": videoId,
            "context": context,
            "playbackContext": ["contentPlaybackContext": contentPlayback],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(spec.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(sapisidHash, forHTTPHeaderField: "Authorization")
        request.setValue(spec.clientNumber, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(spec.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        if let visitorData {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let t0 = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (http, json, ms)
        } catch {
            log("player: lỗi mạng — \(error.localizedDescription)")
            return (0, nil, Int(Date().timeIntervalSince(t0) * 1000))
        }
    }

    private func runReconciliationCell(videoId: String, targetName: String) async -> OfferFacts {
        var facts = OfferFacts()
        let spec = Self.webEmbeddedSpec(apiKey: standardKey())
        log("spec P20-2: clientName=\(spec.clientName) clientVersion=\(spec.clientVersion) clientNumber=\(spec.clientNumber) apiKey=\(spec.apiKey == nil ? "không có" : "có (khoá web chuẩn)")")
        log("danh tính của ô: cookie của phiên cửa (Probe 4) + SAPISIDHASH — KHÔNG dùng OAuth bearer")
        guard let material = await ProbeAuthSession.authMaterial() else {
            facts.detail = "KHÔNG KẾT ÁN ĐƯỢC — phiên cửa biến mất trước ô này (không còn SAPISID)"
            log("KẾT QUẢ P20-2 [\(targetName)]: \(facts.detail)")
            return facts
        }
        log("session: auth material sẵn sàng — \(material.count) cookie (chỉ ghi số lượng), SAPISIDHASH đã gắn (không ghi giá trị)")
        let harvested = await harvestEmbedFactsWithCookies(videoId: videoId,
                                                           userAgent: spec.userAgent,
                                                           cookieHeader: material.cookieHeader)
        log("recipe: context.thirdParty.embedUrl=https://www.reddit.com/ + visitorData \(harvested.visitorData == nil ? "thiếu" : "có") + encryptedHostFlags \(harvested.encryptedHostFlags == nil ? "thiếu" : "có") trong contentPlaybackContext (công thức yt-dlp web_embedded, bản có cookie cửa)")
        let hash = ProbeAuthSession.sapisidHash(sapisid: material.sapisid)
        let r = await callPlayerCookies(spec: spec, videoId: videoId,
                                        cookieHeader: material.cookieHeader,
                                        sapisidHash: hash,
                                        visitorData: harvested.visitorData,
                                        encryptedHostFlags: harvested.encryptedHostFlags)
        guard r.http == 200, let json = r.json else {
            if r.http == 200 {
                log("player: HTTP 200 nhưng body KHÔNG parse được JSON")
                facts.detail = "KHÔNG KẾT ÁN ĐƯỢC — /player HTTP 200 nhưng body không parse được JSON"
            } else {
                log("player: HTTP \(r.http) — không có player response để đọc")
                facts.detail = "KHÔNG KẾT ÁN ĐƯỢC — /player HTTP \(r.http) với cookie cửa"
            }
            log("KẾT QUẢ P20-2 [\(targetName)]: \(facts.detail)")
            return facts
        }
        log("player: HTTP \(r.http) \(r.ms)ms — có player response")
        let playability = (json["playabilityStatus"] as? [String: Any])?["status"] as? String ?? "?"
        let reason = (json["playabilityStatus"] as? [String: Any])?["reason"] as? String ?? ""
        let streaming = json["streamingData"] as? [String: Any]
        let muxed = streaming?["formats"] as? [[String: Any]] ?? []
        let adaptive = streaming?["adaptiveFormats"] as? [[String: Any]] ?? []
        let formats: [OfferFormat] = (muxed + adaptive).map { raw in
            let url = raw["url"] as? String
            let cipher = raw["signatureCipher"] as? String
            return OfferFormat(itag: (raw["itag"] as? NSNumber)?.intValue ?? 0,
                               mimeType: raw["mimeType"] as? String ?? "",
                               bitrate: (raw["bitrate"] as? NSNumber)?.intValue ?? 0,
                               width: (raw["width"] as? NSNumber)?.intValue ?? 0,
                               height: (raw["height"] as? NSNumber)?.intValue ?? 0,
                               url: url,
                               cipher: cipher,
                               hasDirectURL: url != nil,
                               hasCipher: cipher != nil)
        }
        facts = await processOffer(playability: playability, reason: reason,
                                   formats: formats,
                                   hlsURL: streaming?["hlsManifestUrl"] as? String,
                                   sabr: streaming?["serverAbrStreamingUrl"] != nil,
                                   userAgent: spec.userAgent, videoId: videoId)
        log("KẾT QUẢ P20-2 [\(targetName)]: \(facts.detail)")
        return facts
    }

    // MARK: Byte-check target (solver when needed) —
    // Probe 19's machinery, copied without behavioural
    // changes (only names carry the Harvest prefix).

    private enum ByteOutcome {
        case ok(status: Int, bytes: Int)
        case failed(HarvestFailure)
    }

    private struct HarvestFailure {
        var token: String
        var detail: String
    }

    /// Resolve ONE format (the highest AVC) to a real
    /// URL — deciphering through the EJS solver when the
    /// format is ciphered or its URL carries an n
    /// parameter — then run the Range byte-check on it.
    private func byteCheckTarget(itag: Int, raw: [String: Any],
                                 userAgent: String, videoId: String) async -> ByteOutcome {
        var needsSig = false
        var needsN = false
        if let plain = raw["url"] as? String {
            if nParameter(in: plain) != nil { needsN = true }
        } else if let cipher = raw["signatureCipher"] as? String {
            needsSig = true
            if let parts = parseCipher(cipher), nParameter(in: parts.url) != nil { needsN = true }
        }
        log("sign: itag \(itag) — nhu cầu: decipher sig \(needsSig ? "CÓ" : "không") · transform n \(needsN ? "CÓ" : "không")")

        var sigResults: [String: String]?
        var nResults: [String: String]?
        if needsSig || needsN {
            var sigChallenges: [String] = []
            var nChallenges: [String] = []
            if let cipher = raw["signatureCipher"] as? String, let parts = parseCipher(cipher) {
                if needsSig { sigChallenges.append(parts.s) }
                if let nParam = nParameter(in: parts.url) { nChallenges.append(nParam.value) }
            } else if let plain = raw["url"] as? String, let nParam = nParameter(in: plain) {
                nChallenges.append(nParam.value)
            }
            log("solver: challenges cho itag \(itag) — sig ×\(sigChallenges.count), n ×\(nChallenges.count) (chỉ đếm, không ghi giá trị)")

            guard let playerJS = await acquirePlayerJS(videoId: videoId) else {
                return .failed(HarvestFailure(
                    token: "KHÔNG LẤY ĐƯỢC PLAYER JS",
                    detail: "KHÔNG LẤY ĐƯỢC PLAYER JS — cả nguồn tv-player-ias lẫn embed đều hỏng hoặc sai file (xem các dòng player-js ở trên)"))
            }
            log("player-js: dùng nguồn \(playerJS.source) — host \(playerJS.host), path \(playerJS.path), \(playerJS.text.utf8.count) bytes, marker ×\(playerJS.markerCount)")
            if let hash = Self.playerHash(fromPath: playerJS.path) {
                if let seen = seenPlayerHash {
                    log("player-js: hash \(hash) — \(hash == seen ? "TRÙNG với hash của ô trước" : "KHÁC hash của ô trước (\(seen))")")
                } else {
                    log("player-js: hash \(hash)")
                }
                seenPlayerHash = hash
            }

            var attempt = await runSolverAttempt(playerJS: playerJS,
                                                 sigChallenges: sigChallenges,
                                                 nChallenges: nChallenges)
            if let failure = solverFailure(attempt, needsSig: needsSig, needsN: needsN) {
                var finalVerdict: String? = failure.verdict
                if failure.retryable, playerJS.source == "tv-player-ias" {
                    log("solver: lần thử tv-player-ias chưa xong (\(failure.verdict)) — thử lại với player của trang embed")
                    if let embedJS = await fetchEmbedPlayerJS(videoId: videoId) {
                        let second = await runSolverAttempt(playerJS: embedJS,
                                                            sigChallenges: sigChallenges,
                                                            nChallenges: nChallenges)
                        if let secondFailure = solverFailure(second, needsSig: needsSig, needsN: needsN) {
                            finalVerdict = secondFailure.verdict
                        } else {
                            attempt = second
                            finalVerdict = nil
                        }
                    }
                }
                if let finalVerdict {
                    return .failed(HarvestFailure(token: summaryToken(forSolverVerdict: finalVerdict),
                                                  detail: finalVerdict))
                }
            }
            sigResults = attempt.sigResults
            nResults = attempt.nResults
        }

        let outcome = applySolved(itag: itag,
                                  rawURL: raw["url"] as? String,
                                  cipher: raw["signatureCipher"] as? String,
                                  sigResults: sigResults, nResults: nResults)
        switch outcome {
        case .failed(let why):
            return .failed(HarvestFailure(token: "KHÔNG KẾT ÁN ĐƯỢC",
                                          detail: "KHÔNG KẾT ÁN ĐƯỢC — \(why)"))
        case .solved(let url):
            let check = await byteCheck(url: url, userAgent: userAgent)
            if check.status == 0 {
                return .failed(HarvestFailure(
                    token: "KHÔNG KẾT ÁN ĐƯỢC",
                    detail: "KHÔNG KẾT ÁN ĐƯỢC — byte-check itag \(itag) lỗi mạng, không có HTTP response"))
            }
            guard (check.status == 200 || check.status == 206), check.bytes == 1024 else {
                return .failed(HarvestFailure(
                    token: "BYTE-CHECK BỊ TỪ CHỐI",
                    detail: "BYTE-CHECK BỊ TỪ CHỐI — itag \(itag) HTTP \(check.status), nhận \(check.bytes)/1024 bytes (kỳ vọng 206 + đủ 1024)"))
            }
            return .ok(status: check.status, bytes: check.bytes)
        }
    }

    // MARK: Player JS acquisition — Probe 19's, verbatim
    //
    // The FL-335 gate: a JS file is only accepted as THE
    // player if it carries the decipher machinery's
    // marker ("signatureCipher").

    private static let tvScrapeUA = "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.5) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/5.0 Chrome/85.0.4183.120 TV Safari/537.36"
    private static let embedUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private struct PlayerJS {
        var text: String
        var source: String
        var host: String
        var path: String
        var markerCount: Int
    }

    private func markerCount(in js: String) -> Int {
        var count = 0
        var searchFrom = js.startIndex
        while let found = js.range(of: "signatureCipher", range: searchFrom..<js.endIndex) {
            count += 1
            searchFrom = found.upperBound
        }
        return count
    }

    private func fetchPlayerFile(urlString: String, source: String,
                                 userAgent: String) async -> PlayerJS? {
        guard let js = await fetchText(urlString, userAgent: userAgent) else {
            log("player-js: tải file cho nguồn \(source) THẤT BẠI (\(urlString))")
            return nil
        }
        let markers = markerCount(in: js)
        let url = URL(string: urlString)
        let host = url?.host ?? "?"
        let path = url?.path ?? "?"
        guard js.utf8.count > 100_000 else {
            log("player-js: nguồn \(source) trả file quá ngắn (\(js.utf8.count) bytes) — không dùng")
            return nil
        }
        guard markers > 0 else {
            log("player-js: nguồn \(source) — file \(js.utf8.count) bytes nhưng marker signatureCipher ×0 — SAI FILE, loại")
            return nil
        }
        log("player-js: nguồn \(source) OK — host \(host), path \(path), \(js.utf8.count) bytes, marker signatureCipher ×\(markers)")
        return PlayerJS(text: js, source: source, host: host, path: path, markerCount: markers)
    }

    private func fetchTVPlayerJS() async -> PlayerJS? {
        guard let rawHTML = await fetchText("https://www.youtube.com/tv", userAgent: Self.tvScrapeUA) else {
            log("player-js: tải trang /tv THẤT BẠI")
            return nil
        }
        let html = rawHTML.replacingOccurrences(of: "\\/", with: "/")
        let patterns: [(label: String, pattern: String)] = [
            ("jsUrl tv-player-ias", #""jsUrl"\s*:\s*"([^"]*tv-player-ias[^"]*\.js)""#),
            ("player_url tv-player-ias", #""player_url"\s*:\s*"([^"]*tv-player-ias[^"]*\.js)""#),
            ("/s/player/*.js đầu tiên", #""(/s/player/[^"]*\.js)""#),
        ]
        for entry in patterns {
            if let src = regexCapture(in: html, pattern: entry.pattern, group: 1) {
                let full = src.hasPrefix("http") ? src : "https://www.youtube.com" + src
                log("player-js: trang /tv trỏ player bằng pattern '\(entry.label)' → path \(URL(string: full)?.path ?? src)")
                return await fetchPlayerFile(urlString: full, source: "tv-player-ias",
                                             userAgent: Self.tvScrapeUA)
            }
        }
        log("player-js: trang /tv không thấy tham chiếu player JS nào (cả 3 pattern đều miss)")
        return nil
    }

    private func fetchEmbedPlayerJS(videoId: String) async -> PlayerJS? {
        guard let rawHTML = await fetchText("https://www.youtube.com/embed/\(videoId)",
                                            userAgent: Self.embedUA) else {
            log("player-js: tải trang embed THẤT BẠI")
            return nil
        }
        let html = rawHTML.replacingOccurrences(of: "\\/", with: "/")
        guard let src = regexCapture(in: html, pattern: #""jsUrl"\s*:\s*"([^"]+)""#, group: 1) else {
            log("player-js: trang embed không có jsUrl")
            return nil
        }
        let full = src.hasPrefix("http") ? src : "https://www.youtube.com" + src
        log("player-js: trang embed trỏ jsUrl → path \(URL(string: full)?.path ?? src)")
        return await fetchPlayerFile(urlString: full, source: "embed",
                                     userAgent: Self.embedUA)
    }

    private func acquirePlayerJS(videoId: String) async -> PlayerJS? {
        if let tv = await fetchTVPlayerJS() { return tv }
        log("player-js: nguồn tv-player-ias không dùng được — rơi xuống nguồn embed")
        return await fetchEmbedPlayerJS(videoId: videoId)
    }

    private static func playerHash(fromPath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(of: "player"), index + 1 < parts.count {
            return parts[index + 1]
        }
        return nil
    }

    // MARK: EJS solver (vendored yt-dlp-ejs 0.8.0) —
    // Probe 19's harness, verbatim (names prefixed)

    private struct HarvestSolveOutcome: Sendable {
        var notes: [String] = []
        var loadErrorStep: String?
        var loadErrorMessage: String?
        var runErrorStep: String?
        var runErrorMessage: String?
        var sigResults: [String: String]?
        var sigError: String?
        var nResults: [String: String]?
        var nError: String?
        var elapsedMs: Int = 0
    }

    private enum HarvestSolver {

        static func solve(player: String, sigChallenges: [String],
                          nChallenges: [String]) -> HarvestSolveOutcome {
            var outcome = HarvestSolveOutcome()
            let t0 = Date()
            defer { outcome.elapsedMs = Int(Date().timeIntervalSince(t0) * 1000) }

            let createdContext: JSContext? = JSContext()
            guard let context = createdContext else {
                outcome.loadErrorStep = "solver load (JSContext)"
                outcome.loadErrorMessage = "không tạo được JSContext"
                return outcome
            }

            guard let libSource = bundledText("yt.solver.lib.min", "js") else {
                outcome.loadErrorStep = "solver load (lib resource)"
                outcome.loadErrorMessage = "không tìm thấy yt.solver.lib.min.js trong bundle"
                return outcome
            }
            _ = context.evaluateScript(libSource)
            if let message = takeException(from: context) {
                outcome.loadErrorStep = "solver load (lib eval)"
                outcome.loadErrorMessage = message
                return outcome
            }
            _ = context.evaluateScript("Object.assign(globalThis, lib);")
            if let message = takeException(from: context) {
                outcome.loadErrorStep = "solver load (Object.assign(globalThis, lib))"
                outcome.loadErrorMessage = message
                return outcome
            }
            let parseType = context.evaluateScript("typeof lib.meriyah.parse")?.toString() ?? "?"
            let generateType = context.evaluateScript("typeof lib.astring.generate")?.toString() ?? "?"
            outcome.notes.append("solver: lib nạp OK (\(libSource.utf8.count) bytes) — lib.meriyah.parse=\(parseType), lib.astring.generate=\(generateType)")
            guard parseType == "function", generateType == "function" else {
                outcome.loadErrorStep = "solver load (lib shape)"
                outcome.loadErrorMessage = "thiếu API — lib.meriyah.parse=\(parseType), lib.astring.generate=\(generateType)"
                return outcome
            }

            guard let coreSource = bundledText("yt.solver.core.min", "js") else {
                outcome.loadErrorStep = "solver load (core resource)"
                outcome.loadErrorMessage = "không tìm thấy yt.solver.core.min.js trong bundle"
                return outcome
            }
            _ = context.evaluateScript(coreSource)
            if let message = takeException(from: context) {
                outcome.loadErrorStep = "solver load (core eval)"
                outcome.loadErrorMessage = message
                return outcome
            }
            let jscType = context.evaluateScript("typeof jsc")?.toString() ?? "?"
            outcome.notes.append("solver: core nạp OK (\(coreSource.utf8.count) bytes) — typeof jsc=\(jscType)")
            guard jscType == "function" else {
                outcome.loadErrorStep = "solver load (jsc)"
                outcome.loadErrorMessage = "jsc không phải function (typeof=\(jscType))"
                return outcome
            }

            context.setObject(player, forKeyedSubscript: "__ejsPlayer" as NSString)
            context.setObject(sigChallenges, forKeyedSubscript: "__ejsSigChallenges" as NSString)
            context.setObject(nChallenges, forKeyedSubscript: "__ejsNChallenges" as NSString)
            let driver = """
            (function () {
              var requests = [];
              if (__ejsSigChallenges.length > 0) { requests.push({type: "sig", challenges: __ejsSigChallenges}); }
              if (__ejsNChallenges.length > 0) { requests.push({type: "n", challenges: __ejsNChallenges}); }
              var output = jsc({type: "player", player: __ejsPlayer, requests: requests, output_preprocessed: false});
              return JSON.stringify(output);
            })()
            """
            let result = context.evaluateScript(driver)
            if let message = takeException(from: context) {
                outcome.runErrorStep = "solver run (jsc)"
                outcome.runErrorMessage = message
                return outcome
            }
            guard let jsonText = result?.toString(),
                  !jsonText.isEmpty, jsonText != "undefined" else {
                outcome.runErrorStep = "solver run (output)"
                outcome.runErrorMessage = "jsc không trả về chuỗi JSON"
                return outcome
            }
            guard let parsed = (try? JSONSerialization.jsonObject(with: Data(jsonText.utf8))) as? [String: Any] else {
                outcome.runErrorStep = "solver run (output parse)"
                outcome.runErrorMessage = "JSON từ jsc không parse được (\(jsonText.utf8.count) bytes)"
                return outcome
            }
            if (parsed["type"] as? String) == "error" {
                outcome.runErrorStep = "solver run (jsc output)"
                outcome.runErrorMessage = (parsed["error"] as? String) ?? "output type=error, không có text"
                return outcome
            }
            let responses = parsed["responses"] as? [[String: Any]] ?? []
            var index = 0
            if !sigChallenges.isEmpty {
                readResponse(responses, at: index, kind: "sig", into: &outcome)
                index += 1
            }
            if !nChallenges.isEmpty {
                readResponse(responses, at: index, kind: "n", into: &outcome)
                index += 1
            }
            return outcome
        }

        private static func readResponse(_ responses: [[String: Any]], at index: Int,
                                         kind: String, into outcome: inout HarvestSolveOutcome) {
            guard index < responses.count else {
                setError(&outcome, kind: kind,
                         message: "solver không trả response cho \(kind)")
                outcome.notes.append("solver: \(kind) — KHÔNG có response")
                return
            }
            let response = responses[index]
            if (response["type"] as? String) == "error" {
                let raw = (response["error"] as? String) ?? "error không có text"
                let trimmed = raw.count > 300 ? String(raw.prefix(300)) + "…" : raw
                setError(&outcome, kind: kind, message: trimmed)
                outcome.notes.append("solver: \(kind) — KHÔNG NHẬN DIỆN ĐƯỢC: \(trimmed)")
                return
            }
            let data = response["data"] as? [String: String] ?? [:]
            let lengths = data.values.map { $0.count }.sorted()
            if kind == "sig" { outcome.sigResults = data } else { outcome.nResults = data }
            outcome.notes.append("solver: \(kind) — NHẬN DIỆN ĐƯỢC, giải \(data.count) challenge, độ dài kết quả \(lengths)")
        }

        private static func setError(_ outcome: inout HarvestSolveOutcome,
                                     kind: String, message: String) {
            if kind == "sig" { outcome.sigError = message } else { outcome.nError = message }
        }

        private static func bundledText(_ name: String, _ ext: String) -> String? {
            guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
                return nil
            }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }

        private static func takeException(from context: JSContext) -> String? {
            guard let exception = context.exception, !exception.isUndefined else { return nil }
            context.exception = nil
            return exception.toString() ?? "JS exception (không có text)"
        }
    }

    private func runSolverAttempt(playerJS: PlayerJS, sigChallenges: [String],
                                  nChallenges: [String]) async -> HarvestSolveOutcome {
        let playerText = playerJS.text
        let source = playerJS.source
        let outcome = await Task.detached(priority: .userInitiated) { () -> HarvestSolveOutcome in
            HarvestSolver.solve(player: playerText, sigChallenges: sigChallenges,
                                nChallenges: nChallenges)
        }.value
        log("solver: lần thử với nguồn \(source) xong sau \(outcome.elapsedMs)ms")
        for note in outcome.notes { log(note) }
        return outcome
    }

    // MARK: Cipher handling — Probe 19's, verbatim

    private struct CipherParts {
        var s: String
        var sp: String
        var url: String
    }

    private func parseCipher(_ cipher: String) -> CipherParts? {
        var fields: [String: String] = [:]
        for pair in cipher.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            fields[key] = value
        }
        guard let s = fields["s"], let url = fields["url"] else { return nil }
        return CipherParts(s: s, sp: fields["sp"] ?? "signature", url: url)
    }

    private func percentEncodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func nParameter(in url: String) -> (value: String, range: Range<String.Index>)? {
        let question = url.range(of: "?n=")
        let amp = url.range(of: "&n=")
        let marker: Range<String.Index>?
        switch (question, amp) {
        case let (q?, a?): marker = q.lowerBound < a.lowerBound ? q : a
        case let (q?, nil): marker = q
        case let (nil, a?): marker = a
        case (nil, nil): marker = nil
        }
        guard let marker else { return nil }
        let valueStart = marker.upperBound
        let valueEnd = url.range(of: "&", range: valueStart..<url.endIndex)?.lowerBound ?? url.endIndex
        let raw = String(url[valueStart..<valueEnd])
        return (raw.removingPercentEncoding ?? raw, valueStart..<valueEnd)
    }

    // MARK: Apply — Probe 19's assembly, fed by the solver's maps

    private enum SolveOutcome {
        case solved(url: URL)
        case failed(why: String)
    }

    private func applySolved(itag: Int, rawURL: String?, cipher: String?,
                             sigResults: [String: String]?,
                             nResults: [String: String]?) -> SolveOutcome {
        var urlString: String
        var deciphered = false
        if let rawURL {
            urlString = rawURL
            log("sign: itag \(itag) — URL trần có sẵn, bỏ qua decipher")
        } else if let cipher {
            guard let parts = parseCipher(cipher) else {
                return .failed(why: "apply: itag \(itag) signatureCipher không parse được (thiếu s hoặc url)")
            }
            guard let solvedSig = sigResults?[parts.s], !solvedSig.isEmpty else {
                return .failed(why: "apply: solver không có kết quả sig cho itag \(itag)")
            }
            urlString = parts.url + "&" + parts.sp + "=" + percentEncodeQueryValue(solvedSig)
            deciphered = true
        } else {
            return .failed(why: "apply: itag \(itag) không có url cũng không có signatureCipher")
        }
        var nNote = "n=không có"
        if let nParam = nParameter(in: urlString) {
            if let solvedN = nResults?[nParam.value], !solvedN.isEmpty {
                urlString.replaceSubrange(nParam.range, with: percentEncodeQueryValue(solvedN))
                nNote = "n=CÓ (len \(nParam.value.count)→\(solvedN.count))"
            } else if nResults != nil {
                return .failed(why: "apply: solver không có kết quả n cho itag \(itag)")
            } else {
                nNote = "n=CÓ nhưng solver không chạy cho n — giữ nguyên giá trị cũ"
            }
        }
        guard let url = URL(string: urlString) else {
            return .failed(why: "apply: itag \(itag) URL sau giải mã không hợp lệ")
        }
        log("sign: itag \(itag) — decipher=\(deciphered ? "OK" : "không cần") · \(nNote) · host \(url.host ?? "?")")
        return .solved(url: url)
    }

    // MARK: Byte check — Probe 19's, verbatim

    /// Range byte-check: ask for the first 1024 bytes
    /// and STOP reading there (a server that ignores the
    /// Range header and answers 200 must not stream a
    /// whole episode into the probe).
    private func byteCheck(url: URL, userAgent: String) async -> (status: Int, bytes: Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            var count = 0
            do {
                for try await _ in bytes {
                    count += 1
                    if count >= 1024 { break }
                }
            } catch {
                // A stream cut after some bytes still
                // proves the door opened; the count stands.
            }
            return (status, count)
        } catch {
            return (0, 0)
        }
    }

    // MARK: Solver outcome interpretation — Probe 19's, verbatim

    private func solverFailure(_ outcome: HarvestSolveOutcome,
                               needsSig: Bool, needsN: Bool) -> (verdict: String, retryable: Bool)? {
        if let step = outcome.loadErrorStep {
            return ("SOLVER KHÔNG NẠP ĐƯỢC — \(step): \(outcome.loadErrorMessage ?? "")", false)
        }
        if let step = outcome.runErrorStep {
            return ("SOLVER CHẠY LỖI — \(step): \(outcome.runErrorMessage ?? "")", true)
        }
        if needsSig, let sigError = outcome.sigError {
            return ("SOLVER KHÔNG NHẬN DIỆN ĐƯỢC — sig: \(sigError)", true)
        }
        if needsN, let nError = outcome.nError {
            return ("SOLVER KHÔNG NHẬN DIỆN ĐƯỢC — n: \(nError)", true)
        }
        if needsSig, outcome.sigResults == nil {
            return ("KHÔNG KẾT ÁN ĐƯỢC — solver không trả kết quả sig mà cũng không báo lỗi", false)
        }
        if needsN, outcome.nResults == nil {
            return ("KHÔNG KẾT ÁN ĐƯỢC — solver không trả kết quả n mà cũng không báo lỗi", false)
        }
        return nil
    }

    private func summaryToken(forSolverVerdict verdict: String) -> String {
        if let range = verdict.range(of: " — ") {
            return String(verdict[..<range.lowerBound])
        }
        return verdict
    }

    // MARK: P20-5 — WebView PO-token mint, PRESENCE ONLY
    //
    // The Probe 13 phase-1B mint chain, copied without
    // behavioural changes (the TV living-room recipe:
    // /tv scrape → tv_config → BotGuard in a WKWebView →
    // GenerateIT → obtainPoToken). Probe 20 stops the
    // moment a token exists: presence + length + elapsed
    // are the whole product. NO SABR fetch follows.

    private static let tizenUA = "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.5) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/5.0 Chrome/85.0.4183.120 TV Safari/537.36"

    private func fetchTextWithStatus(_ urlString: String, userAgent: String,
                                     referer: String?) async -> (http: Int, text: String)? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            return (http, String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }

    private func jnnPost(_ urlString: String, array: [Any],
                         userAgent: String) async -> (http: Int, array: [Any]?, bytes: Int) {
        guard let url = URL(string: urlString),
              let body = try? JSONSerialization.data(withJSONObject: array) else {
            return (0, nil, 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "x-user-agent")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
            return (http, parsed, data.count)
        } catch {
            log("mint: POST jnn lỗi mạng — \(error.localizedDescription)")
            return (0, nil, 0)
        }
    }

    /// Poll window.__probeMint until a terminal step
    /// shows or the budget runs out; logs every step
    /// transition (Probe 13B's pattern).
    private func pollMintState(terminalSteps: Set<String>,
                               timeoutSeconds: Int) async -> [String: Any]? {
        var lastStep = ""
        var lastState: [String: Any]?
        let polls = max(1, timeoutSeconds * 2 / 3)
        for _ in 0..<polls {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let raw = await evaluateMint("JSON.stringify(window.__probeMint || {step: 'gone'})"),
                  let data = raw.data(using: .utf8),
                  let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let step = state["step"] as? String else { continue }
            lastState = state
            if step != lastStep {
                lastStep = step
                log("mint: bước WebView → \(step)")
            }
            if terminalSteps.contains(step) { return state }
        }
        return lastState
    }

    private func mintPoToken() async -> SabrMintOutcome {
        // 1 — Session identifiers from the /tv page.
        guard let tvHTML = await fetchText("https://www.youtube.com/tv",
                                            userAgent: Self.tizenUA) else {
            return .failed(step: "cạo trang /tv — fetch lỗi, không lấy được trang để tìm livingRoomPoTokenId/visitorData")
        }
        let livingRoom = firstRegexCapture(in: tvHTML, pattern: "\"livingRoomPoTokenId\"\\s*:\\s*\"([^\"]+)\"")
            ?? firstRegexCapture(in: tvHTML, pattern: "\"LIVING_ROOM_PO_TOKEN_ID\"\\s*:\\s*\"([^\"]+)\"")
        let visitor = firstRegexCapture(in: tvHTML, pattern: "\"VISITOR_DATA\"\\s*:\\s*\"([^\"]+)\"")
            ?? firstRegexCapture(in: tvHTML, pattern: "\"visitorData\"\\s*:\\s*\"([^\"]+)\"")
        log("mint: /tv scrape (\(tvHTML.count) bytes) — livingRoomPoTokenId \(livingRoom.map { "CÓ (len \($0.count))" } ?? "KHÔNG THẤY") · visitorData \(visitor.map { "CÓ (len \($0.count))" } ?? "KHÔNG THẤY")")
        guard let identifier = livingRoom ?? visitor else {
            return .failed(step: "cạo trang /tv — không thấy livingRoomPoTokenId lẫn VISITOR_DATA trong HTML /tv")
        }
        let identifierKind = livingRoom != nil ? "livingRoomPoTokenId" : "visitorData"
        log("mint: identifier của mint = \(identifierKind) (len \(identifier.count), không ghi giá trị)")

        // 2 — The TV client's own challenge (tv_config).
        let configURL = "https://www.youtube.com/tv_config?action_get_config=true&client=lb4&theme=cl"
        guard let configFetch = await fetchTextWithStatus(configURL, userAgent: Self.tizenUA,
                                                          referer: "https://www.youtube.com/tv") else {
            return .failed(step: "tv_config — fetch lỗi mạng")
        }
        log("mint: tv_config HTTP \(configFetch.http) · \(configFetch.text.count) bytes")
        guard configFetch.http == 200 else {
            return .failed(step: "tv_config — HTTP \(configFetch.http)")
        }
        var configText = configFetch.text
        if configText.hasPrefix(")]}'") { configText = String(configText.dropFirst(4)) }
        configText = configText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configData = configText.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: configData)) as? [String: Any] else {
            return .failed(step: "tv_config — đáp án không phải JSON object")
        }
        let challengeParams = root["challengeParams"] as? [String: Any]
        var rObject: [String: Any]?
        if let rString = challengeParams?["R"] as? String,
           let rData = rString.data(using: .utf8) {
            rObject = (try? JSONSerialization.jsonObject(with: rData)) as? [String: Any]
        } else if let rDict = challengeParams?["R"] as? [String: Any] {
            rObject = rDict
        }
        log("mint: tv_config keys — root: \(root.keys.sorted().joined(separator: ",")) · challengeParams: \(challengeParams?.keys.sorted().joined(separator: ",") ?? "—") · R: \(rObject?.keys.sorted().joined(separator: ",") ?? "—")")
        let bgChallenge = (rObject?["bgChallenge"] as? [String: Any])
            ?? (challengeParams?["bgChallenge"] as? [String: Any])
            ?? (rObject?.keys.contains("program") == true ? rObject : nil)
        let requestKey = (rObject?["challengeRequestKey"] as? String)
            ?? (challengeParams?["challengeRequestKey"] as? String)
            ?? (root["challengeRequestKey"] as? String)
        guard let bgChallenge,
              let program = bgChallenge["program"] as? String,
              let globalName = bgChallenge["globalName"] as? String else {
            return .failed(step: "tv_config — không tìm thấy bgChallenge/program/globalName (kho keys đã ghi ở trên)")
        }
        guard let requestKey else {
            return .failed(step: "tv_config — không tìm thấy challengeRequestKey cho GenerateIT")
        }
        log("mint: bgChallenge CÓ — program len \(program.count) · globalName \"\(globalName)\" · challengeRequestKey len \(requestKey.count)")

        // 2b — The BotGuard interpreter: inline if the
        // challenge carries it, else fetch its URL.
        var interpreterSource: String?
        var interpreterOrigin = ""
        if let wrapped = bgChallenge["interpreterJavascript"] as? [String: Any] {
            if let inline = wrapped["privateDoNotAccessOrElseSafeScriptWrappedValue"] as? String,
               !inline.isEmpty {
                interpreterSource = inline
                interpreterOrigin = "inline trong bgChallenge"
            } else if let urlString = wrapped["privateDoNotAccessOrElseSafeResourceUrlWrappedValue"] as? String,
                      let fetched = await fetchText(urlString, userAgent: Self.tizenUA) {
                interpreterSource = fetched
                interpreterOrigin = "URL trong bgChallenge (host \(URL(string: urlString)?.host ?? "?"))"
            }
        }
        if interpreterSource == nil, let urlValue = bgChallenge["interpreterUrl"] {
            let urlString = (urlValue as? String)
                ?? ((urlValue as? [String: Any])?["privateDoNotAccessOrElseSafeResourceUrlWrappedValue"] as? String)
            if let urlString, let fetched = await fetchText(urlString, userAgent: Self.tizenUA) {
                interpreterSource = fetched
                interpreterOrigin = "interpreterUrl (host \(URL(string: urlString)?.host ?? "?"))"
            }
        }
        guard let interpreter = interpreterSource else {
            return .failed(step: "tv_config — bgChallenge không có interpreter dùng được (inline lẫn URL đều trống/hỏng)")
        }
        log("mint: interpreter từ \(interpreterOrigin) — \(interpreter.count) bytes")

        // 3 — Run BotGuard in the WebView.
        var challengeForJS: [String: Any] = [
            "program": program,
            "globalName": globalName,
            "interpreterJavascript": [
                "privateDoNotAccessOrElseSafeScriptWrappedValue": interpreter,
            ],
        ]
        if let blob = bgChallenge["clientExperimentsStateBlob"] as? String {
            challengeForJS["clientExperimentsStateBlob"] = blob
            log("mint: clientExperimentsStateBlob CÓ (len \(blob.count)) — chuyển kèm vào WebView")
        }
        guard let inputJSON = jsonEncodedObject(["challenge": challengeForJS]) else {
            return .failed(step: "mint — không JSON-encode được challenge để đưa vào WebView")
        }
        log("mint: nạp trang /tv vào WebView mint…")
        mintController.load(url: "https://www.youtube.com/tv",
                            userAgent: Self.tizenUA, lockedURL: nil)
        var pageReady = false
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if await evaluateMint("document.readyState") == "complete" {
                pageReady = true
                break
            }
        }
        guard pageReady else {
            return .failed(step: "WebView — trang /tv không load xong trong ~30s (readyState không tới complete)")
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        _ = await evaluateMint("window.__probeMintInput = \(inputJSON); 'set'")
        let installResult = await evaluateMint(Self.mintHarnessJS)
        log("mint: harness BotGuard cài xong (\(installResult ?? "không đáp")) — chờ snapshot…")
        guard installResult == "started" else {
            return .failed(step: "WebView — script mint không khởi động được (evaluate trả \(installResult ?? "nil"))")
        }
        let snapState = await pollMintState(terminalSteps: ["snapshot-done", "botguard-error", "gone"],
                                            timeoutSeconds: 60)
        guard let snapStep = snapState?["step"] as? String, snapStep == "snapshot-done" else {
            let step = (snapState?["step"] as? String) ?? "timeout"
            let error = (snapState?["error"] as? String) ?? ""
            return .failed(step: "BotGuard trong WebView dừng ở bước '\(step)'\(error.isEmpty ? "" : " — \(error)")")
        }
        guard let botguardResponse = await evaluateMint("window.__probeMintResult.botguardResponse"),
              !botguardResponse.isEmpty else {
            return .failed(step: "BotGuard — snapshot báo xong nhưng botguardResponse rỗng/không đọc được từ trang")
        }
        log("mint: snapshot OK — botguardResponse len \(botguardResponse.count) (không ghi giá trị)")

        // 4 — GenerateIT: botguardResponse → integrity token.
        let generateIT = await jnnPost("https://www.youtube.com/api/jnn/v1/GenerateIT",
                                       array: [requestKey, botguardResponse],
                                       userAgent: Self.tizenUA)
        log("mint: GenerateIT HTTP \(generateIT.http) · \(generateIT.bytes)B")
        guard generateIT.http == 200, let answer = generateIT.array,
              let tokenString = answer.first as? String,
              let integrityBytes = decodeBase64Loose(tokenString) else {
            return .failed(step: "GenerateIT — HTTP \(generateIT.http), đáp án không chứa integrity token ở phần tử [0]")
        }
        let ttl = answer.count > 1 ? (answer[1] as? NSNumber)?.intValue : nil
        log("mint: integrity token CÓ — \(integrityBytes.count)B · TTL \(ttl.map { "\($0)s" } ?? "?") (không ghi giá trị)")

        // 5 — obtainPoToken in the page → the session token.
        let bytesJSON = "[" + integrityBytes.map { "\($0)" }.joined(separator: ",") + "]"
        _ = await evaluateMint("window.__probeMintInput.integrityTokenBytes = \(bytesJSON); 'set'")
        guard let identifierJSON = jsonEncodedString(identifier) else {
            return .failed(step: "mint — không JSON-encode được identifier")
        }
        _ = await evaluateMint("window.__probeMintInput.identifier = \(identifierJSON); 'set'")
        let finishStep = await evaluateMint(Self.mintFinishJS)
        guard finishStep == "token-done" else {
            let error = await evaluateMint("window.__probeMint.error") ?? ""
            return .failed(step: "obtainPoToken trong WebView dừng ở bước '\(finishStep ?? "không đáp")'\(error.isEmpty ? "" : " — \(error)")")
        }
        guard let tokenB64 = await evaluateMint("window.__probeMint.tokenB64"),
              let tokenData = decodeBase64Loose(tokenB64), !tokenData.isEmpty else {
            return .failed(step: "obtainPoToken — tokenB64 không đọc/giải mã được từ trang")
        }
        log("mint: PO token ĐÃ MINT — len \(tokenData.count) (chỉ ghi độ dài; giá trị không rời máy — Probe 20 dừng ở đây, KHÔNG fetch SABR)")
        return .token(tokenData)
    }

    /// The BotGuard harness — Probe 13B's faithful port
    /// of the canonical po_token.html BotGuardClient
    /// (BgUtils / NewPipe), copied verbatim. State lands
    /// in window.__probeMint; the snapshot result in
    /// window.__probeMintResult.
    static let mintHarnessJS = #"""
        (function () {
          var S = window.__probeMint = {
            step: 'init', error: '', tokenB64: '', tokenLen: 0, bgResponseLen: 0
          };
          var BG = { vmFunctions: null, syncSnapshotFunction: null };

          function loadBotGuard(challengeData) {
            var vm = window[challengeData.globalName];
            if (!vm) throw new Error('[BotGuardClient]: VM not found in the global object');
            if (!vm.a) throw new Error('[BotGuardClient]: Could not load program');
            var vmFunctionsCallback = function (asyncSnapshotFunction, shutdownFunction,
                                                passEventFunction, checkCameraFunction) {
              BG.vmFunctions = {
                asyncSnapshotFunction: asyncSnapshotFunction,
                shutdownFunction: shutdownFunction,
                passEventFunction: passEventFunction,
                checkCameraFunction: checkCameraFunction
              };
            };
            BG.syncSnapshotFunction = vm.a(challengeData.program, vmFunctionsCallback, true,
              document.body, function () {}, [[], []])[0];
            return new Promise(function (resolve, reject) {
              var i = 0;
              var refreshIntervalId = setInterval(function () {
                if (BG.vmFunctions && BG.vmFunctions.asyncSnapshotFunction) {
                  resolve(BG);
                  clearInterval(refreshIntervalId);
                }
                if (i >= 10000) {
                  reject(new Error('asyncSnapshotFunction is null even after 10 seconds'));
                  clearInterval(refreshIntervalId);
                }
                i += 1;
              }, 1);
            });
          }

          function snapshot(args) {
            return new Promise(function (resolve, reject) {
              if (!BG.vmFunctions || !BG.vmFunctions.asyncSnapshotFunction) {
                reject(new Error('[BotGuardClient]: Async snapshot function not found'));
                return;
              }
              BG.vmFunctions.asyncSnapshotFunction(function (response) { resolve(response); }, [
                args.contentBinding,
                args.signedTimestamp,
                args.webPoSignalOutput,
                args.skipPrivacyBuffer
              ]);
            });
          }

          function runBotGuard(challengeData) {
            var interpreterJavascript =
              challengeData.interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue;
            if (interpreterJavascript) {
              new Function(interpreterJavascript)();
            } else {
              throw new Error('Could not load VM');
            }
            var webPoSignalOutput = [];
            return loadBotGuard({
              globalName: challengeData.globalName,
              program: challengeData.program
            }).then(function () {
              return snapshot({ webPoSignalOutput: webPoSignalOutput });
            }).then(function (botguardResponse) {
              return { webPoSignalOutput: webPoSignalOutput, botguardResponse: botguardResponse };
            });
          }

          function obtainPoToken(webPoSignalOutput, integrityToken, identifier) {
            var getMinter = webPoSignalOutput[0];
            if (!getMinter) throw new Error('PMD:Undefined');
            var mintCallback = getMinter(integrityToken);
            if (!(mintCallback instanceof Function)) throw new Error('APF:Failed');
            var result = mintCallback(identifier);
            if (!result) throw new Error('YNJ:Undefined');
            if (!(result instanceof Uint8Array)) throw new Error('ODM:Invalid');
            return result;
          }

          window.__probeMintObtain = obtainPoToken;

          var input = window.__probeMintInput || {};
          S.step = 'running-botguard';
          runBotGuard(input.challenge).then(function (result) {
            window.__probeMintResult = result;
            S.bgResponseLen = result.botguardResponse ? String(result.botguardResponse).length : 0;
            S.step = 'snapshot-done';
          }).catch(function (e) {
            S.step = 'botguard-error';
            S.error = String((e && e.message) || e).slice(0, 120);
          });
          return 'started';
        })()
        """#

    /// Second mint half: integrity token + identifier
    /// in, PO token (base64) out via window.__probeMint.
    static let mintFinishJS = #"""
        (function () {
          var S = window.__probeMint;
          var input = window.__probeMintInput || {};
          var result = window.__probeMintResult;
          try {
            if (!result) throw new Error('no snapshot result');
            var integrity = new Uint8Array(input.integrityTokenBytes || []);
            var identifier = new TextEncoder().encode(String(input.identifier || ''));
            var token = window.__probeMintObtain(result.webPoSignalOutput, integrity, identifier);
            var binary = '';
            for (var i = 0; i < token.length; i++) binary += String.fromCharCode(token[i]);
            S.tokenB64 = btoa(binary);
            S.tokenLen = token.length;
            S.step = 'token-done';
          } catch (e) {
            S.step = 'mint-error';
            S.error = String((e && e.message) || e).slice(0, 120);
          }
          return S.step;
        })()
        """#

    /// P20-5's cell wrapper: run the mint, report
    /// presence + length + elapsed ONLY, then stop.
    private func runMintPresenceCell() async -> (token: String, detail: String) {
        log("danh tính của ô: phiên cửa (Probe 4) trong WebView mint — recipe TV living-room như Probe 13B; ô này CHỈ kiểm sự hiện diện của PO token, không fetch SABR, không phát")
        let t0 = Date()
        switch await mintPoToken() {
        case .token(let data):
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let detail = "PO TOKEN CÓ — len \(data.count), mint xong sau \(ms)ms (chỉ ghi độ dài; R giai đoạn 2 thành việc đáng thiết kế — ô này không kết luận gì thêm)"
            log("KẾT QUẢ P20-5: \(detail)")
            return ("TOKEN CÓ", detail)
        case .failed(let step):
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let detail = "PO TOKEN KHÔNG — mint gãy sau \(ms)ms ở bước: \(step)"
            log("KẾT QUẢ P20-5: \(detail)")
            return ("TOKEN KHÔNG", detail)
        }
    }

    // MARK: The run — one door sign-in feeds every cell
    //
    // Order per target: P20-1 (harvest) → P20-3 (in-page
    // fetch in the SAME loaded page, per its contingency
    // definition). Then P20-2 per target (native, no
    // page), then P20-5 (mint presence). The summary
    // prints ONLY after every cell has finished (FL-330).

    private func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        lines = []
        verdict = ""
        seenPlayerHash = nil
        cellPrefix = ""

        log("=== PROBE 20 — GẶT NGUỒN: ĐỌC streamingData SAU CỬA ĐĂNG NHẬP (FL-351 vòng 3, panel Team D) ===")
        log("Tựa bị cap: Nhân Chứng tập 1 · videoId \(Self.cappedVid) (mọi đường InnerTube chỉ tới itag 135/480p)")
        log("Tựa đối chứng: tập Gold của Probe 16 · videoId \(Self.controlVid) (đường TV cấp 137/1080p)")
        log("Một lần đăng nhập cửa (Probe 4) nuôi cả bốn ô: P20-1 Gặt · P20-2 web_embedded bằng cookie cửa · P20-3 fetch trong trang · P20-5 kiểm PO token (chỉ hiện diện)")
        log("solver: yt-dlp-ejs 0.8.0 vendored — chỉ chạy khi format bị cipher hoặc mang tham số n")

        let cappedName = "tựa bị cap"
        let controlName = "tựa đối chứng"

        func noSessionFacts() -> OfferFacts {
            var facts = OfferFacts()
            facts.detail = "KHÔNG KẾT ÁN ĐƯỢC — không có phiên đăng nhập cửa (xem dòng session ở đầu log)"
            return facts
        }

        var f1cap = noSessionFacts(), f1ctl = noSessionFacts()
        var f3cap = noSessionFacts(), f3ctl = noSessionFacts()
        var f2cap = noSessionFacts(), f2ctl = noSessionFacts()
        var mintToken = "KHÔNG KẾT ÁN ĐƯỢC"
        var mintDetail = "KHÔNG KẾT ÁN ĐƯỢC — không có phiên đăng nhập cửa"

        if await sessionReady() {
            // P20-1 + P20-3 per target (P20-3 rides the
            // page P20-1 leaves loaded).
            cellPrefix = "P20-1 · "
            log("—— P20-1 · HARVEST · vid \(Self.cappedVid) (\(cappedName)) ——")
            f1cap = await harvestTarget(videoId: Self.cappedVid, targetName: cappedName)
            cellPrefix = "P20-3 · "
            log("—— P20-3 · FETCH TRONG TRANG · vid \(Self.cappedVid) (\(cappedName)) ——")
            log("danh tính của ô: chính trang watch đã đăng nhập mà P20-1 vừa gặt — fetch /player từ context của trang (ytcfg của trang, credentials include)")
            f3cap = await inPageFetchTarget(videoId: Self.cappedVid, targetName: cappedName)
            cellPrefix = "P20-1 · "
            log("—— P20-1 · HARVEST · vid \(Self.controlVid) (\(controlName)) ——")
            f1ctl = await harvestTarget(videoId: Self.controlVid, targetName: controlName)
            cellPrefix = "P20-3 · "
            log("—— P20-3 · FETCH TRONG TRANG · vid \(Self.controlVid) (\(controlName)) ——")
            log("danh tính của ô: chính trang watch đã đăng nhập mà P20-1 vừa gặt — fetch /player từ context của trang (ytcfg của trang, credentials include)")
            f3ctl = await inPageFetchTarget(videoId: Self.controlVid, targetName: controlName)

            // P20-2 per target (native cookie recipe).
            cellPrefix = "P20-2 · "
            log("—— P20-2 · WEB_EMBEDDED + COOKIE CỬA · vid \(Self.cappedVid) (\(cappedName)) ——")
            f2cap = await runReconciliationCell(videoId: Self.cappedVid, targetName: cappedName)
            cellPrefix = "P20-2 · "
            log("—— P20-2 · WEB_EMBEDDED + COOKIE CỬA · vid \(Self.controlVid) (\(controlName)) ——")
            f2ctl = await runReconciliationCell(videoId: Self.controlVid, targetName: controlName)

            // P20-5 — mint presence only.
            cellPrefix = "P20-5 · "
            log("—— P20-5 · PO TOKEN TRONG WEBVIEW — CHỈ KIỂM HIỆN DIỆN (R giai đoạn 1) ——")
            let mint = await runMintPresenceCell()
            mintToken = mint.token
            mintDetail = mint.detail
            cellPrefix = ""
        } else {
            log("KẾT QUẢ P20-1 [\(cappedName)]: \(f1cap.detail)")
            log("KẾT QUẢ P20-1 [\(controlName)]: \(f1ctl.detail)")
            log("KẾT QUẢ P20-3 [\(cappedName)]: \(f3cap.detail)")
            log("KẾT QUẢ P20-3 [\(controlName)]: \(f3ctl.detail)")
            log("KẾT QUẢ P20-2 [\(cappedName)]: \(f2cap.detail)")
            log("KẾT QUẢ P20-2 [\(controlName)]: \(f2ctl.detail)")
            log("KẾT QUẢ P20-5: \(mintDetail)")
        }

        // Summary — ONLY now (FL-330).
        let cappedRuns: [(label: String, facts: OfferFacts)] = [
            ("P20-1", f1cap), ("P20-2", f2cap), ("P20-3", f3cap),
        ]
        let controlRuns: [(label: String, facts: OfferFacts)] = [
            ("P20-1", f1ctl), ("P20-2", f2ctl), ("P20-3", f3ctl),
        ]
        let cappedSummary = cappedRuns.map { "\($0.label)=\($0.facts.token)" }.joined(separator: " · ")
            + " · P20-5=\(mintToken)"
        let controlSummary = controlRuns.map { "\($0.label)=\($0.facts.token)" }.joined(separator: " · ")
            + " · P20-5=\(mintToken)"
        log("KẾT QUẢ probe20 [tựa bị cap]: \(cappedSummary)")
        log("KẾT QUẢ probe20 [tựa đối chứng]: \(controlSummary)")
        log("P20-5 (R giai đoạn 1): \(mintDetail)")

        let winners = cappedRuns.filter { $0.facts.beatsCeiling }
        if winners.isEmpty {
            verdict = "KHÔNG Ô NÀO THẮNG TRẦN 480p trên tựa bị cap"
            log("KẾT LUẬN TRẦN 480p: KHÔNG ô nào (Gặt / web_embedded-cookie / fetch-trong-trang) đưa census trên tựa bị cap vượt itag 135 kèm byte-check — phiên trình duyệt của chính anh cũng không phá được trần ở vòng này; P20-5: \(mintToken)")
        } else {
            let names = winners.map { entry -> String in
                let f = entry.facts
                if f.bestAvcHeight > 480, f.byteOK {
                    return "\(entry.label) (AVC itag \(f.bestAvcItag) \(f.bestAvcHeight)p, byte-check OK)"
                }
                return "\(entry.label) (HLS max \(f.hlsMaxHeight)p, byte-check segment OK)"
            }
            verdict = "CÓ Ô THẮNG TRẦN 480p: \(names.joined(separator: ", "))"
            log("KẾT LUẬN TRẦN 480p: CÓ Ô THẮNG — \(names.joined(separator: ", ")) — census trên tựa bị cap đã vượt itag 135 kèm byte-check đạt")
        }
        log("Gửi file log về như thường lệ (link ở màn hình chính) — toàn bộ kiểm kê nằm trong log.")
    }
}

// MARK: - View

struct HarvestProbeView: View {
    var onExit: () -> Void
    @StateObject private var model = HarvestProbeModel()
    @State private var doorPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Probe 20 — Gặt nguồn: đọc streamingData sau cửa đăng nhập")
                .font(.title3).bold()
            Text("Bốn ô, MỘT lần đăng nhập cửa (Probe 4): P20-1 GẶT — mở trang phim bản máy tính trong phiên đã đăng nhập và đọc thẳng phần streamingData mà YouTube đã gửi cho trình duyệt (chưa probe nào đọc phần này); trang không phát được cũng không sao, mình chỉ GẶT dữ liệu rồi phát bằng trình native. P20-2 — công thức web_embedded của Probe 19 nhưng bằng cookie cửa thay token (token đã bị 400). P20-3 — nhờ chính trang đang mở hỏi /player từ trong trang. P20-5 — chỉ kiểm WebView có đúc được PO token không (hiện diện + độ dài), không làm gì thêm. Ô P20-1/P20-3 dùng bề mặt trang bên dưới; P20-5 dùng bề mặt mint dưới cùng — cả hai tự chạy, không cần bấm gì.")
                .font(.footnote).foregroundStyle(.secondary)
            if model.needsDoor {
                VStack(spacing: 10) {
                    Text("CHƯA CÓ PHIÊN ĐĂNG NHẬP CỬA")
                        .font(.headline)
                    Text("Probe 20 cần phiên đăng nhập của Probe 4 (cùng kho cookie). Mở cửa, đăng nhập như các đợt trước; đóng cửa xong probe tự chạy.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Button("Mở cửa đăng nhập (Probe 4)") { doorPresented = true }
                        .font(.system(size: 26, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.yellow.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if !model.verdict.isEmpty {
                Text(model.verdict)
                    .font(.headline)
                    .foregroundStyle(model.verdict.contains("CÓ Ô THẮNG") ? Color.green : Color.red)
            }
            Text("Bề mặt trang cho P20-1/P20-3 (trang watch bản máy tính trong phiên cửa):")
                .font(.footnote).foregroundStyle(.secondary)
            ProbeWebView(controller: model.pageController,
                         navigationMode: .doorRoam,
                         playbackPresses: false)
                .frame(height: 170)
                .background(Color.black)
            Text("Bề mặt WebView cho P20-5 (mint BotGuard recipe TV):")
                .font(.footnote).foregroundStyle(.secondary)
            ProbeWebView(controller: model.mintController,
                         navigationMode: .doorRoam,
                         playbackPresses: false)
                .frame(height: 120)
                .background(Color.black)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Button(model.running ? "Đang chạy…" : "Chạy lại Probe 20") {
                model.rerun()
            }
            .disabled(model.running)
        }
        .padding(28)
        .onExitCommand { onExit() }
        .task { model.start() }
        .fullScreenCover(isPresented: $doorPresented, onDismiss: { model.doorDismissed() }) {
            ProbeDoorView(onExit: { doorPresented = false })
        }
    }
}
