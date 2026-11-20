import SwiftUI
import AVKit

// MARK: - Probe 9 — device-code door + TVHTML5/OAuth Gold leg
//
// The strongest Gold backup (Research Team 5): the YouTube
// TV device-code OAuth flow — the TV never renders a Google
// page, so the passkey wall and the page-focus problem do
// not exist on this route. SmartTubeIOS pattern: the TV
// client credentials are SCRAPED at runtime from the
// youtube.com/tv page (no credentials are baked into this
// app), the owner activates the shown code on his phone,
// the probe polls the token endpoint, then calls the
// TVHTML5 /player endpoint for the fixed GOLD episode with
// the OAuth bearer and logs the outcome per leg.
// Tokens and scraped credentials are stored only in the
// probe's own sandbox (UserDefaults) and are NEVER logged —
// presence and lengths only.

@MainActor
final class DeviceCodeModel: ObservableObject {
    @Published var lines: [String] = []
    @Published var userCode: String = ""
    @Published var verdict: String = ""
    @Published var hasToken = false
    private var clientID: String?
    private var clientSecret: String?
    private var deviceCode: String?
    private var pollTask: Task<Void, Never>?
    private var goldHLS: URL?

    func log(_ line: String) {
        DiagLog.write("probe9", line)
        lines.append(line)
        if lines.count > 8 { lines.removeFirst(lines.count - 8) }
    }

    init() {
        hasToken = UserDefaults.standard.string(forKey: "probe9.accessToken") != nil
    }

    // MARK: Step 1 — scrape the TV client credentials

    private static let tvUserAgent =
        "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)"

    /// UA SmartTubeIOS dùng khi xin trang /tv — biến thể
    /// trang phục vụ cho TV Samsung Tizen là biến thể
    /// chứa thẻ script id="base-js".
    private static let tizenUserAgent =
        "Mozilla/5.0 (SMART-TV; Linux; Tizen 5.0) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/2.1 Chrome/56.0.2924.0 TV Safari/537.36"

    /// Run the client_id / client_secret patterns over one
    /// text (the /tv HTML or one JS bundle). Returns what
    /// THIS text held — values stay in the model, the log
    /// only ever sees presence and lengths.
    private func findCredentials(in text: String)
        -> (id: String?, secret: String?, secretLabel: String?) {
        let id = firstMatch(in: text,
                            pattern: "[0-9]+-[a-z0-9]+\\.apps\\.googleusercontent\\.com")
        var secret: String?
        var secretLabel: String?
        for (label, pattern) in [
            ("json", "\"client_secret\"\\s*:\\s*\"([^\"]{8,})\""),
            ("camel", "\"clientSecret\"\\s*:\\s*\"([^\"]{8,})\""),
            ("js", "client_secret=([A-Za-z0-9_\\-]{8,})"),
        ] {
            if let found = firstCapture(in: text, pattern: pattern) {
                secret = found
                secretLabel = label
                break
            }
        }
        return (id, secret, secretLabel)
    }

