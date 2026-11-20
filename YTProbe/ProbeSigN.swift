import SwiftUI
import AVKit
import JavaScriptCore

// MARK: - Probe 15 — sig/n decipher for the downgraded client
//
// Probe 14's verdict (device log 2026-11-20 14:49 CST):
// the tv_samsung client (TVHTML5 5.20260707 + the OAuth
// device-code identity) answers playability=OK with NO
// SABR forcing — but all 31 formats are signature-
// ciphered (directURL=0, ciphered=31): each format
// carries a signatureCipher (s + sp + url) whose `s`
// must be run through the player JS's decipher function
// before the URL is usable, and the URL's `n` parameter
// must be run through the player JS's n function or
// googlevideo throttles/refuses the fetch. This is the
// classic yt-dlp problem, and yt-dlp's solution is the
// spec here: locate the two functions IN THE PLAYER'S
// OWN base.js BY PATTERN at runtime (no hardcoded
// function bodies — YouTube rotates them), then execute
// them. Execution here is pure JavaScriptCore
// (JSContext) — no web view.
//
// THE CELL: Probe 14's identity chain + /player call,
// verbatim (per-probe copy, the house precedent — Probe
// 14 itself copied Probe 13's chain the same way), then:
//   1. census (Probe 14's fields) and target selection —
//      itag 137 (1080p AVC), itag 140 (AAC), itag 18
//      (muxed 360p, the AVPlayer-decidable one).
//   2. base.js: a jsUrl in the /player response if it
//      carries one, else the youtube.com/tv base-js
//      scrape the device-code flow already proves.
//   3. Pattern extraction of the sig function (+ its
//      helper object) and the n function, yt-dlp pattern
//      families, each hit/miss logged.
//   4. JSCore execution; per format: decipher `s`,
//      append under the cipher's `sp` name, transform
//      the URL's `n` value in place.
//   5. Proof, two ways: a Range byte-check on the
//      deciphered 137 and 140 URLs, and a REAL playback
//      of the deciphered muxed 18 in AVPlayer with
//      Probe 14's sustained check (samples every 15 s
//      up to 150 s — a first-frame-only pass would not
//      decide the ~30 s death pattern). Assembling the
//      adaptive pair into local HLS is INTEGRATION work,
//      deliberately NOT built here.
// Stream URLs are never logged — host and itag only.
// Token VALUES are never logged — presence/length only.

