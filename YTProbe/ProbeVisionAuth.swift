import SwiftUI
import AVKit
import JavaScriptCore

// MARK: - Probe 18 — VISIONOS + OAuth: does another client lift the 480p cap?
//
// FL-351 (device logs diag_9/diag_11, 2026-11-20): the
// production route (device-code OAuth + the downgraded
// tv_samsung client + the vendored EJS solver) plays,
// but its format census is capped PER SERIES — Nhân
// Chứng and Mất Dấu 2 top out at itag 135 (480p) while
// Mười Hai Truyền Thuyết and Mất Dấu 3 receive the full
// 137 (1080p) census through the very same client. The
// app picks the best it is offered; the question is
// whether ANOTHER client, carrying the owner's identity,
// is offered more for the capped titles.
//
// Design: JOETV-2045-ROUND-DESIGN.md §6.2 (leg 4). The
// one candidate left standing is VISIONOS: signed OUT it
// already won Free WITH an HLS manifest (Probes 3+7:
// status OK, hls=YES, 28 formats, first frame 1199 ms),
// but nobody has ever run VISIONOS + OAuth bearer.
// Probe 12's warning is on record: web-session COOKIES
// (SAPISID) pushed VISIONOS to LOGIN_REQUIRED — a cookie
// is not a bearer header; the bearer variant is the
// unmeasured cell this probe exists to measure.
//
// FIVE CELLS (design table, run in order):
//   P18-1 · tv_samsung + OAuth bearer · L1JzJVZA6WU
//           (baseline — must reproduce the capped census)
//   P18-2 · VISIONOS  + OAuth bearer · L1JzJVZA6WU
//   P18-3 · VISIONOS  + anonymous    · L1JzJVZA6WU
//   P18-4 · VISIONOS  + OAuth bearer · f-ZSFRsMW_4
//           (control: Probe 16's Gold title, tv_samsung
//           gave it 137 — is VISIONOS at least as rich?)
//   P18-5 · VISIONOS  + anonymous    · f-ZSFRsMW_4
//           (rights control: UNPLAYABLE expected — this
//           cell separates "capped by client" from
//           "capped by entitlement")
//
// MANDATORY OUTPUTS per cell (design §6.2 — a cell
// missing one has no verdict): playability + reason
// VERBATIM · hlsManifestUrl present? · FULL census
// (every itag) · highest AVC itag · ciphered count ·
// if ciphered: solver first, byte-check after ·
// byte-check at the highest AVC itag (Range 0–1023 →
// expect 206 + the full 1024 bytes) · if HLS: rendition
// ladder (heights in the manifest) + a first-frame try
// with AVPlayer on the manifest URL (ms to first frame
// + the rendition height the player picked) · /player
// time (ms) · the cell's identity variant. The summary
// verdict (incl. the §6.3 decision-tree read) prints
// ONLY after all five cells have finished (FL-330).
//
// The anonymous cells follow ProbeExtract's proven
// recipe (ephemeral session, no cookies): the
// visitorData retry is part of that recipe — Probes 3+7
// only won AFTER the retry with the fresh visitorData
// from the refusal's responseContext. visitorData is a
// public response-context value, not a credential and
// not a cookie; its value is never logged.
//
// Per-probe copy precedent: the identity chain, player
// JS acquisition, solver harness, cipher handling and
// byte-check are copied from UnifiedProbeModel (Probe
// 17) without behavioural changes; Probes 16/17 are
// untouched. Stream URLs and token VALUES are never
// logged (counts/lengths only).

@MainActor
final class VisionAuthProbeModel: ObservableObject {
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