    /// Script bundle URLs referenced by the /tv HTML,
    /// restricted to youtube/google hosts, de-duplicated,
    /// in document order.
    private func bundleURLs(in html: String) -> [URL] {
        guard let regex = try? NSRegularExpression(
            pattern: "src=[\"']([^\"']+\\.js[^\"']*)[\"']") else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        let allowedHosts = ["youtube.com", "google.com", "gstatic.com",
                            "googleusercontent.com", "youtube-nocookie.com"]
        var urls: [URL] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: html) else { continue }
            var raw = String(html[r])
            if raw.hasPrefix("//") {
                raw = "https:" + raw
            } else if raw.hasPrefix("/") {
                raw = "https://www.youtube.com" + raw
            }
            guard let url = URL(string: raw),
                  let host = url.host,
                  allowedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
                  seen.insert(url.absoluteString).inserted
            else { continue }
            urls.append(url)
        }
        return urls
    }

    /// Second scrape leg: the /tv HTML carries the
    /// client_id but not the secret — the TV app's JS
    /// bundles are the remaining place it can live. Fetch
    /// each bundle (bounded) and run the same patterns.
    /// Returns true once BOTH credentials are held.
    private func scrapeJSBundles(html: String) async -> Bool {
        let all = bundleURLs(in: html)
        let cap = 12
        log("scrape-js: tìm thấy \(all.count) bundle JS (domain youtube/google) trong HTML"
            + (all.count > cap ? " — chỉ cào \(cap) bundle đầu (chạm cap)" : ""))
        for url in all.prefix(cap) {
            var req = URLRequest(url: url)
            req.setValue(Self.tvUserAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                log("scrape-js: bundle \(url.host ?? "?")\(url.path) — tải thất bại")
                continue
            }
            let text = String(decoding: data, as: UTF8.self)
            let found = findCredentials(in: text)
            if let id = found.id, clientID == nil { clientID = id }
            if let secret = found.secret, clientSecret == nil { clientSecret = secret }
            log("scrape-js: bundle \(url.host ?? "?")\(url.path) — \(data.count) bytes — "
                + "id=\(found.id != nil ? "TÌM THẤY (len=\(found.id?.count ?? 0))" : "không") "
                + "secret=\(found.secret != nil ? "TÌM THẤY (len=\(found.secret?.count ?? 0))" : "không")")
            if clientID != nil && clientSecret != nil { return true }
        }
        return clientID != nil && clientSecret != nil
    }

    /// Chân 1 (chính) — công thức SmartTubeIOS nguyên bản:
    /// xin /tv bằng UA Samsung Tizen, tìm thẻ script
    /// id="base-js" (đường dẫn kabuki tương đối), tải
    /// base.js, rồi áp hai pattern của Android
    /// ClientData.java: clientId, và client_secret là
    /// giá trị của field NGAY SAU clientId trong cùng
    /// một object. Mọi bước đều ghi log quyết định được;
    /// giá trị credentials không bao giờ vào log — chỉ
    /// độ dài (path của base-js không phải credential).
    private func scrapeBaseJS() async -> Bool {
        guard let url = URL(string: "https://www.youtube.com/tv") else { return false }
        var req = URLRequest(url: url)
        req.setValue(Self.tizenUserAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            log("scrape-base: tải trang /tv (UA Tizen) thất bại")
            return false
        }
        let html = String(decoding: data, as: UTF8.self)
        log("scrape-base: trang /tv (UA Tizen) tải về \(data.count) bytes")
        guard let src = firstCapture(in: html,
                                     pattern: #"id="base-js" src="([^"]+)""#) else {
            log("scrape-base: KHÔNG tìm thấy thẻ base-js trong HTML")
            return false
        }
        log("scrape-base: base-js TÌM THẤY — path=\(src)")
        guard let jsURL = URL(string: "https://www.youtube.com" + src) else {
            log("scrape-base: path base-js không dựng được URL")
            return false
        }
        var jsReq = URLRequest(url: jsURL)
        jsReq.setValue(Self.tizenUserAgent, forHTTPHeaderField: "User-Agent")
        jsReq.timeoutInterval = 20
        guard let (jsData, jsResponse) = try? await URLSession.shared.data(for: jsReq),
              (jsResponse as? HTTPURLResponse)?.statusCode == 200 else {
            log("scrape-base: tải base.js thất bại")
            return false
        }
        let js = String(decoding: jsData, as: UTF8.self)
        log("scrape-base: base.js tải về \(jsData.count) bytes")
        if let id = firstCapture(
            in: js,
            pattern: #"clientId:"([-\w]+\.apps\.googleusercontent\.com)""#) {
            if clientID == nil { clientID = id }
            log("scrape-base: client_id TÌM THẤY trong base.js (len=\(id.count))")
        }
        if let secret = firstCapture(
            in: js,
            pattern: #"clientId:"[-\w]+\.apps\.googleusercontent\.com",\n?[$\w]+:"(\w+)""#) {
            if clientSecret == nil { clientSecret = secret }
            log("scrape-base: client_secret TÌM THẤY trong base.js (len=\(secret.count))")
        }
        if clientID == nil || clientSecret == nil {
            log("scrape-base: base.js chưa đủ credentials "
                + "(id=\(clientID != nil) secret=\(clientSecret != nil))")
            return false
        }
        return true
    }

    /// Cả hai credentials đã có: lưu vào sandbox của app
    /// (không bao giờ ghi log) và nêu tên chân hoàn tất.
    private func finishScrape(completingLeg: String) {
        UserDefaults.standard.set(clientID, forKey: "probe9.clientID")
        UserDefaults.standard.set(clientSecret, forKey: "probe9.clientSecret")
        verdict = "ĐẠT — đủ credentials (chân hoàn tất: \(completingLeg)). Bấm nút 2 để xin mã kích hoạt."
        log("scrape: XONG — chân hoàn tất: \(completingLeg) — bấm nút 2 để xin mã kích hoạt")
        log("KẾT QUẢ probe9-scrape: \(verdict)")
    }

    func scrape() {
        Task {
            log("START Probe 9 — cào credentials của TV client từ youtube.com/tv (SmartTubeIOS recipe)")
            // Chân 1 (chính): base-js theo công thức SmartTubeIOS.
            if await scrapeBaseJS() {
                finishScrape(completingLeg: "base-js")
                return
            }
            // Chân 2 (dự phòng): patterns cũ trên HTML /tv (UA Cobalt).
            guard let url = URL(string: "https://www.youtube.com/tv") else { return }
            var req = URLRequest(url: url)
            req.setValue(Self.tvUserAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                log("scrape: tải trang /tv thất bại (chân HTML) — không có HTML cho chân bundle")
                verdict = "KHÔNG — cả 3 chân đều không đủ credentials "
                    + "(id=\(clientID != nil) secret=\(clientSecret != nil)): "
                    + "base-js không xong, trang /tv không tải được (xem log)"
                log("KẾT QUẢ probe9-scrape: \(verdict)")
                return
            }
            let html = String(decoding: data, as: UTF8.self)
            log("scrape: trang /tv tải về \(data.count) bytes (chân HTML, UA Cobalt)")
            let htmlFound = findCredentials(in: html)
            if let id = htmlFound.id, clientID == nil {
                clientID = id
                log("scrape: client_id TÌM THẤY (pattern: apps.googleusercontent.com, len=\(id.count))")
            }
            if let secret = htmlFound.secret, clientSecret == nil {
                clientSecret = secret
                log("scrape: client_secret TÌM THẤY (pattern: \(htmlFound.secretLabel ?? "?"), len=\(secret.count))")
            }
            if clientID != nil && clientSecret != nil {
                finishScrape(completingLeg: "HTML trang /tv")
                return
            }
            // Chân 3 (dự phòng cuối): bundle JS generic (chân của 0.1.1).
            log("scrape: KHÔNG đủ credentials trong HTML trang /tv "
                + "(id=\(clientID != nil) secret=\(clientSecret != nil)) — "
                + "cào tiếp từ các bundle JS của app TV")
            let completed = await scrapeJSBundles(html: html)
            if completed {
                finishScrape(completingLeg: "bundle JS")
                return
            }
            verdict = "KHÔNG — cả 3 chân (base-js, HTML, bundle JS) đều không đủ credentials "
                + "(id=\(clientID != nil) secret=\(clientSecret != nil)) (xem log)"
            log("KẾT QUẢ probe9-scrape: \(verdict)")
        }
    }

    // MARK: Step 2 — device code

    func requestCode() {
        Task {
            let id = clientID ?? UserDefaults.standard.string(forKey: "probe9.clientID")
            guard let id else {
                log("device/code: chưa có client_id — chạy bước 1 trước")
                return
            }
            clientID = id
            clientSecret = clientSecret ?? UserDefaults.standard.string(forKey: "probe9.clientSecret")
            let body = "client_id=\(id)&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fyoutube"
            guard let (data, status) = await formPost(
                "https://oauth2.googleapis.com/device/code", body: body) else {
                log("device/code: request thất bại")
                return
            }
            guard status == 200,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dc = parsed["device_code"] as? String,
                  let uc = parsed["user_code"] as? String else {
                log("device/code: HTTP \(status) — phản hồi không có device_code/user_code")
                return
            }
            deviceCode = dc
            userCode = uc
            let interval = (parsed["interval"] as? NSNumber)?.intValue ?? 5
            let expires = (parsed["expires_in"] as? NSNumber)?.intValue ?? 0
            log("device/code: ĐÃ CÓ MÃ — verification_url=\(parsed["verification_url"] as? String ?? "https://www.google.com/device") "
                + "hết hạn sau \(expires)s, poll mỗi \(interval)s. Anh mở link trên điện thoại và nhập mã.")
            pollTokens(interval: interval)
        }
    }

    private func pollTokens(interval: Int) {
        pollTask?.cancel()
        pollTask = Task {
            var wait = interval
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                guard let dc = deviceCode,
                      let id = clientID,
                      let secret = clientSecret else { return }
                let body = "client_id=\(id)&client_secret=\(secret)"
                    + "&device_code=\(dc)"
                    + "&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"
                guard let (data, status) = await formPost(
                    "https://oauth2.googleapis.com/token", body: body) else { continue }
                let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                if status == 200,
                   let access = parsed?["access_token"] as? String {
                    UserDefaults.standard.set(access, forKey: "probe9.accessToken")
                    if let refresh = parsed?["refresh_token"] as? String {
                        UserDefaults.standard.set(refresh, forKey: "probe9.refreshToken")
                    }
                    let expires = (parsed?["expires_in"] as? NSNumber)?.intValue ?? 0
                    hasToken = true
                    log("token: ĐÃ CÓ access token (len=\(access.count), expires_in=\(expires)s) "
                        + "refresh=\(parsed?["refresh_token"] != nil ? "present" : "absent") — giá trị không ghi log")
                    verdict = "ĐẠT (chân danh tính) — đã có token. Bấm nút 4 để gọi TVHTML5 cho tập Gold."
                    log("KẾT QUẢ probe9-identity: \(verdict)")
                    return
                }
                let error = (parsed?["error"] as? String) ?? "http\(status)"
                switch error {
                case "authorization_pending":
                    log("token poll: authorization_pending (chờ anh nhập mã trên điện thoại)")
                case "slow_down":
                    wait += 5
                    log("token poll: slow_down — tăng khoảng poll lên \(wait)s")
                default:
                    log("token poll: DỪNG — error=\(error)")
                    verdict = "KHÔNG — token poll dừng: \(error)"
                    return
                }
            }
        }
    }

    // MARK: Step 3 — TVHTML5 /player for the Gold episode

    func goldPlayerCall() {
        Task {
            guard let token = UserDefaults.standard.string(forKey: "probe9.accessToken") else {
                log("player: chưa có token — chạy bước 1–3 trước")
                return
            }
            log("player: gọi TVHTML5 /player cho tập GOLD vid=\(ProbeTargets.goldEp1) với OAuth bearer")
            let clients = (try? JSONDecoder().decode(
                [ProbeClientSpec].self, from: Data(ProbeClientLadder.bundledJSON.utf8))) ?? []
            guard let tv = clients.first(where: { $0.name == "TVHTML5" }) else { return }
            let body: [String: Any] = [
                "videoId": ProbeTargets.goldEp1,
                "context": ["client": [
                    "clientName": tv.clientName,
                    "clientVersion": tv.clientVersion,
                    "hl": "en", "gl": "US",
                    "userAgent": tv.userAgent,
                ]],
                "contentCheckOk": true,
                "racyCheckOk": true,
            ]
            guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false&key=\(tv.apiKey ?? "")"),
                  let bodyData = try? JSONSerialization.data(withJSONObject: body)
            else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = bodyData
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(tv.clientNumber, forHTTPHeaderField: "X-YouTube-Client-Name")
            req.setValue(tv.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
            req.setValue(tv.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let t0 = Date()
            guard let (data, response) = try? await URLSession.shared.data(for: req) else {
                log("player: request thất bại (mạng)")
                return
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log("player: HTTP \(http) — phản hồi không parse được")
                return
            }
            let playability = parsed["playabilityStatus"] as? [String: Any]
            let status = (playability?["status"] as? String) ?? "?"
            let reason = (playability?["reason"] as? String) ?? ""
            let streaming = parsed["streamingData"] as? [String: Any]
            let formats = (streaming?["formats"] as? [Any]) ?? []
            let adaptive = (streaming?["adaptiveFormats"] as? [Any]) ?? []
            let all = formats + adaptive
            var direct = 0
            var ciphered = 0
            for case let format as [String: Any] in all {
                if format["url"] is String { direct += 1 }
                if format["signatureCipher"] is String { ciphered += 1 }
            }
            let sabr = streaming?["serverAbrStreamingUrl"] != nil
            let hls = streaming?["hlsManifestUrl"] as? String
            if let hls, let hlsURL = URL(string: hls) { goldHLS = hlsURL }
            log("player: HTTP \(http) \(ms)ms playability=\(status) reason=\(reason.isEmpty ? "-" : reason) "
                + "hlsManifest=\(hls != nil ? "YES" : "no") formats=\(all.count) "
                + "directURL=\(direct) ciphered=\(ciphered) serverAbr(SABR)=\(sabr ? "YES" : "no")")
            if hls != nil {
                verdict = "ĐẠT — TVHTML5+OAuth trả HLS cho tập Gold. Bấm 'Phát HLS Gold' để xem AVPlayer có phát được không."
            } else if status == "OK" {
                verdict = "MỘT PHẦN — playability OK nhưng không có HLS (formats direct=\(direct) ciphered=\(ciphered) SABR=\(sabr ? "có" : "không")) — đúng cảnh báo SABR của Team 5"
            } else {
                verdict = "KHÔNG — playability=\(status) \(reason)"
            }
            log("KẾT QUẢ probe9-player: \(verdict)")
        }
    }

    func goldHLSURL() -> URL? { goldHLS }

    // MARK: HTTP helpers

    private func formPost(_ urlString: String, body: String) async -> (Data, Int)? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
        } catch {
            return nil
        }
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range, in: text) else { return nil }
        return String(text[r])
    }

    private func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