@MainActor
final class SigNProbeModel: ObservableObject {
    @Published var lines: [String] = []
    @Published var verdict = ""
    @Published var running = false
    @Published var userCode: String?
    @Published var showPlayer = false
    let verificationURL = "https://www.google.com/device"
    private var started = false
    private(set) var activePlayer: AVPlayer?

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
        DiagLog.write("probe15", message)
        lines.append(message)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }

    private func finish(_ verdictLine: String) {
        verdict = verdictLine
        log("KẾT QUẢ probe15: \(verdictLine)")
        log("Gửi file log về như thường lệ (link ở màn hình chính) — toàn bộ kiểm kê nằm trong log.")
    }

    // MARK: Client spec — Probe 14's, verbatim
    //
    // The API key is the TV client's public InnerTube
    // key, taken from the bundled ladder's TVHTML5 entry
    // exactly the way Probes 9/13/14 take it.

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

    // MARK: Identity — Probe 14's chain, verbatim
    //
    // Stored token → refresh → in-line device-code (with
    // the base-js scrape for client credentials), over
    // the shared Probe9TokenStore. Copied without changes
    // from DowngradedProbeModel (ProbeDowngraded.swift);
    // only the log tag differs (this model's log() writes
    // "probe15").

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

    // MARK: /player — Probe 14's call, verbatim

    /// One /player POST for the Gold episode with the
    /// downgraded client block (Probe 14's recipe).
    private func callPlayer(token: String,
                            spec: ProbeClientSpec) async -> (http: Int, json: [String: Any]?, ms: Int) {
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
            "videoId": ProbeTargets.goldEp1,
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

    // MARK: base.js acquisition

    private static let tvScrapeUA = "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.5) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/5.0 Chrome/85.0.4183.120 TV Safari/537.36"

    /// The player JS for THIS run. Source order per the
    /// brief: a jsUrl carried by the /player response
    /// itself, else the youtube.com/tv base-js scrape
    /// (the fetch Probes 9/13/14 prove). Returns the JS
    /// text and its host — the text never enters the log.
    private func acquireBaseJS(playerJSON: [String: Any]) async -> (text: String, host: String, source: String)? {
        if let data = try? JSONSerialization.data(withJSONObject: playerJSON),
           let text = String(data: data, encoding: .utf8),
           let jsURL = regexCapture(in: text, pattern: #""jsUrl"\s*:\s*"([^"]+)""#, group: 1) {
            let cleaned = jsURL.replacingOccurrences(of: "\\/", with: "/")
            let full = cleaned.hasPrefix("http") ? cleaned : "https://www.youtube.com" + cleaned
            if let js = await fetchText(full, userAgent: Self.tvScrapeUA), js.count > 10_000 {
                let host = URL(string: full)?.host ?? "?"
                log("base.js: nguồn = jsUrl trong player response (host \(host), \(js.utf8.count) bytes)")
                return (js, host, "player-jsUrl")
            }
            log("base.js: player response CÓ jsUrl nhưng tải về hỏng/quá ngắn — rơi xuống đường cạo /tv")
        } else {
            log("base.js: player response không có jsUrl — dùng đường cạo youtube.com/tv")
        }
        guard let tvHTML = await fetchText("https://www.youtube.com/tv", userAgent: Self.tvScrapeUA) else {
            log("base.js: tải trang /tv THẤT BẠI")
            return nil
        }
        guard let src = firstRegexCapture(in: tvHTML, pattern: "id=\"base-js\" src=\"([^\"]+)\"") else {
            log("base.js: trang /tv không có thẻ base-js")
            return nil
        }
        let full = src.hasPrefix("http") ? src : "https://www.youtube.com" + src
        guard let js = await fetchText(full, userAgent: Self.tvScrapeUA) else {
            log("base.js: tải file base.js từ thẻ base-js THẤT BẠI")
            return nil
        }
        let host = URL(string: full)?.host ?? "?"
        log("base.js: nguồn = cạo youtube.com/tv (host \(host), \(js.utf8.count) bytes)")
        return (js, host, "tv-scrape")
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

    private func regexAllCaptures(in text: String, pattern: String, group: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var out: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges > group,
                  let capture = Range(match.range(at: group), in: text) else { continue }
            out.append(String(text[capture]))
        }
        return out
    }

    // MARK: Function-name pattern families (yt-dlp)

    private struct NameHit {
        var name: String
        var index: Int?
        var patternLabel: String
    }

    /// yt-dlp `_parse_sig_js` families, in yt-dlp's
    /// order: (label, pattern, capture group of the name).
    private static let sigNamePatterns: [(label: String, pattern: String, group: Int)] = [
        ("S1 c&&d.set(encodeURIComponent(NAME())", #"[cs]\s*&&\s*[adf]\.set\([^,]+\s*,\s*encodeURIComponent\s*\(\s*([a-zA-Z0-9$]+)\("#, 1),
        ("S2 m=NAME(decodeURIComponent(h.s))", #"\bm=([a-zA-Z0-9$]{2,})\(decodeURIComponent\(h\.s\)\)"#, 1),
        ("S3 c&&(c=NAME(decodeURIComponent(c)))", #"\bc&&\(c=([a-zA-Z0-9$]{2,})\(decodeURIComponent\(c\)\)"#, 1),
        ("S4 NAME=function(a){split;XX.yy(a,N)}", #"([a-zA-Z0-9$]{2,})\s*=\s*function\(\s*a\s*\)\s*\{\s*a\s*=\s*a\.split\(\s*""\s*\);\s*[a-zA-Z0-9$]{2}\.[a-zA-Z0-9$]{2}\(a,\d+\)"#, 1),
        ("S5 NAME=function(a){a=a.split()}", #"([a-zA-Z0-9$]{2,})\s*=\s*function\(\s*a\s*\)\s*\{\s*a\s*=\s*a\.split\(\s*""\s*\)"#, 1),
        ("S6 'signature',NAME(", #"["']signature["']\s*,\s*([a-zA-Z0-9$]+)\("#, 1),
        ("S7 .sig||NAME(", #"\.sig\|\|([a-zA-Z0-9$]+)\("#, 1),
        ("S8 x&&y.set(encodeURIComponent(NAME())", #"[a-zA-Z0-9]+\s*&&\s*[a-zA-Z0-9]+\.set\([^,]+\s*,\s*encodeURIComponent\s*\(\s*([a-zA-Z0-9$]+)\("#, 1),
    ]

    /// yt-dlp `_extract_n_function_name` families:
    /// (label, pattern, name group, index group if any).
    private static let nNamePatterns: [(label: String, pattern: String, group: Int, indexGroup: Int?)] = [
        ("N1 .get(n)&&(b=NAME(", #"\.get\("n"\)\)&&\(b=([a-zA-Z_$][\w$]*)\("#, 1, nil),
        ("N2 .get(n)&&(b=NAME[idx](", #"\.get\("n"\)\)&&\(b=([a-zA-Z_$][\w$]*)\[(\d+)\]\("#, 1, 2),
        ("N3 b=String.fromCharCode(110),x=NAME( (heuristic)", #"b=String\.fromCharCode\(110\)\s*,\s*[a-zA-Z_$][\w$]*\s*=\s*([a-zA-Z_$][\w$]*)\("#, 1, nil),
    ]

    private func findSigName(in js: String) -> NameHit? {
        for entry in Self.sigNamePatterns {
            if let name = regexCapture(in: js, pattern: entry.pattern, group: entry.group) {
                return NameHit(name: name, index: nil, patternLabel: entry.label)
            }
        }
        return nil
    }

    private func findNName(in js: String) -> NameHit? {
        for entry in Self.nNamePatterns {
            guard let regex = try? NSRegularExpression(pattern: entry.pattern) else { continue }
            let range = NSRange(js.startIndex..<js.endIndex, in: js)
            guard let match = regex.firstMatch(in: js, range: range),
                  match.numberOfRanges > entry.group,
                  let nameRange = Range(match.range(at: entry.group), in: js) else { continue }
            var index: Int?
            if let indexGroup = entry.indexGroup, match.numberOfRanges > indexGroup,
               let indexRange = Range(match.range(at: indexGroup), in: js) {
                index = Int(js[indexRange])
            }
            return NameHit(name: String(js[nameRange]), index: index, patternLabel: entry.label)
        }
        return nil
    }

    // MARK: Definition extraction (balanced-bracket scan)

    /// The index just past the bracket that closes the
    /// one at `openAt`, stepping over string literals
    /// ('…', "…", `…`) and // + block comments. Regex
    /// literals are NOT understood — a brace inside one
    /// would end the scan early; the consequence is a
    /// JSCore eval error, which the probe logs verbatim
    /// (a decidable outcome, not a crash).
    private func balancedEnd(in text: String, openAt: String.Index,
                             open: Character, close: Character) -> String.Index? {
        var depth = 0
        var index = openAt
        var inSingle = false
        var inDouble = false
        var inTemplate = false
        var inLineComment = false
        var inBlockComment = false
        var escaped = false
        while index < text.endIndex {
            let char = text[index]
            let next = text.index(after: index)
            let peek: Character? = next < text.endIndex ? text[next] : nil
            if inLineComment {
                if char == "\n" { inLineComment = false }
                index = next
                continue
            }
            if inBlockComment {
                if char == "*" && peek == "/" {
                    inBlockComment = false
                    index = text.index(after: next)
                    continue
                }
                index = next
                continue
            }
            if inSingle || inDouble || inTemplate {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if inSingle && char == "'" {
                    inSingle = false
                } else if inDouble && char == "\"" {
                    inDouble = false
                } else if inTemplate && char == "`" {
                    inTemplate = false
                }
                index = next
                continue
            }
            if char == "/" && peek == "/" {
                inLineComment = true
                index = next
                continue
            }
            if char == "/" && peek == "*" {
                inBlockComment = true
                index = next
                continue
            }
            if char == "'" {
                inSingle = true
            } else if char == "\"" {
                inDouble = true
            } else if char == "`" {
                inTemplate = true
            } else if char == open {
                depth += 1
            } else if char == close {
                depth -= 1
                if depth == 0 { return next }
            }
            index = next
        }
        return nil
    }

    /// Find `startPattern`'s first match, then the
    /// balanced extent of the bracket it opens. When
    /// `openIsLastMatchChar` the match itself ends with
    /// the opening bracket (container patterns);
    /// otherwise the opening bracket is the first one at
    /// or after the match end (function patterns — the
    /// match ends at the parameter list's `(` and the
    /// body `{` follows it).
    private func extractBalanced(in js: String, startPattern: String,
                                 open: Character, close: Character,
                                 openIsLastMatchChar: Bool) -> String? {
        guard let regex = try? NSRegularExpression(pattern: startPattern) else { return nil }
        let fullRange = NSRange(js.startIndex..<js.endIndex, in: js)
        guard let match = regex.firstMatch(in: js, range: fullRange),
              let matchRange = Range(match.range, in: js) else { return nil }
        let openIndex: String.Index
        if openIsLastMatchChar {
            openIndex = js.index(before: matchRange.upperBound)
            guard js[openIndex] == open else { return nil }
        } else {
            guard let found = js[matchRange.upperBound...].firstIndex(of: open) else { return nil }
            openIndex = found
        }
        guard let end = balancedEnd(in: js, openAt: openIndex, open: open, close: close) else { return nil }
        return String(js[matchRange.lowerBound..<end])
    }

    /// Extract the full definition text of `name`:
    /// `NAME = function(...){...}`, `function NAME(...)`,
    /// or a container `NAME = [...]` / `NAME = {...}`
    /// (the indexed n-function shape). When the hit
    /// carries an array index the container shapes are
    /// tried first.
    private func extractDefinition(named name: String, in js: String,
                                   preferContainer: Bool) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let boundary = #"(?<![\w$.])"#
        let functionShapes: [String?] = [
            extractBalanced(in: js, startPattern: boundary + escaped + #"\s*=\s*function\s*\("#,
                            open: "{", close: "}", openIsLastMatchChar: false),
            extractBalanced(in: js, startPattern: #"function\s+"# + escaped + #"\s*\("#,
                            open: "{", close: "}", openIsLastMatchChar: false),
        ]
        let containerShapes: [String?] = [
            extractBalanced(in: js, startPattern: boundary + escaped + #"\s*=\s*\["#,
                            open: "[", close: "]", openIsLastMatchChar: true),
            extractBalanced(in: js, startPattern: boundary + escaped + #"\s*=\s*\{"#,
                            open: "{", close: "}", openIsLastMatchChar: true),
        ]
        let ordered = preferContainer ? containerShapes + functionShapes
                                      : functionShapes + containerShapes
        for candidate in ordered {
            if let candidate { return candidate }
        }
        return nil
    }

    /// A helper's definition: an object/array literal
    /// assignment, or a plain function definition.
    private func extractHelperDefinition(named name: String, in js: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let boundary = #"(?<![\w$.])"#
        if let def = extractBalanced(in: js, startPattern: boundary + escaped + #"\s*=\s*\{"#,
                                     open: "{", close: "}", openIsLastMatchChar: true) {
            return def
        }
        if let def = extractBalanced(in: js, startPattern: boundary + escaped + #"\s*=\s*\["#,
                                     open: "[", close: "]", openIsLastMatchChar: true) {
            return def
        }
        return extractDefinition(named: name, in: js, preferContainer: false)
    }

    // MARK: Helper-object discovery

    private static let jsBuiltins: Set<String> = [
        "String", "Number", "Boolean", "Array", "Object", "Math", "JSON",
        "Date", "RegExp", "Error", "TypeError", "RangeError", "SyntaxError",
        "parseInt", "parseFloat", "isNaN", "isFinite", "decodeURIComponent",
        "encodeURIComponent", "decodeURI", "encodeURI", "undefined",
        "NaN", "Infinity", "arguments", "this", "window", "document",
        "navigator", "location", "console", "Promise", "Symbol", "Map",
        "Set", "WeakMap", "Uint8Array", "ArrayBuffer", "globalThis",
        "Reflect", "Proxy", "escape", "unescape",
    ]

    private func declaredNames(in text: String) -> Set<String> {
        var names = Set<String>()
        for name in regexAllCaptures(in: text, pattern: #"\b(?:var|let|const)\s+([A-Za-z_$][\w$]*)"#, group: 1) {
            names.insert(name)
        }
        for name in regexAllCaptures(in: text, pattern: #"function\s+([A-Za-z_$][\w$]*)\s*\("#, group: 1) {
            names.insert(name)
        }
        return names
    }

    private func parameterNames(ofDefinition definition: String) -> Set<String> {
        guard let header = regexCapture(in: definition, pattern: #"function\s*\(([^)]*)\)"#, group: 1) else {
            return []
        }
        var names = Set<String>()
        for part in header.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if let name = regexCapture(in: trimmed, pattern: #"^([A-Za-z_$][\w$]*)"#, group: 1) {
                names.insert(name)
            }
        }
        return names
    }

    /// Identifiers a body USES as `IDENT.` or `IDENT[`
    /// without declaring them — the helper-object shape
    /// (the sig function's operations table above all).
    private func referencedHelpers(inBody body: String, excluding: Set<String>) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for pattern in [#"([A-Za-z_$][\w$]*)\s*\."#, #"([A-Za-z_$][\w$]*)\s*\["#] {
            for name in regexAllCaptures(in: body, pattern: pattern, group: 1) {
                if excluding.contains(name) || Self.jsBuiltins.contains(name) { continue }
                if seen.insert(name).inserted { names.append(name) }
            }
        }
        return names
    }

    private struct ExtractedFunction {
        var name: String
        var index: Int?
        var definition: String
        var helpers: [String]
        var patternLabel: String
    }

    /// Name hit → definition + the helper definitions
    /// its body needs (one recursion level, capped).
    /// nil = name found but no extractable body.
    private func buildExtracted(_ hit: NameHit, in js: String, kind: String) -> ExtractedFunction? {
        guard let definition = extractDefinition(named: hit.name, in: js,
                                                  preferContainer: hit.index != nil) else {
            log("\(kind): thấy tên hàm '\(hit.name)' (pattern \(hit.patternLabel)) nhưng KHÔNG trích được thân hàm từ base.js")
            return nil
        }
        var excluding = declaredNames(in: definition)
        excluding.formUnion(parameterNames(ofDefinition: definition))
        excluding.insert(hit.name)
        var helperTexts: [String] = []
        var helperNames: [String] = []
        var queue = referencedHelpers(inBody: definition, excluding: excluding)
        var steps = 0
        while let helper = queue.first, steps < 8 {
            queue.removeFirst()
            steps += 1
            if helperNames.contains(helper) { continue }
            guard let helperDef = extractHelperDefinition(named: helper, in: js) else {
                log("\(kind): helper '\(helper)' được thân hàm dùng nhưng không tìm thấy định nghĩa của nó — cứ nạp thiếu, để JSCore kết án")
                continue
            }
            helperTexts.append(helperDef)
            helperNames.append(helper)
            var subExcluding = excluding
            subExcluding.formUnion(declaredNames(in: helperDef))
            subExcluding.insert(helper)
            for sub in referencedHelpers(inBody: helperDef, excluding: subExcluding)
            where !helperNames.contains(sub) {
                queue.append(sub)
            }
        }
        let indexNote = hit.index.map { "[\($0)]" } ?? ""
        log("\(kind): trích OK — hàm '\(hit.name)'\(indexNote) (pattern \(hit.patternLabel)), thân \(definition.utf8.count) bytes, helpers: \(helperNames.isEmpty ? "không" : helperNames.joined(separator: ", "))")
        return ExtractedFunction(name: hit.name, index: hit.index,
                                 definition: definition, helpers: helperTexts,
                                 patternLabel: hit.patternLabel)
    }

    // MARK: JavaScriptCore execution

    /// Pure-JSCore execution of the extracted functions.
    /// Values cross via JSValue calls only — nothing is
    /// interpolated into JS source except the
    /// pattern-validated function name and array index.
    private final class SigNEngine {
        private let context: JSContext?

        init() {
            let created: JSContext? = JSContext()
            context = created
        }

        /// Evaluate the assembled definitions. Returns
        /// the exception message verbatim, or nil.
        func load(_ source: String) -> String? {
            guard let context else { return "không tạo được JSContext" }
            _ = context.evaluateScript(source)
            return takeException(from: context)
        }

        func call(name: String, index: Int?, input: String) -> (value: String?, error: String?) {
            guard let context else { return (nil, "không tạo được JSContext") }
            let function: JSValue?
            if let index {
                function = context.evaluateScript("\(name)[\(index)]")
            } else {
                let value = context.objectForKeyedSubscript(name)
                function = (value?.isUndefined == false) ? value : nil
            }
            if let message = takeException(from: context) {
                return (nil, message)
            }
            guard let function, !function.isUndefined, !function.isNull else {
                return (nil, "hàm '\(name)' không tồn tại sau khi nạp")
            }
            let result = function.call(withArguments: [input])
            if let message = takeException(from: context) {
                return (nil, message)
            }
            guard let result, !result.isUndefined, !result.isNull else {
                return (nil, "hàm '\(name)' trả về undefined/null")
            }
            return (result.toString(), nil)
        }

        private func takeException(from context: JSContext) -> String? {
            guard let exception = context.exception, !exception.isUndefined else { return nil }
            context.exception = nil
            return exception.toString() ?? "JS exception (không có text)"
        }
    }

    // MARK: Cipher handling

    private struct CipherParts {
        var s: String
        var sp: String
        var url: String
    }

    /// Parse a signatureCipher ("s=…&sp=…&url=…"),
    /// percent-decoding each field. Manual split on the
    /// RAW string — the values are percent-encoded, so
    /// raw & and = inside them cannot confuse the split.
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

    /// Locate the `n` query parameter in a URL string:
    /// its percent-decoded value + the raw value's range
    /// for in-place replacement.
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

    private enum SolveOutcome {
        case solved(url: URL)
        case evalError(step: String, message: String)
        case failed(why: String)
    }

    /// One format → a playable URL: plain URL as-is,
    /// else decipher `s` and append under `sp`, then
    /// transform the URL's `n` value in place.
    private func solveTarget(itag: Int, rawURL: String?, cipher: String?,
                             engine: SigNEngine?, sig: ExtractedFunction?,
                             nFunc: ExtractedFunction?) -> SolveOutcome {
        var urlString: String
        var deciphered = false
        if let rawURL {
            urlString = rawURL
            log("sign: itag \(itag) — URL trần có sẵn, bỏ qua decipher (ghi nhận theo brief)")
        } else if let cipher {
            guard let parts = parseCipher(cipher) else {
                return .failed(why: "itag \(itag): signatureCipher không parse được (thiếu s hoặc url)")
            }
            guard let engine, let sig else {
                return .failed(why: "itag \(itag): cần decipher nhưng engine/sig chưa sẵn sàng")
            }
            let outcome = engine.call(name: sig.name, index: sig.index, input: parts.s)
            if let error = outcome.error {
                return .evalError(step: "sig(itag \(itag))", message: error)
            }
            guard let sigValue = outcome.value, !sigValue.isEmpty else {
                return .failed(why: "itag \(itag): hàm sig trả chuỗi rỗng")
            }
            urlString = parts.url + "&" + parts.sp + "=" + percentEncodeQueryValue(sigValue)
            deciphered = true
        } else {
            return .failed(why: "itag \(itag): format không có url cũng không có signatureCipher")
        }
        var nNote = "n=không có"
        if let nParam = nParameter(in: urlString) {
            if let engine, let nFunc {
                let outcome = engine.call(name: nFunc.name, index: nFunc.index, input: nParam.value)
                if let error = outcome.error {
                    return .evalError(step: "n(itag \(itag))", message: error)
                }
                guard let newValue = outcome.value, !newValue.isEmpty else {
                    return .failed(why: "itag \(itag): hàm n trả chuỗi rỗng")
                }
                urlString.replaceSubrange(nParam.range, with: percentEncodeQueryValue(newValue))
                nNote = "n=CÓ (len \(nParam.value.count)→\(newValue.count))"
            } else {
                nNote = "n=CÓ nhưng không có hàm n — giữ nguyên giá trị cũ"
            }
        }
        guard let url = URL(string: urlString) else {
            return .failed(why: "itag \(itag): URL sau giải mã không hợp lệ")
        }
        log("sign: itag \(itag) — decipher=\(deciphered ? "OK" : "không cần") · \(nNote) · host \(url.host ?? "?")")
        return .solved(url: url)
    }

    // MARK: Byte check

    /// Range byte-check on a solved URL: ask for the
    /// first 1024 bytes and STOP reading there
    /// (bytes(for:) + break — a server that ignores the
    /// Range header and answers 200 must not stream a
    /// whole episode into the probe). Returns
    /// (status, bytes); status 0 = network error, no
    /// HTTP response at all.
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

    // MARK: Playback leg — Probe 14's, verbatim
    //
    // First frame + sustained check, copied without
    // changes from DowngradedProbeModel.playAndMeasure.

    /// Play the chosen URL in AVPlayer (presented by the
    /// view) and measure: first frame (Probe 3+7's
    /// definition — timeControlStatus .playing with a
    /// ready item), then position samples every 15 s up
    /// to 150 s. Returns the first-frame milliseconds
    /// (-1 = never), the content seconds survived, and
    /// the death cause (nil = survived the full window).
    /// Stream URLs are never logged — host and itag only.
    private func playAndMeasure(url: URL, kind: String) async
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
        log("play: FIRST FRAME sau \(firstFrameMs) ms — bắt đầu kiểm bền: mẫu mỗi 15s, tối đa 150s")

        var lastPosition = startPosition
        var survived = 0
        var stalledSamples = 0
        for sample in 1...10 {
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
            log("play: mẫu \(sample)/10 — t=\(String(format: "%.1f", position))s "
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

    // MARK: The run

    private func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        lines = []
        verdict = ""
        userCode = nil

        log("=== PROBE 15 — GIẢI MÃ SIG/N CHO CLIENT DOWNGRADED (tv_samsung) ===")
        log("Tập Gold: \(ProbeTargets.goldEp1) · Câu hỏi: trích + chạy được hai hàm sig/n của player JS bằng JavaScriptCore trên máy không, và URL giải xong có phát bền không?")
        log("client spec (yt-dlp master, INNERTUBE_CLIENTS['tv_samsung']): clientName=TVHTML5 clientVersion=5.20260707 "
            + "deviceMake=Samsung deviceModel=UKS9800 osName=Tizen osVersion=2.4.0 clientNumber=7")
        log("client UA: Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1")

        guard let initialToken = await acquireToken() else {
            finish("KHÔNG KẾT ÁN ĐƯỢC — không lấy được access token (xem các dòng identity ở trên)")
            return
        }

        guard let apiKey = tvAPIKey() else {
            finish("KHÔNG KẾT ÁN ĐƯỢC — không đọc được API key TVHTML5 từ ladder đóng gói")
            return
        }
        let spec = Self.downgradedSpec(apiKey: apiKey)

        // /player, with one refresh retry and one
        // device-code retry on a 401 (Probe 14's pattern).
        var token = initialToken
        var player = await callPlayer(token: token, spec: spec)
        if player.http == 401 {
            log("player: HTTP 401 — thử refresh 1 lần")
            let outcome = await Probe9TokenStore.refresh()
            log("identity: \(outcome.note)")
            if let refreshed = outcome.token {
                token = refreshed
                player = await callPlayer(token: token, spec: spec)
            }
            if player.http == 401 {
                log("player: vẫn 401 — chạy lại device-code 1 lần")
                if let fresh = await deviceCodeFlow() {
                    token = fresh
                    player = await callPlayer(token: token, spec: spec)
                }
            }
        }
        guard player.http == 200, let json = player.json else {
            finish("KHÔNG KẾT ÁN ĐƯỢC — /player HTTP \(player.http) sau mọi lần thử identity")
            return
        }

        // Census — exactly the Probe 9/13/14 fields.
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
            finish("KHÔNG KẾT ÁN ĐƯỢC — playability=\(playability)\(reason.isEmpty ? "" : " — \(reason)")")
            return
        }

        // AVC/AAC presence, mapped through Probe 13's
        // format model (Probe 14's census block, verbatim).
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
            log("player: response có HLS manifest (host \(URL(string: hls)?.host ?? "?")) — ghi nhận, nhưng câu hỏi của probe này là sig/n nên vẫn đi tiếp đường giải mã")
        }

        // Targets: 137 (1080p AVC) + 140 (AAC) for the
        // byte-check, 18 (muxed) for the playback leg.
        func targetRaw(_ itag: Int, in list: [[String: Any]]) -> [String: Any]? {
            list.first { ($0["itag"] as? NSNumber)?.intValue == itag }
        }
        guard let raw137 = targetRaw(137, in: all), let raw140 = targetRaw(140, in: all) else {
            finish("KHÔNG KẾT ÁN ĐƯỢC — census thiếu itag 137 hoặc 140")
            return
        }
        let raw18 = targetRaw(18, in: muxed)
        if raw18 == nil {
            log("sign: census KHÔNG có itag 18 muxed — chân phát thử sẽ không chạy được (byte-check vẫn chạy)")
        }
        var targets: [(itag: Int, raw: [String: Any])] = [(137, raw137), (140, raw140)]
        if let raw18 { targets.append((18, raw18)) }

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

        var engine: SigNEngine?
        var sigFn: ExtractedFunction?
        var nFn: ExtractedFunction?
        if needsSig || needsN {
            guard let baseJS = await acquireBaseJS(playerJSON: json) else {
                finish("KHÔNG KẾT ÁN ĐƯỢC — không lấy được base.js (cả jsUrl lẫn đường cạo /tv đều hỏng)")
                return
            }
            let js = baseJS.text
            let jsSize = js.utf8.count
            if needsSig {
                guard let hit = findSigName(in: js) else {
                    log("sig: located=NO — mọi pattern family S1–S8 đều miss")
                    finish("KHÔNG TRÍCH ĐƯỢC HÀM — sig (pattern miss trên base.js \(jsSize)B)")
                    return
                }
                log("sig: located=YES — pattern \(hit.patternLabel), tên hàm '\(hit.name)'")
                guard let extracted = buildExtracted(hit, in: js, kind: "sig") else {
                    finish("KHÔNG TRÍCH ĐƯỢC HÀM — sig (pattern miss trên base.js \(jsSize)B)")
                    return
                }
                sigFn = extracted
            }
            if needsN {
                guard let hit = findNName(in: js) else {
                    log("n: located=NO — mọi pattern family N1–N3 đều miss")
                    finish("KHÔNG TRÍCH ĐƯỢC HÀM — n (pattern miss trên base.js \(jsSize)B)")
                    return
                }
                let indexNote = hit.index.map { "[\($0)]" } ?? ""
                log("n: located=YES — pattern \(hit.patternLabel), tên hàm '\(hit.name)'\(indexNote)")
                guard let extracted = buildExtracted(hit, in: js, kind: "n") else {
                    finish("KHÔNG TRÍCH ĐƯỢC HÀM — n (pattern miss trên base.js \(jsSize)B)")
                    return
                }
                nFn = extracted
            }
            let newEngine = SigNEngine()
            var source = ""
            if let sigFn {
                source += sigFn.helpers.joined(separator: "\n") + "\n" + sigFn.definition + "\n"
            }
            if let nFn {
                source += nFn.helpers.joined(separator: "\n") + "\n" + nFn.definition + "\n"
            }
            if let loadError = newEngine.load(source) {
                finish("EVAL LỖI — nạp hàm vào JSCore: \(loadError)")
                return
            }
            log("sign: JSCore nạp hàm OK (nguồn ghép \(source.utf8.count) bytes)")
            engine = newEngine
        }

        // Solve every target.
        var solved: [Int: URL] = [:]
        for entry in targets {
            let outcome = solveTarget(itag: entry.itag,
                                      rawURL: entry.raw["url"] as? String,
                                      cipher: entry.raw["signatureCipher"] as? String,
                                      engine: engine, sig: sigFn, nFunc: nFn)
            switch outcome {
            case .solved(let url):
                solved[entry.itag] = url
            case .evalError(let step, let message):
                finish("EVAL LỖI — \(step): \(message)")
                return
            case .failed(let why):
                finish("KHÔNG KẾT ÁN ĐƯỢC — \(why)")
                return
            }
        }

        // Proof 1: byte-check on the deciphered 137 + 140.
        for itag in [137, 140] {
            guard let url = solved[itag] else {
                finish("KHÔNG KẾT ÁN ĐƯỢC — itag \(itag) không có URL sau giải mã")
                return
            }
            let check = await byteCheck(url: url, userAgent: spec.userAgent)
            log("byte-check: itag \(itag) — HTTP \(check.status), nhận \(check.bytes) bytes")
            if check.status == 0 {
                finish("KHÔNG KẾT ÁN ĐƯỢC — byte-check itag \(itag) lỗi mạng, không có HTTP response")
                return
            }
            guard check.status == 200 || check.status == 206, check.bytes > 0 else {
                finish("BYTE-CHECK BỊ TỪ CHỐI — itag \(itag) HTTP \(check.status)")
                return
            }
        }
        log("byte-check: itag 137 + 140 đều OK")

        // Proof 2: real playback of the deciphered muxed 18.
        guard let url18 = solved[18] else {
            finish("KHÔNG KẾT ÁN ĐƯỢC — không có itag 18 đã giải mã để phát thử (xem dòng census ở trên)")
            return
        }
        let result = await playAndMeasure(url: url18, kind: "itag 18 muxed, URL đã giải mã")
        if let death = result.death {
            log("play: đường phát chết — \(death)")
            finish("GIẢI ĐƯỢC MÀ PHÁT CHẾT — first-frame \(result.firstFrameMs)ms, chết ở \(result.survivedSeconds)s")
        } else {
            finish("SIG/N: ĐẠT — giải mã OK, byte-check 137/140 OK, phát bền \(result.survivedSeconds)s (first-frame \(result.firstFrameMs)ms)")
        }
    }
}

// MARK: - View

struct SigNProbeView: View {
    var onExit: () -> Void
    @StateObject private var model = SigNProbeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Probe 15 — Giải mã sig/n (downgraded)")
                .font(.title3).bold()
            Text("Đi lại đúng đường của Probe 14 (danh tính device-code + /player bằng client TVHTML5 5.x) rồi GIẢI MÃ các format bị khoá chữ ký: trích hai hàm sig/n từ base.js của player bằng pattern kiểu yt-dlp, chạy bằng JavaScriptCore ngay trên TV, giải URL của itag 137/140/18, kiểm byte thật, rồi phát thử bản muxed 18 bền tới 150 giây (lấy mẫu vị trí mỗi 15s) — cứ để nó chạy hết.")
                .font(.footnote).foregroundStyle(.secondary)
            if let code = model.userCode {
                VStack(spacing: 8) {
                    Text("MÃ KÍCH HOẠT")
                        .font(.headline)
                    Text(code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                    Text("Mở \(model.verificationURL) trên iPhone → nhập mã này → duyệt bằng tài khoản Gold. Xong là probe tự chạy tiếp, không cần bấm gì thêm trên TV.")
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
                    .foregroundStyle(model.verdict.hasPrefix("SIG/N: ĐẠT") ? Color.green : Color.red)
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
            Button(model.running ? "Đang chạy…" : "Chạy lại Probe 15") {
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