    // The two targets (design §6.2).
    private static let cappedVid = "L1JzJVZA6WU"   // Mất Dấu 2 tập 1 — census capped at 135
    private static let controlVid = "f-ZSFRsMW_4"  // Probe 16's Gold ep — tv_samsung gave 137

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
        DiagLog.write("P18", cellPrefix + message)
        lines.append(cellPrefix + message)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }

    // MARK: Client specs

    private func ladderClients() -> [ProbeClientSpec] {
        (try? JSONDecoder().decode(
            [ProbeClientSpec].self,
            from: Data(ProbeClientLadder.bundledJSON.utf8))) ?? []
    }

    private func tvAPIKey() -> String? {
        ladderClients().first(where: { $0.name == "TVHTML5" })?.apiKey
    }

    private func visionSpec() -> ProbeClientSpec? {
        ladderClients().first(where: { $0.name == "VISIONOS" })
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

    // MARK: Identity — Probe 17's chain, verbatim
    //
    // Stored token → refresh → in-line device-code (with
    // the base-js scrape for client credentials), over
    // the shared Probe9TokenStore. ONE approval covers
    // every OAuth cell.

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

    // MARK: /player — tv_samsung OAuth (Probe 17's call, verbatim)

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

    /// Probe 17's retry pattern: one refresh retry and
    /// one device-code retry on a 401; the working token
    /// is kept in `currentToken` for the next cell.
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

    // MARK: /player — VISIONOS (ProbeExtract's proven shape)
    //
    // Context + headers follow ProbeResolver.postPlayer
    // (the recipe that won in Probes 3+7): ephemeral
    // session (no cookies), Origin/Referer youtube.com,
    // X-YouTube-Client-Name/Version from the spec,
    // visitorData in the context AND as X-Goog-Visitor-Id
    // when one is in play. The spec carries no apiKey —
    // the ladder's VISIONOS entry runs keyless, so the
    // URL gets no &key=. `token` non-nil adds the OAuth
    // bearer header (the P18-2/P18-4 variant — the cell
    // this probe exists to measure).

    private let visionSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private func callPlayerVision(token: String?, spec: ProbeClientSpec, videoId: String,
                                  visitorData: String?) async -> (http: Int, json: [String: Any]?, ms: Int) {
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
        if let visitorData { clientContext["visitorData"] = visitorData }
        let body: [String: Any] = [
            "videoId": videoId,
            "context": ["client": clientContext],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        var urlString = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
        if let key = spec.apiKey { urlString += "&key=\(key)" }
        guard let url = URL(string: urlString) else { return (0, nil, 0) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(spec.clientNumber, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(spec.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(spec.userAgent, forHTTPHeaderField: "User-Agent")
        if let visitorData {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let t0 = Date()
        do {
            let (data, response) = try await visionSession.data(for: request)
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (http, json, ms)
        } catch {
            log("player: lỗi mạng — \(error.localizedDescription)")
            return (0, nil, Int(Date().timeIntervalSince(t0) * 1000))
        }
    }

    /// VISIONOS + OAuth with Probe 17's 401 discipline
    /// (refresh once, device-code once).
    private func visionOAuthWithRetry(videoId: String,
                                      spec: ProbeClientSpec) async -> (http: Int, json: [String: Any]?, ms: Int) {
        var result = await callPlayerVision(token: currentToken, spec: spec,
                                            videoId: videoId, visitorData: nil)
        if result.http == 401 {
            log("player: HTTP 401 — thử refresh 1 lần")
            let outcome = await Probe9TokenStore.refresh()
            log("identity: \(outcome.note)")
            if let refreshed = outcome.token {
                currentToken = refreshed
                result = await callPlayerVision(token: currentToken, spec: spec,
                                                videoId: videoId, visitorData: nil)
            }
            if result.http == 401 {
                log("player: vẫn 401 — chạy lại device-code 1 lần")
                if let fresh = await deviceCodeFlow() {
                    currentToken = fresh
                    result = await callPlayerVision(token: currentToken, spec: spec,
                                                    videoId: videoId, visitorData: nil)
                }
            }
        }
        return result
    }

    /// VISIONOS anonymous with the proven visitorData
    /// retry (Probes 3+7): first attempt reuses the
    /// stored visitorData if one exists; a refusal whose
    /// responseContext carries a FRESH visitorData is
    /// retried once with it (the fresh value is saved
    /// back, exactly like ProbeResolver). Returns the
    /// final response + the total /player time across
    /// attempts + how many attempts ran.
    private func visionAnonWithRetry(videoId: String,
                                     spec: ProbeClientSpec) async -> (http: Int, json: [String: Any]?, ms: Int, attempts: Int) {
        var visitorData = UserDefaults.standard.string(forKey: "probe.visitorData")
        if visitorData != nil {
            log("player: ẩn danh — dùng visitorData ĐÃ LƯU (recipe Probe 3+7)")
        }
        var totalMs = 0
        var attempt = 0
        while attempt < 2 {
            attempt += 1
            let result = await callPlayerVision(token: nil, spec: spec,
                                                videoId: videoId, visitorData: visitorData)
            totalMs += result.ms
            let status = (result.json?["playabilityStatus"] as? [String: Any])?["status"] as? String
            if status == "OK" || attempt == 2 {
                return (result.http, result.json, totalMs, attempt)
            }
            guard let context = result.json?["responseContext"] as? [String: Any],
                  let fresh = context["visitorData"] as? String, fresh != visitorData else {
                return (result.http, result.json, totalMs, attempt)
            }
            visitorData = fresh
            UserDefaults.standard.set(fresh, forKey: "probe.visitorData")
            log("player: ẩn danh — bị từ chối (\(status ?? "?")) — thử lại với visitorData MỚI từ responseContext (recipe Probe 3+7, đã lưu)")
        }
        return (0, nil, totalMs, attempt)
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

    // MARK: One cell's facts (feeds the §6.3 tree read)

    private struct CellFacts {
        var token = "KHÔNG KẾT ÁN ĐƯỢC"
        var detail = ""
        var ok = false
        var hasHLS = false
        var hlsMaxHeight = 0
        var bestAvcItag = 0
        var bestAvcHeight = 0
        var byteOK = false
        var firstFrameMs = -1
    }

    /// Everything after a /player response lands: the
    /// mandatory §6.2 outputs + the two proof legs (HLS
    /// first frame, cipher/direct byte-check). `spec` is
    /// the cell's own client spec (its UA rides the
    /// byte-check + manifest fetch).
    private func processResponse(json: [String: Any], http: Int, ms: Int,
                                 spec: ProbeClientSpec, videoId: String) async -> CellFacts {
        var facts = CellFacts()
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
        log("player: HTTP \(http) \(ms)ms playability=\(playability) reason=\(reason.isEmpty ? "-" : reason) "
            + "hlsManifest=\(hls != nil ? "YES" : "no") formats=\(all.count) "
            + "directURL=\(direct) ciphered=\(ciphered) serverAbr(SABR)=\(sabr ? "YES" : "no")")

        guard playability == "OK" else {
            facts.token = "UNPLAYABLE"
            facts.detail = "UNPLAYABLE — playability=\(playability)\(reason.isEmpty ? "" : " — \(reason)")"
            return facts
        }
        facts.ok = true

        // FULL census — every format line + the sorted
        // itag array on one line (the §6.1 comparison
        // shape).
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
        let census = mapped.map { $0.itag }.sorted()
        log("player: census đầy đủ (\(all.count) format) = \(census)")
        for (index, format) in all.enumerated() {
            let model = mapped[index]
            let dims = model.isVideo ? " \(model.width)x\(model.height)" : ""
            let urlNote = format["url"] is String ? "url=CÓ" : "url=không"
            let cipherNote = format["signatureCipher"] is String ? " ciphered=CÓ" : ""
            log("player: fmt itag \(model.itag) \"\(model.mimeType)\"\(dims) bitrate \(model.bitrate) \(urlNote)\(cipherNote)")
        }

        // Highest AVC = the byte-check target (§6.2):
        // height first, bitrate breaks the tie.
        let avcIndex = mapped.indices.filter { mapped[$0].isVideo && mapped[$0].isAvc }
            .max { a, b in
                mapped[a].height != mapped[b].height
                    ? mapped[a].height < mapped[b].height
                    : mapped[a].bitrate < mapped[b].bitrate
            }
        if let avcIndex {
            facts.bestAvcItag = mapped[avcIndex].itag
            facts.bestAvcHeight = mapped[avcIndex].height
            log("player: AVC cao nhất — itag \(facts.bestAvcItag) (\(mapped[avcIndex].width)x\(mapped[avcIndex].height), bitrate \(mapped[avcIndex].bitrate))")
        } else {
            log("player: census KHÔNG có format AVC nào")
        }

        // Proof leg 1 — HLS: rendition ladder + a real
        // first-frame try on the manifest URL.
        if let hls, let hlsURL = URL(string: hls) {
            facts.hasHLS = true
            log("hls: manifest có mặt (host \(hlsURL.host ?? "?")) — đọc thang rendition…")
            let ladder = await fetchLadder(url: hlsURL, userAgent: spec.userAgent)
            if ladder.isEmpty {
                log("hls: manifest tải về nhưng KHÔNG parse được rendition nào (hoặc tải lỗi)")
            } else {
                let heights = ladder.map { $0.height }.sorted(by: >)
                facts.hlsMaxHeight = heights.first ?? 0
                log("hls: thang rendition — \(ladder.count) mức, heights (cao→thấp) = \(heights)")
            }
            let frame = await playHLSFirstFrame(url: hlsURL)
            if let death = frame.death {
                log("hls: thử first frame CHẾT — \(death)")
                facts.token = "PHÁT CHẾT"
                facts.detail = "PHÁT CHẾT — có HLS (max \(facts.hlsMaxHeight)p) nhưng AVPlayer không lên được khung hình đầu: \(death)"
                return facts
            }
            facts.firstFrameMs = frame.ms
            log("hls: FIRST FRAME sau \(frame.ms) ms — rendition player chọn: height \(frame.chosenHeight.map { "\($0)p" } ?? "chưa đọc được")")
        }

        // Proof leg 2 — the highest AVC format must
        // deliver real bytes (solver first when the
        // format is ciphered or carries an n parameter).
        guard let avcIndex else {
            facts.token = "KHÔNG KẾT ÁN ĐƯỢC"
            facts.detail = "KHÔNG KẾT ÁN ĐƯỢC — playability OK nhưng census không có AVC để byte-check"
            return facts
        }
        let raw = all[avcIndex]
        let byteOutcome = await byteCheckTarget(itag: facts.bestAvcItag, raw: raw,
                                                spec: spec, videoId: videoId)
        switch byteOutcome {
        case .ok(let status, let bytes):
            facts.byteOK = true
            log("byte-check: itag \(facts.bestAvcItag) — HTTP \(status), nhận \(bytes) bytes — \(status == 206 ? "đúng kỳ vọng 206" : "server trả \(status) thay vì 206 nhưng byte vẫn chảy đủ")")
        case .failed(let why):
            if facts.hasHLS, facts.firstFrameMs >= 0 {
                // The HLS leg already proved playback;
                // the byte-check failure is recorded but
                // the cell's headline stands on the HLS
                // proof (the design's branch A reads HLS).
                log("byte-check: itag \(facts.bestAvcItag) KHÔNG qua — \(why) (ô vẫn có bằng chứng HLS first frame ở trên)")
            } else {
                facts.token = why.token
                facts.detail = why.detail
                return facts
            }
        }

        // Cell verdict from the facts.
        let hdViaHLS = facts.hasHLS && facts.hlsMaxHeight > 480 && facts.firstFrameMs >= 0
        let hdViaAvc = facts.bestAvcHeight > 480 && facts.byteOK
        if hdViaHLS {
            facts.token = "ĐẠT-HD"
            facts.detail = "ĐẠT-HD — HLS có mức \(facts.hlsMaxHeight)p, first frame \(facts.firstFrameMs)ms; AVC cao nhất itag \(facts.bestAvcItag) \(facts.bestAvcHeight)p, byte-check \(facts.byteOK ? "OK" : "không qua (xem log)")"
        } else if hdViaAvc {
            facts.token = "ĐẠT-HD"
            facts.detail = "ĐẠT-HD — AVC itag \(facts.bestAvcItag) \(facts.bestAvcHeight)p qua byte-check; HLS \(facts.hasHLS ? "max \(facts.hlsMaxHeight)p" : "không có")"
        } else if facts.ok {
            facts.token = "ĐẠT-480"
            facts.detail = "ĐẠT-480 — phát được nhưng không gì trên 480p: AVC cao nhất itag \(facts.bestAvcItag) \(facts.bestAvcHeight)p (byte-check \(facts.byteOK ? "OK" : "không qua")), HLS \(facts.hasHLS ? "max \(facts.hlsMaxHeight)p, first frame \(facts.firstFrameMs)ms" : "không có")"
        }
        return facts
    }

    // MARK: HLS ladder + first frame

    private func fetchLadder(url: URL, userAgent: String) async -> [(height: Int, bandwidth: Int)] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        var ladder: [(height: Int, bandwidth: Int)] = []
        for line in text.components(separatedBy: .newlines) {
            guard line.hasPrefix("#EXT-X-STREAM-INF") else { continue }
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
            ladder.append((height: height, bandwidth: bandwidth))
        }
        return ladder
    }

    /// First frame on an HLS manifest (Probe 3+7's
    /// definition: timeControlStatus == .playing with a
    /// readyToPlay item), then a short settle window to
    /// read the rendition height the player picked
    /// (presentationSize). Deadline 25 s, like the other
    /// probes' playback legs.
    private func playHLSFirstFrame(url: URL) async -> (ms: Int, chosenHeight: Int?, death: String?) {
        let player = AVPlayer(url: url)
        activePlayer = player
        showPlayer = true
        let t0 = Date()
        player.play()
        var firstFrameMs = -1
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if let item = player.currentItem, item.status == .failed {
                let error = item.error?.localizedDescription ?? "item failed (không có error text)"
                showPlayer = false
                player.pause()
                return (-1, nil, "item FAILED trước khung hình đầu — \(error)")
            }
            if player.timeControlStatus == .playing,
               let item = player.currentItem, item.status == .readyToPlay {
                firstFrameMs = Int(Date().timeIntervalSince(t0) * 1000)
                break
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        guard firstFrameMs >= 0 else {
            let statusNote = "timeControlStatus=\(player.timeControlStatus.rawValue) "
                + "itemStatus=\(player.currentItem?.status.rawValue ?? -1)"
            showPlayer = false
            player.pause()
            return (-1, nil, "không có khung hình đầu sau 25s (\(statusNote))")
        }
        var chosenHeight: Int?
        for _ in 0..<10 {
            if let size = player.currentItem?.presentationSize, size.height > 0 {
                chosenHeight = Int(size.height)
                break
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        showPlayer = false
        player.pause()
        return (firstFrameMs, chosenHeight, nil)
    }

    // MARK: Byte-check target (solver when needed)

    private enum ByteOutcome {
        case ok(status: Int, bytes: Int)
        case failed(CellFailure)
    }

    private struct CellFailure {
        var token: String
        var detail: String
    }

    /// Resolve ONE format (the highest AVC) to a real
    /// URL — deciphering through the EJS solver when the
    /// format is ciphered or its URL carries an n
    /// parameter (Probe 17 cell A's lesson: even fully
    /// direct responses still need the n transform) —
    /// then run the Range byte-check on it.
    private func byteCheckTarget(itag: Int, raw: [String: Any],
                                 spec: ProbeClientSpec, videoId: String) async -> ByteOutcome {
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
                return .failed(CellFailure(
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
                    return .failed(CellFailure(token: summaryToken(forSolverVerdict: finalVerdict),
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
            return .failed(CellFailure(token: "KHÔNG KẾT ÁN ĐƯỢC",
                                       detail: "KHÔNG KẾT ÁN ĐƯỢC — \(why)"))
        case .solved(let url):
            let check = await byteCheck(url: url, userAgent: spec.userAgent)
            if check.status == 0 {
                return .failed(CellFailure(
                    token: "KHÔNG KẾT ÁN ĐƯỢC",
                    detail: "KHÔNG KẾT ÁN ĐƯỢC — byte-check itag \(itag) lỗi mạng, không có HTTP response"))
            }
            guard (check.status == 200 || check.status == 206), check.bytes == 1024 else {
                return .failed(CellFailure(
                    token: "BYTE-CHECK BỊ TỪ CHỐI",
                    detail: "BYTE-CHECK BỊ TỪ CHỐI — itag \(itag) HTTP \(check.status), nhận \(check.bytes)/1024 bytes (kỳ vọng 206 + đủ 1024)"))
            }
            return .ok(status: check.status, bytes: check.bytes)
        }
    }

    // MARK: Player JS acquisition — Probe 17's, verbatim
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

    // MARK: EJS solver (vendored yt-dlp-ejs 0.8.0) — Probe 17's harness, verbatim

    private struct VisionSolveOutcome: Sendable {
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

    private enum VisionSolver {

        static func solve(player: String, sigChallenges: [String],
                          nChallenges: [String]) -> VisionSolveOutcome {
            var outcome = VisionSolveOutcome()
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
                                         kind: String, into outcome: inout VisionSolveOutcome) {
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

        private static func setError(_ outcome: inout VisionSolveOutcome,
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
                                  nChallenges: [String]) async -> VisionSolveOutcome {
        let playerText = playerJS.text
        let source = playerJS.source
        let outcome = await Task.detached(priority: .userInitiated) { () -> VisionSolveOutcome in
            VisionSolver.solve(player: playerText, sigChallenges: sigChallenges,
                               nChallenges: nChallenges)
        }.value
        log("solver: lần thử với nguồn \(source) xong sau \(outcome.elapsedMs)ms")
        for note in outcome.notes { log(note) }
        return outcome
    }

    // MARK: Cipher handling — Probe 17's, verbatim

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

    // MARK: Apply — Probe 17's assembly, fed by the solver's maps

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

    // MARK: Byte check — Probe 17's, verbatim

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

    // MARK: Solver outcome interpretation — Probe 17's, verbatim

    private func solverFailure(_ outcome: VisionSolveOutcome,
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

    // MARK: The run — five cells, in the design's order

    private func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        lines = []
        verdict = ""
        userCode = nil
        seenPlayerHash = nil
        cellPrefix = ""

        log("=== PROBE 18 — VISIONOS + OAuth CÓ NÂNG ĐƯỢC TRẦN 480p KHÔNG? (FL-351, thiết kế §6.2) ===")
        log("Tựa bị cap: Mất Dấu 2 tập 1 · videoId \(Self.cappedVid) (census qua tv_samsung chỉ tới itag 135/480p)")
        log("Tựa đối chứng: tập Gold của Probe 16 · videoId \(Self.controlVid) (tv_samsung cấp 137/1080p)")
        log("solver: yt-dlp-ejs 0.8.0 vendored — chỉ chạy khi format bị cipher hoặc mang tham số n")
        guard let vision = visionSpec() else {
            log("KHÔNG đọc được spec VISIONOS từ ladder đóng gói — probe không chạy được")
            verdict = "P18: KHÔNG KẾT ÁN ĐƯỢC (thiếu spec VISIONOS)"
            log("KẾT QUẢ probe18: \(verdict)")
            return
        }
        log("spec VISIONOS (ladder đóng gói): clientName=\(vision.clientName) clientVersion=\(vision.clientVersion) "
            + "clientNumber=\(vision.clientNumber) deviceMake=\(vision.deviceMake ?? "-") deviceModel=\(vision.deviceModel ?? "-") "
            + "osName=\(vision.osName ?? "-") osVersion=\(vision.osVersion ?? "-") apiKey=\(vision.apiKey == nil ? "không có (keyless)" : "có")")
        log("spec VISIONOS UA: \(vision.userAgent)")
        let tvSpec = Self.downgradedSpec(apiKey: tvAPIKey())
        log("spec tv_samsung (baseline): clientName=TVHTML5 clientVersion=5.20260707 clientNumber=7 (persona yt-dlp tv_samsung, như Probe 14/16/17)")

        // Identity once, before the OAuth cells. If it
        // fails, the OAuth cells end KHÔNG KẾT ÁN ĐƯỢC
        // but the anonymous cells still run.
        var identityOK = false
        if let token = await acquireToken() {
            currentToken = token
            identityOK = true
        } else {
            log("identity: KHÔNG lấy được access token — các ô OAuth (P18-1/2/4) sẽ kết KHÔNG KẾT ÁN ĐƯỢC; các ô ẩn danh vẫn chạy")
        }

        // P18-1 · baseline
        cellPrefix = "P18-1 · "
        log("—— P18-1 · BASELINE · tv_samsung + OAuth bearer · vid \(Self.cappedVid) ——")
        log("danh tính của ô: OAuth bearer (device-code của app probe)")
        var f1 = CellFacts()
        if identityOK {
            let r = await playerWithRetry(videoId: Self.cappedVid, spec: tvSpec)
            if r.http == 200, let json = r.json {
                f1 = await processResponse(json: json, http: r.http, ms: r.ms, spec: tvSpec, videoId: Self.cappedVid)
            } else {
                f1.detail = "KHÔNG KẾT ÁN ĐƯỢC — /player HTTP \(r.http) sau mọi lần thử identity"
            }
        } else {
            f1.detail = "KHÔNG KẾT ÁN ĐƯỢC — identity thất bại (xem các dòng identity ở đầu log)"
        }
        log("KẾT QUẢ P18-1: \(f1.detail)")
        cellPrefix = ""

        // P18-2 · VISIONOS + OAuth on the capped title
        cellPrefix = "P18-2 · "
        log("—— P18-2 · VISIONOS + OAuth bearer · vid \(Self.cappedVid) ——")
        log("danh tính của ô: OAuth bearer (cùng token với P18-1) + context/headers recipe VISIONOS của Probe 3")
        var f2 = CellFacts()
        if identityOK {
            let r = await visionOAuthWithRetry(videoId: Self.cappedVid, spec: vision)
            if r.http == 200, let json = r.json {
                f2 = await processResponse(json: json, http: r.http, ms: r.ms, spec: vision, videoId: Self.cappedVid)
            } else {
                f2.detail = "KHÔNG KẾT ÁN ĐƯỢC — /player HTTP \(r.http) sau mọi lần thử identity"
            }
        } else {
            f2.detail = "KHÔNG KẾT ÁN ĐƯỢC — identity thất bại (xem các dòng identity ở đầu log)"
        }
        log("KẾT QUẢ P18-2: \(f2.detail)")
        cellPrefix = ""

        // P18-3 · VISIONOS anonymous on the capped title
        cellPrefix = "P18-3 · "
        log("—— P18-3 · VISIONOS ẨN DANH · vid \(Self.cappedVid) ——")
        log("danh tính của ô: ẩn danh — ephemeral, không cookie, không token; visitorData retry theo recipe Probe 3+7")
        var f3 = CellFacts()
        do {
            let r = await visionAnonWithRetry(videoId: Self.cappedVid, spec: vision)
            log("player: ẩn danh chạy \(r.attempts) attempt, tổng \(r.ms)ms")
            if r.http == 200, let json = r.json {
                f3 = await processResponse(json: json, http: r.http, ms: r.ms, spec: vision, videoId: Self.cappedVid)
            } else {
                f3.detail = "KHÔNG KẾT ÁN ĐƯỢC — /player HTTP \(r.http)"
            }
        }
        log("KẾT QUẢ P18-3: \(f3.detail)")
        cellPrefix = ""

        // P18-4 · VISIONOS + OAuth on the control title
        cellPrefix = "P18-4 · "
        log("—— P18-4 · ĐỐI CHỨNG · VISIONOS + OAuth bearer · vid \(Self.controlVid) ——")
        log("danh tính của ô: OAuth bearer (cùng token)")
        var f4 = CellFacts()
        if identityOK {
            let r = await visionOAuthWithRetry(videoId: Self.controlVid, spec: vision)
            if r.http == 200, let json = r.json {
                f4 = await processResponse(json: json, http: r.http, ms: r.ms, spec: vision, videoId: Self.controlVid)
            } else {
                f4.detail = "KHÔNG KẾT ÁN ĐƯỢC — /player HTTP \(r.http) sau mọi lần thử identity"
            }
        } else {
            f4.detail = "KHÔNG KẾT ÁN ĐƯỢC — identity thất bại (xem các dòng identity ở đầu log)"
        }
        log("KẾT QUẢ P18-4: \(f4.detail)")
        cellPrefix = ""

        // P18-5 · VISIONOS anonymous on the control title
        cellPrefix = "P18-5 · "
        log("—— P18-5 · ĐỐI CHỨNG QUYỀN · VISIONOS ẨN DANH · vid \(Self.controlVid) ——")
        log("danh tính của ô: ẩn danh — kỳ vọng UNPLAYABLE (tập Gold không có quyền ẩn danh); ô này tách 'cap do client' khỏi 'cap do quyền'")
        var f5 = CellFacts()
        do {
            let r = await visionAnonWithRetry(videoId: Self.controlVid, spec: vision)
            log("player: ẩn danh chạy \(r.attempts) attempt, tổng \(r.ms)ms")
            if r.http == 200, let json = r.json {
                f5 = await processResponse(json: json, http: r.http, ms: r.ms, spec: vision, videoId: Self.controlVid)
            } else {
                f5.detail = "KHÔNG KẾT ÁN ĐƯỢC — /player HTTP \(r.http)"
            }
        }
        log("KẾT QUẢ P18-5: \(f5.detail)")
        cellPrefix = ""

        // Summary — ONLY now (FL-330): the five tokens +
        // the mechanical §6.3 decision-tree read.
        let oauthHD = f2.ok && ((f2.hasHLS && f2.hlsMaxHeight > 480 && f2.firstFrameMs >= 0) || f2.bestAvcHeight > 480)
        let anonHD = f3.ok && ((f3.hasHLS && f3.hlsMaxHeight > 480 && f3.firstFrameMs >= 0) || f3.bestAvcHeight > 480)
        let branch: String
        let branchWhy: String
        if f2.ok, f2.hasHLS, f2.hlsMaxHeight > 480, f2.firstFrameMs >= 0 {
            branch = "A"
            branchWhy = "VISIONOS+OAuth trả HLS có mức \(f2.hlsMaxHeight)p và first frame chạy được → thang client VISIONOS+OAuth trước, rơi về tv_samsung khi không HLS/không OK (đường .hlsManifest đã có sẵn trong player)"
        } else if oauthHD {
            branch = "B"
            branchWhy = "VISIONOS+OAuth không HLS-HD nhưng census có AVC \(f2.bestAvcHeight)p (itag \(f2.bestAvcItag)) → resolver chạy hai client, chọn census giàu hơn cho bộ ghép; tầng dưới không đổi"
        } else if anonHD && !oauthHD {
            branch = "C"
            branchWhy = "chỉ ô ẨN DANH thắng HD (VISIONOS+OAuth không hơn baseline) → tựa nào ẩn danh OK đi spine VISIONOS ẩn danh lấy HLS/HD; tựa cần quyền ở lại tv_samsung — quyết theo TỰA lúc resolve, không theo nhãn tier"
        } else {
            branch = "D"
            branchWhy = "không ô nào hơn baseline → trần 480p theo tựa ĐỨNG NGUYÊN vòng này; app phải HIỆN mức chất lượng thật đang phát thay vì để người xem đoán"
        }
        let summary = "P18-1=\(f1.token) · P18-2=\(f2.token) · P18-3=\(f3.token) · P18-4=\(f4.token) · P18-5=\(f5.token)"
        verdict = "\(summary) → NHÁNH \(branch)"
        log("KẾT QUẢ probe18: \(summary)")
        log("CÂY QUYẾT ĐỊNH §6.3: NHÁNH \(branch) — \(branchWhy)")
        log("Đối chứng: P18-4 (VISIONOS+OAuth, tựa 137) = \(f4.token) — AVC cao nhất \(f4.bestAvcItag) \(f4.bestAvcHeight)p, HLS \(f4.hasHLS ? "max \(f4.hlsMaxHeight)p" : "không"); P18-5 (ẩn danh, tựa Gold) = \(f5.token) — kỳ vọng UNPLAYABLE")
        log("Gửi file log về như thường lệ (link ở màn hình chính) — toàn bộ kiểm kê nằm trong log.")
    }
}

// MARK: - View

struct VisionAuthProbeView: View {
    var onExit: () -> Void
    @StateObject private var model = VisionAuthProbeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Probe 18 — VISIONOS + OAuth: nâng trần 480p?")
                .font(.title3).bold()
            Text("Năm ô đo trên hai tựa: tựa BỊ CAP Mất Dấu 2 tập 1 (client hiện tại chỉ cấp tới 480p) và tựa ĐỐI CHỨNG của Probe 16 (được cấp 1080p). Mở probe là nó TỰ CHẠY: nếu cần, hiện MÃ KÍCH HOẠT một lần (duyệt ở google.com/device bằng tài khoản của anh — một lần duyệt cho mọi ô OAuth), xong nó tự chạy lần lượt P18-1 (baseline tv_samsung) → P18-2 (VISIONOS + đăng nhập) → P18-3 (VISIONOS ẩn danh) → P18-4/P18-5 (đối chứng). Ô nào có HLS thì trình phát TỰ MỞ thử khung hình đầu — để nó chạy vài giây, nó tự đóng. Kết luận nằm ở dòng \"KẾT QUẢ probe18\" cuối log, kèm nhánh kiến trúc A/B/C/D.")
                .font(.footnote).foregroundStyle(.secondary)
            if let code = model.userCode {
                VStack(spacing: 8) {
                    Text("MÃ KÍCH HOẠT")
                        .font(.headline)
                    Text(code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                    Text("Mở \(model.verificationURL) trên iPhone → nhập mã này → duyệt bằng tài khoản của anh. Xong là probe tự chạy tiếp cả năm ô, không cần bấm gì thêm trên TV.")
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
                    .foregroundStyle(model.verdict.contains("NHÁNH D") ? Color.red : Color.green)
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
            Button(model.running ? "Đang chạy…" : "Chạy lại Probe 18") {
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
