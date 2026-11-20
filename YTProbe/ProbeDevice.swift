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

    func scrape() {
        Task {
            log("START Probe 9 — cào credentials của TV client từ youtube.com/tv (SmartTubeIOS pattern)")
            guard let url = URL(string: "https://www.youtube.com/tv") else { return }
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)",
                         forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                log("scrape: tải trang /tv thất bại")
                verdict = "KHÔNG — không tải được trang youtube.com/tv"
                return
            }
            let html = String(decoding: data, as: UTF8.self)
            log("scrape: trang /tv tải về \(data.count) bytes")
            clientID = firstMatch(in: html, pattern: "[0-9]+-[a-z0-9]+\\.apps\\.googleusercontent\\.com")
            if clientID != nil {
                log("scrape: client_id TÌM THẤY (pattern: apps.googleusercontent.com, len=\(clientID?.count ?? 0))")
            }
            for (label, pattern) in [
                ("json", "\"client_secret\"\\s*:\\s*\"([^\"]{8,})\""),
                ("camel", "\"clientSecret\"\\s*:\\s*\"([^\"]{8,})\""),
                ("js", "client_secret=([A-Za-z0-9_\\-]{8,})"),
            ] {
                if let secret = firstCapture(in: html, pattern: pattern) {
                    clientSecret = secret
                    log("scrape: client_secret TÌM THẤY (pattern: \(label), len=\(secret.count))")
                    break
                }
            }
            if clientID == nil || clientSecret == nil {
                log("scrape: KHÔNG đủ credentials trong HTML trang /tv "
                    + "(id=\(clientID != nil) secret=\(clientSecret != nil)) — "
                    + "credentials có thể nằm trong bundle JS của app TV (đợt sau cào tiếp từ JS)")
                verdict = "KHÔNG — chưa cào được credentials từ HTML (xem log)"
                return
            }
            UserDefaults.standard.set(clientID, forKey: "probe9.clientID")
            UserDefaults.standard.set(clientSecret, forKey: "probe9.clientSecret")
            log("scrape: XONG — bấm nút 2 để xin mã kích hoạt")
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
