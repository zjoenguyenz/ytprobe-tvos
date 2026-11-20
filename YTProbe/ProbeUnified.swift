import SwiftUI
import AVKit
import JavaScriptCore

// MARK: - Probe 17 — the UNIFIED route against Free + Super VIP
//
// Probe 16 (device log 2026-11-20 15:42–15:45 CST)
// proved the Gold route end-to-end on the owner's TV:
// device-code OAuth + the downgraded tv_samsung client
// + the vendored EJS solver in JavaScriptCore →
// deciphered 137/140 pass real byte-checks, muxed 18
// plays sustained 148 s, first frame 921 ms. The owner
// then ruled (2026-11-20 15:47 CST): ONE route for
// every tier — "bỏ đường free đi… khỏi rắc rối" — and
// he is upgrading the account to Super VIP. The
// separate signed-out VISIONOS Free spine is dropped
// from the integration design IF this probe passes.
//
// THE TWO UNTESTED CELLS this probe settles, in ONE
// run under ONE device-code approval:
//   Cell A · FREE — Bằng Chứng Thép II ep 1
//     (ProbeTargets.freeEp1, proven Free in Probes
//     3+7) through the authenticated route. The route
//     has only ever been run against a Gold episode;
//     whether it also serves a Free episode is open.
//   Cell B · SUPER VIP — Cuộc Chiến Hoa Hồng ep 1
//     (catalogue tier "vip", pid PLXOEtXRMZ-3Y) through
//     the same route. If /player answers UNPLAYABLE,
//     the reason is logged VERBATIM and the cell ends
//     "CHƯA MỞ" — that means the account upgrade has
//     not landed yet, a clean decidable result, NOT a
//     route failure. If OK, the full flow runs.
//
// THE FLOW per cell is Probe 16's, unchanged: census →
// runtime player JS (tv-player-ias first, embed
// fallback; the FL-335 marker gate — a file without
// "signatureCipher" is the wrong file and is rejected)
// → EJS solver in a bare JSContext → decipher the best
// AVC + best AAC + the muxed format → Range byte-check
// on the AVC/AAC pair → real AVPlayer playback of the
// muxed format (first frame + samples every 15 s × 4
// = 60 s; stall = 2 consecutive non-advancing samples,
// Probe 16's like-with-like readback — FL-330).
// The solver runs FRESH for each cell (its own
// challenges); the player hash is logged per cell so
// the log shows whether both cells solved against the
// same player generation. Cells run strictly in
// sequence and the summary verdict prints only after
// both have finished (FL-330 rules 4–5).
//
// Per-probe copy precedent: the identity chain, player
// JS acquisition, solver harness, cipher handling and
// playback leg are copied from EjsProbeModel (Probe
// 16) without behavioural changes; Probe 16's own code
// is untouched. Stream URLs and token VALUES are never
// logged (counts/lengths only).

@MainActor
final class UnifiedProbeModel: ObservableObject {
    @Published var lines: [String] = []
    @Published var verdict = ""
    @Published var running = false
    @Published var userCode: String?
    @Published var showPlayer = false
    let verificationURL = "https://www.google.com/device"
    private var started = false
    private(set) var activePlayer: AVPlayer?
    private var currentToken = ""
    private var cellPrefix = ""
    private var seenPlayerHash: String?

    // Super VIP target — first series of tier "vip" in
    // ~/workspace/tv-build/tvb-yt.json (41 series), its
    // first episode. Title in the log is fine; no
    // credentials anywhere near this probe.
    private static let svipSeriesTitle = "Cuộc Chiến Hoa Hồng"
    private static let svipPlaylist = "PLXOEtXRMZ-3Y"
    private static let svipEp1 = "A9gDlGV4CP4"

    func start() {
        guard !started else { return }
        started = true
        Task { await run() }
    }

    func rerun() {
        guard !running else { return }
        Task { await run() }
    }

    private func log(_ message: String) {
        DiagLog.write("probe17", cellPrefix + message)
        lines.append(cellPrefix + message)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }

    private func finishSummary(free: String, svip: String) {
        let summary = "FREE=\(free) · SVIP=\(svip)"
        verdict = summary
        log("KẾT QUẢ probe17: \(summary)")
        log("Gửi file log về như thường lệ (link ở màn hình chính) — toàn bộ kiểm kê nằm trong log.")
    }

    // MARK: Client spec — Probe 16's, verbatim

    private func tvAPIKey() -> String? {
        let clients = (try? JSONDecoder().decode(
            [ProbeClientSpec].self,
            from: Data(ProbeClientLadder.bundledJSON.utf8))) ?? []
        return clients.first(where: { $0.name == "TVHTML5" })?.apiKey
    }