struct DeviceCodeView: View {
    let onExit: () -> Void
    @StateObject private var model = DeviceCodeModel()
    @State private var showPlayer = false
    @State private var goldPlayer: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Probe 9 — Device-code + TVHTML5 Gold")
                .font(.system(size: 36, weight: .bold))
            Text("Đường dự phòng Gold mạnh nhất: đăng nhập bằng MÃ KÍCH HOẠT trên điện thoại (không trang Google, không passkey). Sau khi có token: gọi TVHTML5 cho tập Gold và ghi kết quả từng chân.")
                .font(.system(size: 23))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 1200, alignment: .leading)
            HStack(spacing: 16) {
                Button("1 · Cào credentials") { model.scrape() }
                Button("2 · Xin mã kích hoạt") { model.requestCode() }
                Button("3 · (poll tự chạy)") {}.disabled(true)
                Button("4 · Gọi TVHTML5 tập Gold") { model.goldPlayerCall() }
                    .disabled(!model.hasToken)
                Button("Phát HLS Gold") {
                    if let url = model.goldHLSURL() {
                        goldPlayer = AVPlayer(url: url)
                        showPlayer = true
                    }
                }
                .disabled(model.goldHLSURL() == nil)
            }
            .font(.system(size: 24, weight: .semibold))
            if !model.userCode.isEmpty {
                HStack(spacing: 24) {
                    Text("MÃ KÍCH HOẠT:")
                        .font(.system(size: 30))
                    Text(model.userCode)
                        .font(.system(size: 64, weight: .heavy, design: .monospaced))
                    Text("Mở google.com/device trên điện thoại và nhập mã này")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }
            }
            if !model.verdict.isEmpty {
                Text(model.verdict)
                    .font(.system(size: 27, weight: .heavy))
                    .foregroundStyle(model.verdict.contains("KHÔNG") ? .red : .green)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 20, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(50)
        .onExitCommand { onExit() }
        .fullScreenCover(isPresented: $showPlayer) {
            if let goldPlayer {
                NativePlayerView(player: goldPlayer)
                    .ignoresSafeArea()
                    .onAppear {
                        DiagLog.write("probe9", "player: phát HLS Gold trong AVPlayer")
                        goldPlayer.play()
                    }
                    .onExitCommand { showPlayer = false }
            }
        }
    }
}

