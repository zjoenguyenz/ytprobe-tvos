import SwiftUI
import AVKit

// MARK: - Probe 14 — TVHTML5 "downgraded" (tv_samsung) + OAuth
//
// The #1-ranked alternative from the 2026-11-20 research
// sweep (GOLD-ALTERNATIVES-TEAM-A-APPS-CODE.md §1 +
// GOLD-ALTERNATIVES-TEAM-B-FORUMS.md §2.3 — both teams
// converged on it independently): yt-dlp ships the
// `tv_samsung` persona as its default SIGNED-IN client at
// end of 2026 (logged-in free accounts:
// `web_embedded,tv_samsung,web` — yt-dlp PR #17805), its
// client table carries NO PO-token policy for it (→ not
// required), and the 5.x clientVersion predates the SABR
// forcing that the 7.x TV client (Probe 9) suffers.
// Hypothesis, decidable in ONE cell: the SAME Gold episode
// Probe 9 called with TVHTML5 7.x (playability=OK but
// SABR-only formats) may answer with plain/HLS formats
// when the client block is the downgraded 5.x spec.
//
// CLIENT SPEC — taken at build time from the PRIMARY
// SOURCE, yt-dlp master `INNERTUBE_CLIENTS`
// (yt_dlp/extractor/youtube/_base.py, read 2026-11-20):
//   'tv_samsung': clientName TVHTML5,
//     clientVersion 5.20260707, deviceMake Samsung,
//     deviceModel UKS9800, osName Tizen, osVersion 2.4.0,
//     userAgent "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0)
//       AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0
//       TV Safari/538.1",
//     INNERTUBE_CONTEXT_CLIENT_NAME 7, SUPPORTS_COOKIES,
//     no GVS_PO_TOKEN_POLICY entry (→ default policy,
//     required=false).
// The sibling 'tv_downgraded' entry is the same
// clientName/clientVersion with a Cobalt UA and no device
// fields; this probe runs the tv_samsung entry because
// that is the persona yt-dlp defaults to for signed-in
// accounts (and the Tizen device context is the documented
// bypass for the `tcl` "page needs to be reloaded"
// experiment). NOTHING in the spec is invented: every
// string above is copied from the table.
//
// THE CELL: identity = Probe 9/13's chain, reused as-is
// (the section below is a verbatim copy of Probe 13's
// implementation over the shared Probe9TokenStore —
// Probe 13's own copies are private to its model, and the
// house precedent is per-probe copies: Probe 13 itself
// re-implemented Probe 9's chain the same way; NO identity
// code was changed anywhere). Then ONE /player call for
// the Gold episode with the downgraded spec + the OAuth
// bearer, a Probe 9/13-shaped census, and — if a playable
// URL exists — a REAL playback leg in AVPlayer with a
// sustained check: position samples every 15 s up to
// 150 s, because token/URL deaths at ~30 s are a
// documented pattern (Team B §3.2) and a first-frame-only
// pass would not decide the question this probe exists
// for. Ciphered-only formats are NAMED, not solved — no
// JS sig/n solver is built here (brief). Token VALUES are
// never logged — presence, lengths and expiry only.