    private static func downgradedSpec(apiKey: String?) -> ProbeClientSpec {
        ProbeClientSpec(
            name: "TV_SAMSUNG",
            clientName: "TVHTML5",
            clientVersion: "5.20260707",
            clientNumber: "7",
            userAgent: "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
            apiKey: apiKey,
            deviceMake: "Samsung",
            deviceModel: "UKS9800",
            osName: "Tizen",
            osVersion: "2.4.0",
            androidSdkVersion: nil)
    }

    // MARK: Identity — Probe 16's chain, verbatim
    //
    // Stored token → refresh → in-line device-code (with
    // the base-js scrape for client credentials), over
    // the shared Probe9TokenStore. ONE approval covers
    // both cells: the token is acquired once, before
    // cell A, and cell B reuses it (the per-cell
    // /player helper refreshes/re-runs device-code on a
    // 401 exactly like Probe 16's run did).

    private func acquireToken() async -> String? {
        let stored = Probe9TokenStore.accessToken
        if let stored, let expiry = Probe9TokenStore.accessTokenExpiry,
           expiry > Date().addingTimeInterval(120) {
            log("identity: NHÁNH token-đã-lưu — access token còn hạn tới \(Self.timeLabel(expiry)) (len \(stored.count))")
            return stored
        }
        if let stored, Probe9TokenStore.accessTokenExpiry == nil {
            log("identity: NHÁNH token-đã-lưu — token đời Probe 9 không có mốc hết hạn (len \(stored.count)); dùng luôn, nếu /player trả 401 sẽ refresh/device-code")
            return stored
        }
        if stored != nil {
            log("identity: access token đã lưu ĐÃ HẾT HẠN — thử refresh")
        } else {
            log("identity: KHÔNG có access token trong máy (sandbox đã bị xoá từ sau Probe 9)")
        }
        if Probe9TokenStore.refreshToken != nil {
            let outcome = await Probe9TokenStore.refresh()
            log("identity: \(outcome.note)")
            if let token = outcome.token {
                log("identity: NHÁNH refresh — dùng access token mới")
                return token
            }
        }
        log("identity: NHÁNH device-code — chạy lại cửa đăng nhập của Probe 9 ngay trong probe này")
        return await deviceCodeFlow()
    }

    private func deviceCodeFlow() async -> String? {
        var clientID = Probe9TokenStore.clientID
        var clientSecret = Probe9TokenStore.clientSecret
        if clientID == nil || clientSecret == nil {
            log("device-code: chưa có clientId/secret — cạo base-js từ youtube.com/tv…")
            if let scraped = await scrapeTVClientCredentials() {
                Probe9TokenStore.saveClientCredentials(id: scraped.id, secret: scraped.secret)
                clientID = scraped.id
                clientSecret = scraped.secret
                log("device-code: cạo OK — clientId len \(scraped.id.count), secret len \(scraped.secret.count) (không ghi giá trị)")
            } else {
                log("device-code: cạo base-js THẤT BẠI — không lấy được clientId/secret")
                return nil
            }
        }
        guard let cid = clientID, let secret = clientSecret else { return nil }
        log("device-code: dùng clientId/secret (id len \(cid.count), secret len \(secret.count))")

        let device = await formJSONPost(
            "https://oauth2.googleapis.com/device/code",
            fields: ["client_id": cid,
                     "scope": "https://www.googleapis.com/auth/youtube"])
        guard device.http == 200, let deviceJSON = device.json,
              let deviceCode = deviceJSON["device_code"] as? String,
              let code = deviceJSON["user_code"] as? String else {
            log("device-code: POST device/code HTTP \(device.http) — không lấy được mã kích hoạt")
            return nil
        }
        var waitSeconds = max(5, (deviceJSON["interval"] as? NSNumber)?.intValue ?? 5)
        let expiresIn = (deviceJSON["expires_in"] as? NSNumber)?.intValue ?? 1800
        userCode = code
        log("device-code: MÃ KÍCH HOẠT hiện trên màn hình TV — mở \(verificationURL) trên iPhone, nhập mã, duyệt bằng tài khoản Gold")
        log("device-code: đang chờ duyệt, tối đa \(expiresIn)s…")

        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(waitSeconds) * 1_000_000_000)
            let poll = await formJSONPost(
                "https://oauth2.googleapis.com/token",
                fields: ["client_id": cid,
                         "client_secret": secret,
                         "device_code": deviceCode,
                         "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            if poll.http == 200, let pollJSON = poll.json,
               let access = pollJSON["access_token"] as? String {
                let refresh = pollJSON["refresh_token"] as? String
                let expires = (pollJSON["expires_in"] as? NSNumber)?.intValue
                Probe9TokenStore.saveTokens(access: access, refresh: refresh, expiresIn: expires)
                let refreshNote = refresh.map { "CÓ (len \($0.count))" } ?? "KHÔNG"
                let expiresNote = expires.map { "\($0)" } ?? "?"
                log("device-code: DUYỆT OK — access token len \(access.count), refresh token \(refreshNote), expires_in \(expiresNote)s")
                userCode = nil
                return access
            }
            let error = (poll.json?["error"] as? String) ?? "http_\(poll.http)"
            switch error {
            case "authorization_pending":
                log("device-code: chưa duyệt (authorization_pending) — vẫn chờ…")
            case "slow_down":
                waitSeconds += 5
                log("device-code: slow_down — giãn nhịp chờ thành \(waitSeconds)s")
            default:
                log("device-code: DỪNG — lỗi \(error)")
                userCode = nil
                return nil
            }
        }
        log("device-code: HẾT THỜI GIAN chờ duyệt (\(expiresIn)s)")
        userCode = nil
        return nil
    }