// MARK: - Probe 10 — BotGuard minting (SPECULATIVE, Team A-6)
//
// Can YouTube's BotGuard even EXECUTE inside our bridged
// WebView on tvOS? The probe loads youtube.com in the view,
// fetches the attestation challenge from the page's own
// origin, loads the interpreter the challenge names, and
// reports the furthest step reached. A token's VALUE never
// leaves the page — only its length would be reported, and
// only if the flow ever gets that far.

@MainActor
final class BotGuardModel: ObservableObject {
    let controller = ProbeWebController()
    @Published var lines: [String] = []
    @Published var verdict: String = ""
    private var started = false
    private var lastStep = ""
    private var pollTask: Task<Void, Never>?

    static let installScript = """
        (function(){
          window.__probeBG = {step: 'init', http: 0, hasChallenge: false,
            interpreter: false, factory: false, tokenLen: 0, error: ''};
          var S = window.__probeBG;
          var KEY = 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';
          fetch('https://www.youtube.com/youtubei/v1/attestation?key=' + KEY + '&prettyPrint=false', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({
              context: {client: {clientName: 'IOS', clientVersion: '21.26.4',
                deviceMake: 'Apple', deviceModel: 'iPhone16,2',
                osName: 'iPhone', osVersion: '18.3.2.22D82', hl: 'en', gl: 'US'}},
              engagementType: 'ENGAGEMENT_TYPE_VIDEO'
            })
          }).then(function(r) {
            S.http = r.status;
            return r.json();
          }).then(function(j) {
            var bg = j && j.bgChallenge;
            if (!bg) { S.step = 'no-bgChallenge'; return; }
            S.hasChallenge = true;
            S.step = 'challenge-ok';
            var interp = bg.interpreterJavascript
              && bg.interpreterJavascript.privateDoNotAccessOrElseSafeResourceUrlWrappedValue;
            if (!interp) { S.step = 'no-interpreter-url'; return; }
            S.step = 'loading-interpreter';
            var sc = document.createElement('script');
            sc.src = interp;
            sc.onload = function() {
              S.interpreter = true;
              var names = Object.keys(window).filter(function(k) {
                return /botguard|BotGuard/.test(k);
              });
              S.step = 'interpreter-loaded globals=' + names.slice(0, 5).join(',');
              if (window.botguard || window.BotGuard) {
                S.factory = true;
                S.step = 'factory-present';
              }
            };
            sc.onerror = function() { S.step = 'interpreter-load-error'; };
            document.head.appendChild(sc);
          }).catch(function(e) {
            S.step = 'fetch-failed';
            S.error = String(e).slice(0, 80);
          });
          return 'started';
        })()
        """