@MainActor
final class DowngradedProbeModel: ObservableObject {
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
        DiagLog.write("probe14", message)
        lines.append(message)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }

    private func finish(_ verdictLine: String) {
        verdict = verdictLine
        log("KẾT QUẢ probe14: \(verdictLine)")
        log("Gửi file log về như thường lệ (link ở màn hình chính) — toàn bộ kiểm kê nằm trong log.")
    }

    // MARK: Client spec (yt-dlp master, tv_samsung entry)

    /// The API key is NOT part of the downgraded spec: it
    /// is the TV client's public InnerTube key, taken from
    /// the bundled ladder's TVHTML5 entry exactly the way
    /// Probes 9/13 take it (same key their proven calls
    /// used).
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

    // MARK: Identity — Probe 13's chain, verbatim
    //
    // Stored token → refresh → in-line device-code (with
    // the base-js scrape for client credentials), over the
    // shared Probe9TokenStore. Copied without changes from
    // SabrProbeModel (ProbeSabr.swift); only the log tag
    // differs (this model's log() writes "probe14").

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

    // MARK: /player (Probe 9/13's recipe, downgraded spec)

    /// One /player POST for the Gold episode with the
    /// downgraded client block. The context carries the
    /// yt-dlp tv_samsung fields verbatim: the five keys
    /// Probes 9/13 send (clientName, clientVersion, hl,
    /// gl, userAgent) PLUS this entry's device fields
    /// (deviceMake, deviceModel, osName, osVersion) —
    /// those fields ARE the spec under test, not a second
    /// variable.
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

    // MARK: Playback leg — first frame + sustained check

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

        log("=== PROBE 14 — TVHTML5 DOWNGRADED (tv_samsung) + OAuth ===")
        log("Tập Gold: \(ProbeTargets.goldEp1) · Câu hỏi: client 5.x có trả format thường/HLS thay vì SABR-only như 7.x không?")
        log("client spec (yt-dlp master, INNERTUBE_CLIENTS['tv_samsung']): clientName=TVHTML5 clientVersion=5.20260707 "
            + "deviceMake=Samsung deviceModel=UKS9800 osName=Tizen osVersion=2.4.0 clientNumber=7")
        log("client UA: Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1")

        guard let initialToken = await acquireToken() else {
            finish("DOWNGRADED: KHÔNG KẾT ÁN ĐƯỢC — không lấy được access token (xem các dòng identity ở trên)")
            return
        }

        guard let apiKey = tvAPIKey() else {
            finish("DOWNGRADED: KHÔNG KẾT ÁN ĐƯỢC — không đọc được API key TVHTML5 từ ladder đóng gói")
            return
        }
        let spec = Self.downgradedSpec(apiKey: apiKey)

        // /player, with one refresh retry and one
        // device-code retry on a 401 (Probe 13's pattern).
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
            finish("DOWNGRADED: KHÔNG KẾT ÁN ĐƯỢC — /player HTTP \(player.http) sau mọi lần thử identity")
            return
        }

        // Census — exactly the Probe 9/13 fields.
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
            finish("DOWNGRADED: UNPLAYABLE — \(reason.isEmpty ? playability : reason)")
            return
        }

        // AVC/AAC presence, mapped through Probe 13's
        // format model.
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

        // Playable target selection.
        var playURL: URL?
        var playKind = ""
        if let hls, let hlsURL = URL(string: hls) {
            playURL = hlsURL
            playKind = "HLS"
            log("play: đích = HLS manifest (host \(hlsURL.host ?? "?"))")
        } else if direct > 0 {
            // Best direct AVC: a muxed format wins over
            // an adaptive one (it carries its own audio —
            // a lone adaptive video would play silent),
            // then highest bitrate.
            var chosen: (raw: [String: Any], model: SabrPlayerFormat)?
            // Selection walks the raw arrays directly
            // (indices into `all` = muxed ++ adaptive).
            var bestIndex: Int?
            var bestScore: (Int, Int)?
            for (index, format) in all.enumerated() {
                guard format["url"] is String else { continue }
                let model = mapped[index]
                guard model.isVideo, model.isAvc else { continue }
                let score = (index < muxed.count ? 1 : 0, model.bitrate)
                if bestScore == nil || score > bestScore! {
                    bestScore = score
                    bestIndex = index
                }
            }
            if let bestIndex {
                chosen = (all[bestIndex], mapped[bestIndex])
            } else {
                // No direct AVC at all — try the
                // highest-bitrate direct format anyway;
                // AVPlayer's answer is still decidable.
                var fallbackIndex: Int?
                var fallbackBitrate = -1
                for (index, format) in all.enumerated() {
                    guard format["url"] is String else { continue }
                    let bitrate = mapped[index].bitrate
                    if bitrate > fallbackBitrate {
                        fallbackBitrate = bitrate
                        fallbackIndex = index
                    }
                }
                if let fallbackIndex {
                    chosen = (all[fallbackIndex], mapped[fallbackIndex])
                    log("play: KHÔNG có format direct AVC — thử format direct bitrate cao nhất "
                        + "(itag \(mapped[fallbackIndex].itag)); AVPlayer có nhận hay không vẫn là kết quả kết án được")
                }
            }
            if let chosen, let urlString = chosen.raw["url"] as? String,
               let url = URL(string: urlString) {
                playURL = url
                playKind = "direct"
                log("play: đích = direct format itag \(chosen.model.itag) \"\(chosen.model.mimeType)\" "
                    + "\(chosen.model.width)x\(chosen.model.height) bitrate \(chosen.model.bitrate) (host \(url.host ?? "?"))")
            }
        }

        guard let playURL, !playKind.isEmpty else {
            if sabr {
                finish("DOWNGRADED: SABR-ONLY — như 7.x")
            } else if ciphered > 0 {
                finish("DOWNGRADED: CHỈ CIPHERED — playability OK nhưng format cần JS sig/n")
            } else {
                finish("DOWNGRADED: KHÔNG KẾT ÁN ĐƯỢC — playability OK nhưng streamingData không có HLS/format nào dùng được (formats=\(all.count))")
            }
            return
        }

        let result = await playAndMeasure(url: playURL, kind: playKind)
        if let death = result.death {
            finish("DOWNGRADED: CHẾT KHI PHÁT — first-frame \(result.firstFrameMs)ms, chết ở \(result.survivedSeconds)s (\(death))")
        } else {
            finish("DOWNGRADED: ĐẠT — \(playKind) formats, phát bền \(result.survivedSeconds)s, first-frame \(result.firstFrameMs)ms")
        }
    }
}

// MARK: - View

struct DowngradedProbeView: View {
    var onExit: () -> Void
    @StateObject private var model = DowngradedProbeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Probe 14 — TVHTML5 downgraded + OAuth")
                .font(.title3).bold()
            Text("Cùng chân danh tính OAuth của Probe 9 (mất token thì tự chạy lại cửa device-code tại đây), nhưng /player cho tập Gold dùng client TVHTML5 bản 5.x 'downgraded' (persona tv_samsung của yt-dlp — client mặc định cho tài khoản đã đăng nhập, không cần PO token). Nếu có format phát được, trình phát native tự mở và phát bền tới 150 giây (lấy mẫu vị trí mỗi 15s) — cứ để nó chạy hết.")
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
                    .foregroundStyle(model.verdict.hasPrefix("DOWNGRADED: ĐẠT") ? Color.green : Color.red)
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
            Button(model.running ? "Đang chạy…" : "Chạy lại Probe 14") {
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