    /// Probe 9's proven scrape: youtube.com/tv with the
    /// Tizen TV UA → `id="base-js"` script → base.js →
    /// clientId + the field right after it (the secret).
    /// Falls back to pattern-matching the /tv HTML itself.
    private func scrapeTVClientCredentials() async -> (id: String, secret: String)? {
        let tvUA = "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.5) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/5.0 Chrome/85.0.4183.120 TV Safari/537.36"
        guard let tvHTML = await fetchText("https://www.youtube.com/tv", userAgent: tvUA) else {
            return nil
        }
        if let src = firstRegexCapture(in: tvHTML, pattern: "id=\"base-js\" src=\"([^\"]+)\"") {
            let jsURL = src.hasPrefix("http") ? src : "https://www.youtube.com" + src
            if let js = await fetchText(jsURL, userAgent: tvUA),
               let credentials = findClientCredentials(in: js) {
                return credentials
            }
        }
        return findClientCredentials(in: tvHTML)
    }

    private func findClientCredentials(in text: String) -> (id: String, secret: String)? {
        if let id = firstRegexCapture(in: text, pattern: "clientId:\"([-\\w]+\\.apps\\.googleusercontent\\.com)\""),
           let secret = firstRegexCapture(in: text, pattern: "clientId:\"[-\\w]+\\.apps\\.googleusercontent\\.com\",\n?[$\\w]+:\"(\\w+)\"") {
            return (id, secret)
        }
        if let id = firstRegexCapture(in: text, pattern: "([-\\w]+\\.apps\\.googleusercontent\\.com)"),
           let secret = firstRegexCapture(in: text, pattern: "client_secret\"?\\s*:\\s*\"(\\w+)\"") {
            return (id, secret)
        }
        return nil
    }