    func log(_ line: String) {
        DiagLog.write("probe10", line)
        lines.append(line)
        if lines.count > 7 { lines.removeFirst(lines.count - 7) }
    }

    func start() {
        guard !started else { return }
        started = true
        log("START Probe 10 — BotGuard minting (SPECULATIVE): nạp youtube.com, chờ 3s, cài script mint")
        controller.onFinishLoad = { [weak self] in
            guard let self else { return }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.controller.evaluate(Self.installScript)
                self.log("botguard: script mint đã cài — bắt đầu poll trạng thái")
                self.beginPolling()
            }
        }
        controller.load(url: "https://www.youtube.com/", userAgent: ProbeJS.safariUA,
                        lockedURL: nil)
    }

    private func beginPolling() {
        pollTask = Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled else { return }
                let result = await withCheckedContinuation {
                    (cont: CheckedContinuation<String?, Never>) in
                    self.controller.evaluateForResult(
                        "JSON.stringify(window.__probeBG || {step: 'gone'})"
                    ) { r in cont.resume(returning: r) }
                }
                guard let result,
                      let data = result.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let step = parsed["step"] as? String
                else { continue }
                if step != self.lastStep {
                    self.lastStep = step
                    let http = (parsed["http"] as? NSNumber)?.intValue ?? 0
                    let challenge = (parsed["hasChallenge"] as? Bool) ?? false
                    let interp = (parsed["interpreter"] as? Bool) ?? false
                    let factory = (parsed["factory"] as? Bool) ?? false
                    let tokenLen = (parsed["tokenLen"] as? NSNumber)?.intValue ?? 0
                    self.log("botguard step: \(step) (http=\(http) challenge=\(challenge) "
                        + "interpreter=\(interp) factory=\(factory) tokenLen=\(tokenLen))")
                    if factory {
                        self.verdict = "MỞ — BotGuard chạy tới factory trong WebView tvOS (mint đầy đủ là đợt nghiên cứu kế tiếp)"
                        self.log("KẾT QUẢ probe10: \(self.verdict)")
                        return
                    }
                }
            }
            guard let self else { return }
            self.verdict = "KHÔNG/CHƯA — dừng ở bước '\(self.lastStep)' sau 45s (đây là bằng chứng đóng/mở nhánh PO-token)"
            self.log("KẾT QUẢ probe10: \(self.verdict)")
        }
    }

    func stop() { pollTask?.cancel() }
}