    private func firstRegexCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[capture])
    }

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

    private func formJSONPost(_ urlString: String,
                              fields: [String: String]) async -> (http: Int, json: [String: Any]?) {
        guard let url = URL(string: urlString) else { return (0, nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)"
        }.joined(separator: "&").utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (http, json)
        } catch {
            return (0, nil)
        }
    }

    static func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm dd/MM"
        return formatter.string(from: date)
    }

    // MARK: /player — Probe 16's call, parameterized by videoId

    private func callPlayer(token: String, spec: ProbeClientSpec,
                            videoId: String) async -> (http: Int, json: [String: Any]?, ms: Int) {
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
        if let deviceMake = spec.deviceMake { clientContext["deviceMake"] = deviceMake }
        if let deviceModel = spec.deviceModel { clientContext["deviceModel"] = deviceModel }
        if let osName = spec.osName { clientContext["osName"] = osName }
        if let osVersion = spec.osVersion { clientContext["osVersion"] = osVersion }
        let body: [String: Any] = [
            "videoId": videoId,
            "context": ["client": clientContext],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(spec.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(spec.clientNumber, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(spec.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
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

    /// Probe 16's retry pattern, per cell: one refresh
    /// retry and one device-code retry on a 401; the
    /// working token is kept in `currentToken` so the
    /// next cell starts from it.
    private func playerWithRetry(videoId: String,
                                 spec: ProbeClientSpec) async -> (http: Int, json: [String: Any]?, ms: Int) {
        var result = await callPlayer(token: currentToken, spec: spec, videoId: videoId)
        if result.http == 401 {
            log("player: HTTP 401 — thử refresh 1 lần")
            let outcome = await Probe9TokenStore.refresh()
            log("identity: \(outcome.note)")
            if let refreshed = outcome.token {
                currentToken = refreshed
                result = await callPlayer(token: currentToken, spec: spec, videoId: videoId)
            }
            if result.http == 401 {
                log("player: vẫn 401 — chạy lại device-code 1 lần")
                if let fresh = await deviceCodeFlow() {
                    currentToken = fresh
                    result = await callPlayer(token: currentToken, spec: spec, videoId: videoId)
                }
            }
        }
        return result
    }

    // MARK: Regex helpers

    private func regexCapture(in text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > group,
              let capture = Range(match.range(at: group), in: text) else { return nil }
        return String(text[capture])
    }

    // MARK: Player JS acquisition — Probe 16's, verbatim
    //
    // The FL-335 gate: a JS file is only accepted as THE
    // player if it carries the decipher machinery's
    // marker ("signatureCipher"). Source + size + marker
    // count are logged for every candidate, so one log
    // separates "wrong file" from "wrong method".

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

    /// The player build hash out of a /s/player/<hash>/…
    /// path — a public build identifier (never a
    /// credential), logged so the two cells' solver runs
    /// can be compared by player generation.
    private static func playerHash(fromPath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(of: "player"), index + 1 < parts.count {
            return parts[index + 1]
        }
        return nil
    }

    // MARK: EJS solver (vendored yt-dlp-ejs 0.8.0) — Probe 16's harness, verbatim
    //
    // Bundled resources (same artifacts as Probe 16):
    //   yt.solver.lib.min.js  — 151,561 B (meriyah 6.1.4
    //     + astring 1.9.0, upstream minified build)
    //   yt.solver.core.min.js — 6,945 B (the solver)
    // Driven exactly as upstream's driver (yt-dlp
    // master ejs.py `_construct_stdin`): eval lib →
    // Object.assign(globalThis, lib) → eval core → call
    // jsc(input); values cross as JSValues, results come
    // back as a JSON string. Everything runs inside ONE
    // detached task; failures are captured as named
    // steps — never a crash, never a hang.

    private struct UnifiedSolveOutcome: Sendable {
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

    private enum UnifiedSolver {

        static func solve(player: String, sigChallenges: [String],
                          nChallenges: [String]) -> UnifiedSolveOutcome {
            var outcome = UnifiedSolveOutcome()
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
                                         kind: String, into outcome: inout UnifiedSolveOutcome) {
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

        private static func setError(_ outcome: inout UnifiedSolveOutcome,
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
                                  nChallenges: [String]) async -> UnifiedSolveOutcome {
        let playerText = playerJS.text
        let source = playerJS.source
        let outcome = await Task.detached(priority: .userInitiated) { () -> UnifiedSolveOutcome in
            UnifiedSolver.solve(player: playerText, sigChallenges: sigChallenges,
                                nChallenges: nChallenges)
        }.value
        log("solver: lần thử với nguồn \(source) xong sau \(outcome.elapsedMs)ms")
        for note in outcome.notes { log(note) }
        return outcome
    }

    // MARK: Cipher handling — Probe 16's, verbatim

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

    // MARK: Apply — Probe 16's assembly, fed by the solver's maps

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

    // MARK: Byte check — Probe 16's, verbatim

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

    // MARK: Playback leg — Probe 16's, with the sample count as a parameter
    //
    // First frame (Probe 3+7's definition) + position
    // samples every 15 s; Probe 17 runs 4 samples (60 s
    // window) per its spec. The readback compares the
    // SAME quantities before/after on the SAME player
    // (position + timeControlStatus) — FL-330 rule 1.

    private func playAndMeasure(url: URL, kind: String, samples: Int) async
        -> (firstFrameMs: Int, survivedSeconds: Int, death: String?) {
        let player = AVPlayer(url: url)
        activePlayer = player
        showPlayer = true
        let t0 = Date()
        player.play()
        log("play: bắt đầu phát (\(kind)) — chờ khung hình đầu (deadline 25s)")

        var firstFrameMs = -1
        var startPosition = 0.0
        let frameDeadline = Date().addingTimeInterval(25)
        while Date() < frameDeadline {
            if let item = player.currentItem, item.status == .failed {
                let error = item.error?.localizedDescription ?? "item failed (không có error text)"
                showPlayer = false
                player.pause()
                return (-1, 0, "item FAILED trước khung hình đầu — \(error)")
            }
            if player.timeControlStatus == .playing,
               let item = player.currentItem, item.status == .readyToPlay {
                firstFrameMs = Int(Date().timeIntervalSince(t0) * 1000)
                let position = player.currentTime().seconds
                startPosition = position.isFinite ? position : 0
                break
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        guard firstFrameMs >= 0 else {
            let statusNote = "timeControlStatus=\(player.timeControlStatus.rawValue) "
                + "itemStatus=\(player.currentItem?.status.rawValue ?? -1)"
            showPlayer = false
            player.pause()
            return (-1, 0, "không có khung hình đầu sau 25s (\(statusNote))")
        }
        log("play: FIRST FRAME sau \(firstFrameMs) ms — bắt đầu kiểm bền: mẫu mỗi 15s, tối đa \(samples * 15)s")

        var lastPosition = startPosition
        var survived = 0
        var stalledSamples = 0
        for sample in 1...samples {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if let item = player.currentItem, item.status == .failed {
                let error = item.error?.localizedDescription ?? "item failed (không có error text)"
                let rawNow = player.currentTime().seconds
                if rawNow.isFinite {
                    survived = max(survived, Int(rawNow - startPosition))
                }
                showPlayer = false
                player.pause()
                return (firstFrameMs, survived, "item FAILED ở mẫu \(sample) — \(error)")
            }
            let rawPosition = player.currentTime().seconds
            let position = rawPosition.isFinite ? rawPosition : lastPosition
            survived = max(0, Int(position - startPosition))
            let advancing = position - lastPosition >= 0.5
            if !advancing && player.timeControlStatus != .playing {
                stalledSamples += 1
            } else {
                stalledSamples = 0
            }
            log("play: mẫu \(sample)/\(samples) — t=\(String(format: "%.1f", position))s "
                + "(đã bền \(survived)s) timeControlStatus=\(player.timeControlStatus.rawValue) "
                + "rate=\(String(format: "%.2f", player.rate))")
            lastPosition = position
            if stalledSamples >= 2 {
                showPlayer = false
                player.pause()
                return (firstFrameMs, survived,
                        "phát đứng — t không nhích qua 2 mẫu liên tiếp (30s), kẹt ở \(Int(position))s")
            }
        }
        showPlayer = false
        player.pause()
        return (firstFrameMs, survived, nil)
    }

    // MARK: Solver outcome interpretation — Probe 16's, verbatim

    private func solverFailure(_ outcome: UnifiedSolveOutcome,
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

    /// The short token for the summary line = the part
    /// of a solver verdict before its " — " detail.
    private func summaryToken(forSolverVerdict verdict: String) -> String {
        if let range = verdict.range(of: " — ") {
            return String(verdict[..<range.lowerBound])
        }
        return verdict
    }

    // MARK: One cell

    private struct CellResult {
        var token: String
        var detail: String
    }

    /// Probe 16's full flow against ONE episode.
    /// `detail` is the complete cell verdict sentence
    /// (it starts with the same words as `token`).
    private func runCell(videoId: String, spec: ProbeClientSpec,
                         isSuperVIP: Bool) async -> CellResult {
        let player = await playerWithRetry(videoId: videoId, spec: spec)
        guard player.http == 200, let json = player.json else {
            return CellResult(token: "KHÔNG KẾT ÁN ĐƯỢC",
                              detail: "KHÔNG KẾT ÁN ĐƯỢC — /player HTTP \(player.http) sau mọi lần thử identity")
        }

        // Census — exactly the Probe 9/13/14/15/16 fields.
        let playability = (json["playabilityStatus"] as? [String: Any])?["status"] as? String ?? "?"
        let reason = (json["playabilityStatus"] as? [String: Any])?["reason"] as? String ?? ""
        let streaming = json["streamingData"] as? [String: Any]
        let muxed = streaming?["formats"] as? [[String: Any]] ?? []
        let adaptive = streaming?["adaptiveFormats"] as? [[String: Any]] ?? []
        let all = muxed + adaptive
        var direct = 0
        var ciphered = 0
        for format in all {
            if format["url"] is String { direct += 1 }
            if format["signatureCipher"] is String { ciphered += 1 }
        }
        let sabr = streaming?["serverAbrStreamingUrl"] != nil
        let hls = streaming?["hlsManifestUrl"] as? String
        log("player: HTTP \(player.http) \(player.ms)ms playability=\(playability) reason=\(reason.isEmpty ? "-" : reason) "
            + "hlsManifest=\(hls != nil ? "YES" : "no") formats=\(all.count) "
            + "directURL=\(direct) ciphered=\(ciphered) serverAbr(SABR)=\(sabr ? "YES" : "no")")

        guard playability == "OK" else {
            if isSuperVIP {
                // The decidable not-yet outcome: the
                // account upgrade has not landed. The
                // reason was logged verbatim in the
                // census line above; it is repeated in
                // the cell verdict so the verdict stands
                // on its own.
                let reasonText = reason.isEmpty ? "playability=\(playability), không có reason" : reason
                return CellResult(token: "CHƯA MỞ",
                                  detail: "CHƯA MỞ — \(reasonText)")
            }
            return CellResult(token: "KHÔNG PHÁT ĐƯỢC",
                              detail: "KHÔNG PHÁT ĐƯỢC — playability=\(playability)\(reason.isEmpty ? "" : " — \(reason)")")
        }

        // Format census through Probe 13's model.
        let mapped: [SabrPlayerFormat] = all.map { raw in
            let lastModified: UInt64
            if let string = raw["lastModified"] as? String {
                lastModified = UInt64(string) ?? 0
            } else if let number = raw["lastModified"] as? NSNumber {
                lastModified = number.uint64Value
            } else {
                lastModified = 0
            }
            return SabrPlayerFormat(
                itag: (raw["itag"] as? NSNumber)?.intValue ?? 0,
                mimeType: raw["mimeType"] as? String ?? "",
                bitrate: (raw["bitrate"] as? NSNumber)?.intValue ?? 0,
                width: (raw["width"] as? NSNumber)?.intValue ?? 0,
                height: (raw["height"] as? NSNumber)?.intValue ?? 0,
                lastModified: lastModified,
                xtags: raw["xtags"] as? String ?? "")
        }
        let avcCount = mapped.filter { $0.isVideo && $0.isAvc }.count
        let aacCount = mapped.filter { $0.isAudio && $0.isAac }.count
        log("player: adaptiveFormats=\(adaptive.count) · muxed=\(muxed.count) · AVC(avc1) video = \(avcCount) · AAC(mp4a) audio = \(aacCount)")
        for (index, format) in all.enumerated() {
            let model = mapped[index]
            let dims = model.isVideo ? " \(model.width)x\(model.height)" : ""
            let urlNote = format["url"] is String ? "url=CÓ" : "url=không"
            let cipherNote = format["signatureCipher"] is String ? " ciphered=CÓ" : ""
            log("player: fmt itag \(model.itag) \"\(model.mimeType)\"\(dims) bitrate \(model.bitrate) \(urlNote)\(cipherNote)")
        }
        if let hls {
            log("player: response có HLS manifest (host \(URL(string: hls)?.host ?? "?")) — ghi nhận, nhưng câu hỏi của probe này là đường giải mã nên vẫn đi tiếp")
        }

        // Targets: the BEST AVC video + the BEST AAC
        // audio (byte-check pair) + the best muxed
        // format (playback leg). "Best" = highest
        // bitrate, height breaks a video tie.
        let avcIndex = mapped.indices.filter { mapped[$0].isVideo && mapped[$0].isAvc }
            .max { a, b in
                mapped[a].bitrate != mapped[b].bitrate
                    ? mapped[a].bitrate < mapped[b].bitrate
                    : mapped[a].height < mapped[b].height
            }
        let aacIndex = mapped.indices.filter { mapped[$0].isAudio && mapped[$0].isAac }
            .max { a, b in mapped[a].bitrate < mapped[b].bitrate }
        let muxedIndex = muxed.indices
            .max { a, b in mapped[a].bitrate < mapped[b].bitrate }
        guard let avcIndex, let aacIndex else {
            return CellResult(token: "KHÔNG KẾT ÁN ĐƯỢC",
                              detail: "KHÔNG KẾT ÁN ĐƯỢC — census thiếu format AVC hoặc AAC (AVC=\(avcCount), AAC=\(aacCount))")
        }
        let avcItag = mapped[avcIndex].itag
        let aacItag = mapped[aacIndex].itag
        log("player: chọn byte-check — AVC itag \(avcItag) (\(mapped[avcIndex].width)x\(mapped[avcIndex].height), bitrate \(mapped[avcIndex].bitrate)) · AAC itag \(aacItag) (bitrate \(mapped[aacIndex].bitrate))")
        var targets: [(itag: Int, raw: [String: Any])] = [(avcItag, all[avcIndex]), (aacItag, all[aacIndex])]
        var muxedItag: Int?
        if let muxedIndex {
            muxedItag = mapped[muxedIndex].itag
            targets.append((mapped[muxedIndex].itag, all[muxedIndex]))
            log("player: chọn phát thử — muxed itag \(mapped[muxedIndex].itag) (\(mapped[muxedIndex].width)x\(mapped[muxedIndex].height), bitrate \(mapped[muxedIndex].bitrate))")
        } else {
            log("player: census KHÔNG có format muxed — chân phát thử sẽ không chạy được (byte-check vẫn chạy)")
        }

        // What does this response actually need?
        var needsSig = false
        var needsN = false
        for entry in targets {
            if let plain = entry.raw["url"] as? String {
                log("sign: itag \(entry.itag) có URL trần (direct) — bỏ qua decipher cho format này")
                if nParameter(in: plain) != nil { needsN = true }
            } else if let cipher = entry.raw["signatureCipher"] as? String {
                needsSig = true
                if let parts = parseCipher(cipher), nParameter(in: parts.url) != nil { needsN = true }
            }
        }
        log("sign: nhu cầu từ response này — decipher sig: \(needsSig ? "CÓ" : "không") · transform n: \(needsN ? "CÓ" : "không")")

        var sigResults: [String: String]?
        var nResults: [String: String]?
        if needsSig || needsN {
            var sigChallenges: [String] = []
            var nChallenges: [String] = []
            for entry in targets {
                if let cipher = entry.raw["signatureCipher"] as? String,
                   let parts = parseCipher(cipher) {
                    if needsSig, !sigChallenges.contains(parts.s) {
                        sigChallenges.append(parts.s)
                    }
                    if let nParam = nParameter(in: parts.url),
                       !nChallenges.contains(nParam.value) {
                        nChallenges.append(nParam.value)
                    }
                } else if let plain = entry.raw["url"] as? String,
                          let nParam = nParameter(in: plain),
                          !nChallenges.contains(nParam.value) {
                    nChallenges.append(nParam.value)
                }
            }
            log("solver: challenges từ response này — sig ×\(sigChallenges.count), n ×\(nChallenges.count) (chỉ đếm, không ghi giá trị)")

            guard let playerJS = await acquirePlayerJS(videoId: videoId) else {
                return CellResult(token: "KHÔNG LẤY ĐƯỢC PLAYER JS",
                                  detail: "KHÔNG LẤY ĐƯỢC PLAYER JS — cả nguồn tv-player-ias lẫn embed đều hỏng hoặc sai file (xem các dòng player-js ở trên)")
            }
            log("player-js: dùng nguồn \(playerJS.source) — host \(playerJS.host), path \(playerJS.path), \(playerJS.text.utf8.count) bytes, marker ×\(playerJS.markerCount)")
            if let hash = Self.playerHash(fromPath: playerJS.path) {
                if let seen = seenPlayerHash {
                    log("player-js: hash \(hash) — \(hash == seen ? "TRÙNG với hash của cell trước" : "KHÁC hash của cell trước (\(seen))")")
                } else {
                    log("player-js: hash \(hash)")
                }
                seenPlayerHash = hash
            }
            log("solver: cell này chạy solver RIÊNG cho challenges của nó — không dùng lại kết quả nhận diện của cell trước (mỗi cell một lượt solver đầy đủ)")

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
                    return CellResult(token: summaryToken(forSolverVerdict: finalVerdict),
                                      detail: finalVerdict)
                }
            }
            sigResults = attempt.sigResults
            nResults = attempt.nResults
        }

        // Solve every target.
        var solved: [Int: URL] = [:]
        for entry in targets {
            let outcome = applySolved(itag: entry.itag,
                                      rawURL: entry.raw["url"] as? String,
                                      cipher: entry.raw["signatureCipher"] as? String,
                                      sigResults: sigResults, nResults: nResults)
            switch outcome {
            case .solved(let url):
                solved[entry.itag] = url
            case .failed(let why):
                return CellResult(token: "KHÔNG KẾT ÁN ĐƯỢC",
                                  detail: "KHÔNG KẾT ÁN ĐƯỢC — \(why)")
            }
        }

        // Proof 1: byte-check on the deciphered pair.
        for itag in [avcItag, aacItag] {
            guard let url = solved[itag] else {
                return CellResult(token: "KHÔNG KẾT ÁN ĐƯỢC",
                                  detail: "KHÔNG KẾT ÁN ĐƯỢC — itag \(itag) không có URL sau giải mã")
            }
            let check = await byteCheck(url: url, userAgent: spec.userAgent)
            log("byte-check: itag \(itag) — HTTP \(check.status), nhận \(check.bytes) bytes")
            if check.status == 0 {
                return CellResult(token: "KHÔNG KẾT ÁN ĐƯỢC",
                                  detail: "KHÔNG KẾT ÁN ĐƯỢC — byte-check itag \(itag) lỗi mạng, không có HTTP response")
            }
            guard check.status == 200 || check.status == 206, check.bytes > 0 else {
                return CellResult(token: "BYTE-CHECK BỊ TỪ CHỐI",
                                  detail: "BYTE-CHECK BỊ TỪ CHỐI — itag \(itag) HTTP \(check.status)")
            }
        }
        log("byte-check: itag \(avcItag) + \(aacItag) đều OK")

        // Proof 2: real playback of the deciphered muxed format.
        guard let muxedItag, let urlMuxed = solved[muxedItag] else {
            return CellResult(token: "KHÔNG KẾT ÁN ĐƯỢC",
                              detail: "KHÔNG KẾT ÁN ĐƯỢC — byte-check OK nhưng không có format muxed đã giải mã để phát thử (xem dòng census ở trên)")
        }
        let result = await playAndMeasure(url: urlMuxed,
                                          kind: "itag \(muxedItag) muxed, URL đã giải mã bằng EJS solver",
                                          samples: 4)
        if let death = result.death {
            log("play: đường phát chết — \(death)")
            return CellResult(token: "PHÁT CHẾT",
                              detail: "PHÁT CHẾT — giải được mà phát chết: first-frame \(result.firstFrameMs)ms, chết ở \(result.survivedSeconds)s — \(death)")
        }
        return CellResult(token: "ĐẠT",
                          detail: "ĐẠT — giải mã OK, byte-check \(avcItag)/\(aacItag) OK, phát bền \(result.survivedSeconds)s (first-frame \(result.firstFrameMs)ms)")
    }

    // MARK: The run

    private func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        lines = []
        verdict = ""
        userCode = nil
        seenPlayerHash = nil
        cellPrefix = ""

        log("=== PROBE 17 — ĐƯỜNG CHUNG (device-code OAuth + tv_samsung + EJS solver) CHO FREE + SUPER VIP ===")
        log("Câu hỏi: đúng MỘT đường đã chứng minh ở Probe 16 (tập Gold) có phục vụ được cả tập Free lẫn tập Super VIP không — để Joe TV chỉ cần một đường duy nhất?")
        log("Cell A · FREE: Bằng Chứng Thép II tập 1 · videoId \(ProbeTargets.freeEp1) (đã chứng minh Free ở Probe 3+7)")
        log("Cell B · SUPER VIP: \(Self.svipSeriesTitle) tập 1 · videoId \(Self.svipEp1) · series tier \"vip\" trong catalogue tvb-yt.json (pid \(Self.svipPlaylist), kênh TVB_Vietnam)")
        log("solver: yt-dlp-ejs 0.8.0 vendored (lib = meriyah 6.1.4 + astring 1.9.0; core = solver) — giao thức nạp/khớp đúng bản yt-dlp master")
        log("client spec (yt-dlp master, INNERTUBE_CLIENTS['tv_samsung']): clientName=TVHTML5 clientVersion=5.20260707 "
            + "deviceMake=Samsung deviceModel=UKS9800 osName=Tizen osVersion=2.4.0 clientNumber=7")
        log("client UA: Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1")

        guard let apiKey = tvAPIKey() else {
            log("KHÔNG đọc được API key TVHTML5 từ ladder đóng gói — cả hai cell đều không chạy được")
            finishSummary(free: "KHÔNG KẾT ÁN ĐƯỢC", svip: "KHÔNG KẾT ÁN ĐƯỢC")
            return
        }
        let spec = Self.downgradedSpec(apiKey: apiKey)

        guard let token = await acquireToken() else {
            log("identity: KHÔNG lấy được access token — cả hai cell đều không chạy được (xem các dòng identity ở trên)")
            finishSummary(free: "KHÔNG KẾT ÁN ĐƯỢC", svip: "KHÔNG KẾT ÁN ĐƯỢC")
            return
        }
        currentToken = token

        cellPrefix = "cellA · "
        log("—— CELL A · FREE · Bằng Chứng Thép II tập 1 · videoId \(ProbeTargets.freeEp1) ——")
        let free = await runCell(videoId: ProbeTargets.freeEp1, spec: spec, isSuperVIP: false)
        log("KẾT QUẢ cell A (FREE): \(free.detail)")
        cellPrefix = ""

        cellPrefix = "cellB · "
        log("—— CELL B · SUPER VIP · \(Self.svipSeriesTitle) tập 1 · videoId \(Self.svipEp1) ——")
        let svip = await runCell(videoId: Self.svipEp1, spec: spec, isSuperVIP: true)
        log("KẾT QUẢ cell B (SUPER VIP): \(svip.detail)")
        cellPrefix = ""

        finishSummary(free: free.token, svip: svip.token)
    }
}

// MARK: - View

struct UnifiedProbeView: View {
    var onExit: () -> Void
    @StateObject private var model = UnifiedProbeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Probe 17 — Đường chung: Free + Super VIP")
                .font(.title3).bold()
            Text("Một đường duy nhất của Probe 16 (device-code + client TVHTML5 5.x + solver EJS) chạy cho HAI tập chưa từng thử qua nó: tập Free (Bằng Chứng Thép II 1) và tập Super VIP (Cuộc Chiến Hoa Hồng 1). Mở probe là nó TỰ CHẠY: hiện MÃ KÍCH HOẠT một lần (duyệt ở google.com/device bằng tài khoản của anh — một lần duyệt cho cả hai cell), xong nó tự chạy cell A rồi cell B: giải mã, kiểm byte thật, phát thử bản muxed bền 60 giây mỗi cell. Tập Super VIP mà tài khoản chưa lên hạng thì cell B kết \"CHƯA MỞ\" kèm lý do nguyên văn — đó là kết quả đọc được, không phải lỗi. Màn hình chỉ có chữ cho tới lúc phát thử là đúng. Kết luận nằm ở dòng \"KẾT QUẢ probe17\" cuối log.")
                .font(.footnote).foregroundStyle(.secondary)
            if let code = model.userCode {
                VStack(spacing: 8) {
                    Text("MÃ KÍCH HOẠT")
                        .font(.headline)
                    Text(code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                    Text("Mở \(model.verificationURL) trên iPhone → nhập mã này → duyệt bằng tài khoản của anh. Xong là probe tự chạy tiếp cả hai cell, không cần bấm gì thêm trên TV.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.yellow.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if !model.verdict.isEmpty {
                Text(model.verdict)
                    .font(.headline)
                    .foregroundStyle(model.verdict.contains("FREE=ĐẠT")
                                      && (model.verdict.contains("SVIP=ĐẠT") || model.verdict.contains("SVIP=CHƯA MỞ"))
                                      ? Color.green : Color.red)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Button(model.running ? "Đang chạy…" : "Chạy lại Probe 17") {
                model.rerun()
            }
            .disabled(model.running)
        }
        .padding(28)
        .onExitCommand { onExit() }
        .task { model.start() }
        .fullScreenCover(isPresented: $model.showPlayer) {
            if let player = model.activePlayer {
                NativePlayerView(player: player)
                    .ignoresSafeArea()
            }
        }
    }
}