struct BotGuardView: View {
    let onExit: () -> Void
    @StateObject private var model = BotGuardModel()

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Probe 10 — BotGuard minting (SPECULATIVE)")
                        .font(.system(size: 34, weight: .bold))
                    Text("BotGuard của YouTube có CHẠY được trong WebView cầu nối trên tvOS không? Chỉ ghi bước đi xa nhất — giá trị token không bao giờ rời trang.")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 900, alignment: .leading)
                }
                Spacer()
                if !model.verdict.isEmpty {
                    Text(model.verdict)
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(model.verdict.contains("MỞ") ? .green : .orange)
                        .frame(maxWidth: 640, alignment: .trailing)
                }
            }
            ProbeWebView(controller: model.controller,
                         navigationMode: .doorRoam,
                         playbackPresses: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 19, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(50)
        .onExitCommand { onExit() }
        .task { model.start() }
        .onDisappear { model.stop() }
    }
}

// MARK: - Probe 9 token store (shared by Probe 9 + Probe 13)
//
// Probe 9 originally kept its OAuth material in four
// UserDefaults keys, written inline by
// `DeviceCodeProbeModel.finishScrape` / `pollToken`.
// Probe 13 (SABR phase 1) needs the same tokens PLUS a
// refresh path and an expiry stamp, so the accessors
// live here now — additive only: Probe 9's own code is
// untouched and reads/writes the same keys. UserDefaults
// lives in the app sandbox, so a delete+reinstall wipes
// everything below — which is why Probe 13 re-runs the
// device-code flow in-line when no token is present.
// Token VALUES are never logged anywhere — presence,
// lengths and expiry only.

struct Probe9RefreshOutcome {
    var token: String?
    var note: String
}

enum Probe9TokenStore {
    static let accessTokenKey = "probe9.accessToken"
    static let refreshTokenKey = "probe9.refreshToken"
    static let clientIDKey = "probe9.clientID"
    static let clientSecretKey = "probe9.clientSecret"
    static let expiryKey = "probe9.accessTokenExpiry"

    static var accessToken: String? {
        UserDefaults.standard.string(forKey: accessTokenKey)
    }

    static var refreshToken: String? {
        UserDefaults.standard.string(forKey: refreshTokenKey)
    }

    static var clientID: String? {
        UserDefaults.standard.string(forKey: clientIDKey)
    }

    static var clientSecret: String? {
        UserDefaults.standard.string(forKey: clientSecretKey)
    }

    /// Written by `saveTokens` (Probe 13's flows). Probe 9
    /// never stamped an expiry, so tokens saved by Probe 9
    /// read back as nil here — callers treat that as
    /// "unknown expiry, let /player arbitrate (401 →
    /// refresh / device-code)".
    static var accessTokenExpiry: Date? {
        let epoch = UserDefaults.standard.double(forKey: expiryKey)
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }

    static func saveClientCredentials(id: String, secret: String) {
        UserDefaults.standard.set(id, forKey: clientIDKey)
        UserDefaults.standard.set(secret, forKey: clientSecretKey)
    }

    static func saveTokens(access: String, refresh: String?, expiresIn: Int?) {
        UserDefaults.standard.set(access, forKey: accessTokenKey)
        if let refresh {
            UserDefaults.standard.set(refresh, forKey: refreshTokenKey)
        }
        if let expiresIn {
            UserDefaults.standard.set(
                Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970,
                forKey: expiryKey)
        }
    }

    /// Exchange the stored refresh token for a fresh
    /// access token (Google OAuth `refresh_token` grant
    /// against the same token endpoint Probe 9 polls).
    /// The outcome carries a log-safe note (no values).
    static func refresh() async -> Probe9RefreshOutcome {
        guard let refreshToken, let clientID, let clientSecret else {
            return Probe9RefreshOutcome(
                token: nil,
                note: "refresh: thiếu refresh token hoặc clientId/secret — không refresh được")
        }
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            return Probe9RefreshOutcome(token: nil, note: "refresh: URL token endpoint không hợp lệ")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
        let fields = ["client_id": clientID,
                      "client_secret": clientSecret,
                      "refresh_token": refreshToken,
                      "grant_type": "refresh_token"]
        request.httpBody = Data(fields.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)"
        }.joined(separator: "&").utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard http == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let access = json["access_token"] as? String else {
                return Probe9RefreshOutcome(
                    token: nil,
                    note: "refresh: token endpoint HTTP \(http) — refresh thất bại")
            }
            let newRefresh = json["refresh_token"] as? String
            let expiresIn = (json["expires_in"] as? NSNumber)?.intValue
            saveTokens(access: access, refresh: newRefresh, expiresIn: expiresIn)
            let expiresNote = expiresIn.map { "\($0)" } ?? "?"
            return Probe9RefreshOutcome(
                token: access,
                note: "refresh: OK — access token mới len \(access.count), expires_in \(expiresNote)s")
        } catch {
            return Probe9RefreshOutcome(
                token: nil,
                note: "refresh: lỗi mạng — \(error.localizedDescription)")
        }
    }
}
