import SwiftUI
import AVKit

// MARK: - Probes 3+7 — extraction (InnerTube client matrix)
//
// The free-tier structural route, measured end to end:
// resolve the fixed free episode through FOUR clients
// (VISIONOS · ANDROID_VR · TVHTML5 anonymous · WEB_SAFARI),
// log per-client verdicts, then play the winner natively
// and exercise the full experience (play/pause, NEXT by
// queue-advance AND by item-swap, prefetch, signed-URL
// lifetime). Folded research: A-1 prefetch · A-2 visitorData
// persistence · A-4 web_safari · A-5/C-5 URL lifetime ·
// A-7 client-identity-as-data · A-8 per-attempt verdicts ·
// C-4 queue-vs-swap · C-6 /next completeness · D-P1/D-P2
// beacons · D-P5 playbackTracking inventory · D-P6
// sync-down seed read.
//
// Discipline: playabilityStatus and reason strings are
// logged verbatim (public API responses); stream URLs,
// tracking URLs and cookie values are NEVER logged —
// presence, counts and lifetimes only.

// MARK: Client ladder as data (Team A-7)

struct ProbeClientSpec: Codable, Sendable {
    var name: String
    var clientName: String
    var clientVersion: String
    var clientNumber: String
    var userAgent: String
    var apiKey: String?
    var deviceMake: String?
    var deviceModel: String?
    var osName: String?
    var osVersion: String?
    var androidSdkVersion: Int?
}

/// The bundled fallback ladder (identical content to the
/// hosted probe-clients.json on the dabanh-playlist repo).
enum ProbeClientLadder {
    static let hostedURL = "https://raw.githubusercontent.com/zjoenguyenz/dabanh-playlist/main/probe-clients.json"
    static let bundledJSON = """
        [
          {"name":"VISIONOS","clientName":"VISIONOS","clientVersion":"1.02","clientNumber":"101",
           "userAgent":"Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
           "deviceMake":"Apple","deviceModel":"RealityDevice17,1","osName":"visionOS","osVersion":"26.5.23O471"},
          {"name":"ANDROID_VR","clientName":"ANDROID_VR","clientVersion":"1.65.10","clientNumber":"28",
           "userAgent":"com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
           "apiKey":"AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w",
           "deviceMake":"Oculus","deviceModel":"Quest 3","osName":"Android","osVersion":"12L","androidSdkVersion":32},
          {"name":"TVHTML5","clientName":"TVHTML5","clientVersion":"7.20260707.07.00","clientNumber":"7",
           "userAgent":"Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)",
           "apiKey":"AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"},
          {"name":"WEB_SAFARI","clientName":"WEB","clientVersion":"2.20260708.00.00","clientNumber":"1",
           "userAgent":"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",
           "apiKey":"AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"}
        ]
        """

    static func load() async -> (clients: [ProbeClientSpec], source: String) {
        if let url = URL(string: hostedURL) {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            if let (data, response) = try? await URLSession.shared.data(for: req),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let clients = try? JSONDecoder().decode([ProbeClientSpec].self, from: data),
               !clients.isEmpty {
                return (clients, "hosted (dabanh-playlist/probe-clients.json)")
            }
        }
        let clients = (try? JSONDecoder().decode(
            [ProbeClientSpec].self,
            from: Data(bundledJSON.utf8))) ?? []
        return (clients, "bundled fallback")
    }
}

// MARK: Resolver

struct ResolveOutcome: Sendable {
    var clientName: String = ""
    var status: String = ""
    var reason: String = ""
    var hlsPresent: Bool = false
    var formatCount: Int = 0
    var playableKind: String = ""   // "hls" | "muxed" | ""
    var milliseconds: Int = 0
    var posts: Int = 0
    var trackingFields: [String] = []
}

@MainActor
final class ProbeResolver {
    /// In-memory only: the winning URLs + the tracking pair.
    /// Never written to the log.
    var playableURL: URL?
    var trackingPlayback: String?
    var trackingWatchtime: String?

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    func resolve(videoID: String, client: ProbeClientSpec) async -> ResolveOutcome {
        var outcome = ResolveOutcome(clientName: client.name)
        let t0 = Date()
        var visitorData = UserDefaults.standard.string(forKey: "probe.visitorData")
        if visitorData != nil {
            DiagLog.write("extract", "resolve \(client.name): dùng visitorData ĐÃ LƯU (A-2)")
        }
        for attempt in 0..<2 {
            outcome.posts += 1
            let (parsed, httpStatus) = await postPlayer(
                videoID: videoID, client: client, visitorData: visitorData)
            guard let parsed else {
                outcome.status = "HTTP \(httpStatus)"
                outcome.milliseconds = Int(Date().timeIntervalSince(t0) * 1000)
                return outcome
            }
            let playability = parsed["playabilityStatus"] as? [String: Any]
            outcome.status = (playability?["status"] as? String) ?? "?"
            outcome.reason = (playability?["reason"] as? String) ?? ""
            if outcome.status == "OK" {
                let streaming = parsed["streamingData"] as? [String: Any]
                let formats = (streaming?["formats"] as? [Any]) ?? []
                let adaptive = (streaming?["adaptiveFormats"] as? [Any]) ?? []
                outcome.formatCount = formats.count + adaptive.count
                if let hls = streaming?["hlsManifestUrl"] as? String,
                   let url = URL(string: hls) {
                    outcome.hlsPresent = true
                    outcome.playableKind = "hls"
                    playableURL = url
                } else {
                    // First direct muxed format (progressive
                    // entries carry both audio and video).
                    for case let format as [String: Any] in formats {
                        if let direct = format["url"] as? String,
                           let url = URL(string: direct) {
                            outcome.playableKind = "muxed"
                            playableURL = url
                            break
                        }
                    }
                }
                // D-P5: playbackTracking inventory — field
                // NAMES only.
                if let tracking = parsed["playbackTracking"] as? [String: Any] {
                    let known = ["videostatsPlaybackUrl", "videostatsWatchtimeUrl",
                                 "videostatsScheduledFlushWalltimeSeconds",
                                 "videostatsDefaultFlushIntervalSeconds",
                                 "atrUrl", "ptrackingUrl", "qoeUrl",
                                 "videostatsDelayplayUrl"]
                    outcome.trackingFields = known.filter { tracking[$0] != nil }
                    trackingPlayback = tracking["videostatsPlaybackUrl"] as? String
                    trackingWatchtime = tracking["videostatsWatchtimeUrl"] as? String
                }
                outcome.milliseconds = Int(Date().timeIntervalSince(t0) * 1000)
                return outcome
            }
            // Refusal: the AIOStreams visitorData retry, once.
            if attempt == 0,
               let context = parsed["responseContext"] as? [String: Any],
               let fresh = context["visitorData"] as? String {
                visitorData = fresh
                UserDefaults.standard.set(fresh, forKey: "probe.visitorData")
                DiagLog.write("extract", "resolve \(client.name): bị từ chối (\(outcome.status)) — thử lại với visitorData mới (A-2, đã lưu)")
                continue
            }
            outcome.milliseconds = Int(Date().timeIntervalSince(t0) * 1000)
            return outcome
        }
        outcome.milliseconds = Int(Date().timeIntervalSince(t0) * 1000)
        return outcome
    }

    private func postPlayer(videoID: String, client: ProbeClientSpec,
                            visitorData: String?) async -> ([String: Any]?, Int) {
        var clientDict: [String: Any] = [
            "clientName": client.clientName,
            "clientVersion": client.clientVersion,
            "hl": "en",
            "gl": "US",
            "userAgent": client.userAgent,
        ]
        if let v = client.deviceMake { clientDict["deviceMake"] = v }
        if let v = client.deviceModel { clientDict["deviceModel"] = v }
        if let v = client.osName { clientDict["osName"] = v }
        if let v = client.osVersion { clientDict["osVersion"] = v }
        if let v = client.androidSdkVersion { clientDict["androidSdkVersion"] = v }
        if let visitorData { clientDict["visitorData"] = visitorData }
        let body: [String: Any] = [
            "videoId": videoID,
            "context": ["client": clientDict],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        var urlString = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
        if let key = client.apiKey { urlString += "&key=\(key)" }
        guard let url = URL(string: urlString),
              let bodyData = try? JSONSerialization.data(withJSONObject: body)
        else { return (nil, -1) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        req.setValue(client.clientNumber, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(client.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        if let visitorData {
            req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else { return (nil, status) }
            let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (parsed, status)
        } catch {
            return (nil, -2)
        }
    }
}

// MARK: Native player plumbing

struct NativePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController,
                                context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

@MainActor
final class ExtractPlayerModel: ObservableObject {
    @Published var presented = false
    let player = AVQueuePlayer()
    private(set) var mode: String = "queue"
    private var supervisor: Task<Void, Never>?
    private var firstFrameAt: Date?
    private var playStartedAt: Date?
    private var currentVideoID: String = ""
    private var advanceStartedAt: Date?
    private var endHandled = false
    var onEvent: ((String) -> Void)?

    private func event(_ line: String) {
        DiagLog.write("extract", line)
        onEvent?(line)
    }

    func play(url: URL, videoID: String, mode: String) {
        self.mode = mode
        currentVideoID = videoID
        endHandled = false
        firstFrameAt = nil
        playStartedAt = Date()
        player.removeAllItems()
        let item = AVPlayerItem(url: url)
        player.insert(item, after: nil)
        presented = true
        player.play()
        event("player: bắt đầu phát vid=\(videoID) mode=\(mode)")
        startSupervisor()
    }

    /// A-1: insert the pre-resolved next item behind the
    /// current one (queue mode).
    func prefetchInsert(url: URL, videoID: String) {
        let item = AVPlayerItem(url: url)
        if let last = player.items().last {
            player.insert(item, after: last)
            event("player: prefetch đã chèn vid=\(videoID) vào hàng đợi (A-1)")
        }
    }

    func nextViaQueue() {
        advanceStartedAt = Date()
        player.advanceToNextItem()
        event("player: QUA TẬP kiểu QUEUE (advanceToNextItem)")
    }

    func nextViaSwap(url: URL, videoID: String) {
        advanceStartedAt = Date()
        currentVideoID = videoID
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
        event("player: QUA TẬP kiểu SWAP (replaceCurrentItem) vid=\(videoID)")
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
            event("player: pause (AVPlayer trực tiếp)")
        } else {
            player.play()
            event("player: play (AVPlayer trực tiếp)")
        }
    }

    func dismiss() {
        supervisor?.cancel()
        player.pause()
        presented = false
        event("player: đóng trình phát")
    }

    private func startSupervisor() {
        supervisor?.cancel()
        supervisor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard presented else { return }
        if firstFrameAt == nil,
           player.timeControlStatus == .playing,
           let item = player.currentItem, item.status == .readyToPlay {
            firstFrameAt = Date()
            let ms = Int(Date().timeIntervalSince(playStartedAt ?? Date()) * 1000)
            event("player: FIRST FRAME sau \(ms) ms")
            if let advanceStartedAt {
                let switchMs = Int(Date().timeIntervalSince(advanceStartedAt) * 1000)
                event("player: qua tập hoàn tất — press→picture \(switchMs) ms (mode=\(mode))")
                self.advanceStartedAt = nil
            }
        }
        if let item = player.currentItem, item.status == .failed {
            event("player: item FAILED — \(item.error?.localizedDescription ?? "?")")
        }
        // End detection for the swap mode's auto-advance
        // note: AVQueuePlayer advances itself in queue mode;
        // the tick just observes the current item change.
        if let d = player.currentItem?.duration.seconds,
           d.isFinite, d > 0,
           let t = player.currentItem?.currentTime().seconds,
           t >= d - 0.6, !endHandled {
            endHandled = true
            event("player: item tới cuối (t=\(Int(t))/\(Int(d))) — mode=\(mode) "
                + "(queue tự qua tập; swap do app xử lý ở bản production)")
        }
    }
}

// MARK: - The extraction screen

struct ExtractView: View {
    let onExit: () -> Void
    @StateObject private var model = ExtractModel()
    @StateObject private var playerModel = ExtractPlayerModel()

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Probe 3+7 — Trích xuất (ma trận client)")
                        .font(.system(size: 34, weight: .bold))
                    Text("Bằng Chứng Thép II tập 1 (free) qua 4 client InnerTube. Client thắng sẽ phát native; trong trình phát có sẵn: nạp trước tập 2, qua tập QUEUE vs SWAP, beacon D-P1/D-P2.")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
                Spacer()
                if !model.verdict.isEmpty {
                    Text(model.verdict)
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(model.verdict.contains("KHÔNG") ? .red : .green)
                        .frame(maxWidth: 640, alignment: .trailing)
                }
            }
            HStack(spacing: 16) {
                Button("1 · Chạy ma trận 4 client") { model.runMatrix(player: playerModel) }
                Button("2 · Phát QUEUE + nạp trước") { model.playMode("queue", player: playerModel) }
                    .disabled(model.winningURL == nil)
                Button("3 · Phát SWAP") { model.playMode("swap", player: playerModel) }
                    .disabled(model.winningURL == nil)
            }
            .font(.system(size: 24, weight: .semibold))
            HStack(spacing: 16) {
                Button("Beacon CÓ cookie (D-P1)") { model.runBeacon(withCookies: true) }
                    .disabled(!model.trackingPresent)
                Button("Beacon KHÔNG cookie (D-P2)") { model.runBeacon(withCookies: false) }
                    .disabled(!model.trackingPresent)
                Button("Kiểm tra lại URL (C-5)") { model.recheckURL() }
                    .disabled(model.winningURL == nil)
                Button("/next panel (C-6)") { model.checkNextPanel() }
                Button("Đọc lịch sử (D-P6)") { model.syncDown() }
            }
            .font(.system(size: 22))
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 20, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(50)
        .onExitCommand { onExit() }
        .task { model.prepare(player: playerModel) }
        .fullScreenCover(isPresented: $playerModel.presented) {
            ZStack(alignment: .topTrailing) {
                NativePlayerView(player: playerModel.player)
                    .ignoresSafeArea()
                HStack(spacing: 16) {
                    Button("⏭ Qua tập") { model.playerNext(player: playerModel) }
                    Button("Đóng") { playerModel.dismiss() }
                }
                .font(.system(size: 24, weight: .semibold))
                .padding(40)
            }
        }
    }
}

@MainActor
final class ExtractModel: ObservableObject {
    @Published var lines: [String] = []
    @Published var verdict: String = ""
    @Published private(set) var winningURL: URL?
    @Published private(set) var trackingPresent = false
    let resolver = ProbeResolver()
    private var winningClient: ProbeClientSpec?
    private var clients: [ProbeClientSpec] = []
    private var prefetchedEp2: URL?
    private var prepared = false

    func log(_ line: String) {
        DiagLog.write("extract", line)
        lines.append(line)
    }

    func prepare(player: ExtractPlayerModel) {
        guard !prepared else { return }
        prepared = true
        player.onEvent = { [weak self] line in self?.lines.append(line) }
        Task {
            let loaded = await ProbeClientLadder.load()
            clients = loaded.clients
            log("START Probe 3+7 — client ladder từ: \(loaded.source) "
                + "(\(clients.map { "\($0.name)@\($0.clientVersion)" }.joined(separator: ", ")))")
            log("danh sách tập: dữ liệu playlist có sẵn (tvb-yt.json) — resolve theo videoId, không cần trang")
        }
    }

    func runMatrix(player: ExtractPlayerModel) {
        Task {
            if clients.isEmpty {
                let loaded = await ProbeClientLadder.load()
                clients = loaded.clients
                log("ma trận: ladder nạp muộn từ \(loaded.source)")
            }
            log("ma trận: bắt đầu resolve vid=\(ProbeTargets.freeEp1)")
            var winner: (ProbeClientSpec, URL)?
            for client in clients {
                let resolver = ProbeResolver()
                let outcome = await resolver.resolve(
                    videoID: ProbeTargets.freeEp1, client: client)
                log("client \(outcome.clientName): status=\(outcome.status) "
                    + "reason=\(outcome.reason.isEmpty ? "-" : outcome.reason) "
                    + "hls=\(outcome.hlsPresent ? "YES" : "no") formats=\(outcome.formatCount) "
                    + "playable=\(outcome.playableKind.isEmpty ? "-" : outcome.playableKind) "
                    + "posts=\(outcome.posts) \(outcome.milliseconds)ms")
                if client.name == "VISIONOS" {
                    log("D-P5 playbackTracking (VISIONOS): "
                        + (outcome.trackingFields.isEmpty
                            ? "KHÔNG có block playbackTracking"
                            : "có các field: \(outcome.trackingFields.joined(separator: ", "))"))
                    self.resolver.trackingPlayback = resolver.trackingPlayback
                    self.resolver.trackingWatchtime = resolver.trackingWatchtime
                }
                if winner == nil, let url = resolver.playableURL {
                    winner = (client, url)
                    self.resolver.trackingPlayback = resolver.trackingPlayback ?? self.resolver.trackingPlayback
                    self.resolver.trackingWatchtime = resolver.trackingWatchtime ?? self.resolver.trackingWatchtime
                }
                if self.resolver.trackingPlayback != nil {
                    self.trackingPresent = true
                }
            }
            if let winner {
                winningClient = winner.0
                winningURL = winner.1
                log("ma trận: client thắng đầu tiên = \(winner.0.name)")
                if let expire = expireSeconds(of: winner.1) {
                    log("C-5: URL thắng còn hạn ≈ \(expire / 60) phút (đọc từ tham số expire)")
                }
                verdict = "MA TRẬN XONG — thắng: \(winner.0.name). Bấm nút 2 hoặc 3 để phát."
            } else {
                verdict = "KHÔNG — không client nào trả URL phát được"
            }
            log("KẾT QUẢ extract-matrix: \(verdict)")
        }
    }

    func playMode(_ mode: String, player: ExtractPlayerModel) {
        guard let url = winningURL, let client = winningClient else { return }
        Task {
            player.play(url: url, videoID: ProbeTargets.freeEp1, mode: mode)
            // A-1: prefetch episode 2 with the winning client.
            let t0 = Date()
            let resolver = ProbeResolver()
            let outcome = await resolver.resolve(
                videoID: ProbeTargets.freeEp2, client: client)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if let ep2 = resolver.playableURL {
                prefetchedEp2 = ep2
                log("A-1 prefetch tập 2: resolve \(ms)ms status=\(outcome.status) — sẵn sàng qua tập")
                if mode == "queue" {
                    player.prefetchInsert(url: ep2, videoID: ProbeTargets.freeEp2)
                }
            } else {
                log("A-1 prefetch tập 2: THẤT BẠI status=\(outcome.status) reason=\(outcome.reason)")
            }
        }
    }

    func playerNext(player: ExtractPlayerModel) {
        if player.mode == "queue" {
            player.nextViaQueue()
        } else if let ep2 = prefetchedEp2 {
            player.nextViaSwap(url: ep2, videoID: ProbeTargets.freeEp2)
        } else {
            log("player: chưa có URL tập 2 đã nạp trước")
        }
    }

    // MARK: C-5 — signed-URL lifetime re-check

    func recheckURL() {
        guard let url = winningURL else { return }
        Task {
            let t0 = Date()
            var status = -1
            var isManifest = false
            if let (data, response) = try? await URLSession.shared.data(from: url) {
                status = (response as? HTTPURLResponse)?.statusCode ?? -1
                isManifest = String(decoding: data.prefix(7), as: UTF8.self) == "#EXTM3U"
            }
            let mins = Int(Date().timeIntervalSince(t0) / 60)
            log("C-5 re-check URL sau \(mins) phút từ lúc phát: HTTP \(status) manifest=\(isManifest ? "YES" : "no")")
        }
    }

    private func expireSeconds(of url: URL) -> Int? {
        // googlevideo carries the expiry both as an `expire`
        // query item and as an /expire/<epoch>/ path segment
        // (the manifest URL uses the path form).
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let raw = components.queryItems?.first(where: { $0.name == "expire" })?.value,
           let epoch = TimeInterval(raw) {
            return Int(epoch - Date().timeIntervalSince1970)
        }
        let segments = url.pathComponents
        if let idx = segments.firstIndex(of: "expire"),
           idx + 1 < segments.count,
           let epoch = TimeInterval(segments[idx + 1]) {
            return Int(epoch - Date().timeIntervalSince1970)
        }
        return nil
    }

    // MARK: D-P1 / D-P2 — watch-time beacons

    func runBeacon(withCookies: Bool) {
        Task {
            guard let playback = resolver.trackingPlayback,
                  let watchtime = resolver.trackingWatchtime else {
                log("beacon: resolve VISIONOS không mang playbackTracking — beacon không chạy được (đây là đáp án D-P5)")
                return
            }
            var headers: [String: String] = [:]
            if withCookies {
                guard let cookie = await ProbeSession.shared.cookieHeader() else {
                    log("beacon D-P1: KHÔNG có cookie phiên — hãy đăng nhập ở Probe 4 trước")
                    return
                }
                headers["Cookie"] = cookie.header
                log("beacon D-P1: đính \(cookie.count) cookie của phiên đăng nhập (giá trị không ghi log)")
            } else {
                log("beacon D-P2: chạy KHÔNG cookie (control run)")
            }
            let cpn = (0..<16).map { _ in
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()!
            }.map(String.init).joined()
            let s1 = await fireBeacon(playback, extra: ["cmt": "0", "final": "0", "cpn": cpn],
                                      headers: headers)
            log("beacon playback ping (start): HTTP \(s1)")
            let s2 = await fireBeacon(watchtime, extra: ["st": "0", "et": "30", "cmt": "30", "cpn": cpn],
                                      headers: headers)
            log("beacon watchtime 0–30: HTTP \(s2)")
            let s3 = await fireBeacon(watchtime, extra: ["st": "30", "et": "60", "cmt": "60", "cpn": cpn],
                                      headers: headers)
            log("beacon watchtime 30–60: HTTP \(s3)")
            let s4 = await fireBeacon(watchtime, extra: ["st": "60", "et": "90", "cmt": "90", "final": "1", "cpn": cpn],
                                      headers: headers)
            log("beacon watchtime 60–90 final=1: HTTP \(s4)")
            log("beacon \(withCookies ? "D-P1" : "D-P2") xong — mốc thời gian NÉN (90s phát gói trong vài giây). "
                + (withCookies ? "KIỂM TRA: mở YouTube trên điện thoại → Lịch sử — tập này có xuất hiện ở ≈1:30 không." : ""))
        }
    }

    private func fireBeacon(_ base: String, extra: [String: String],
                            headers: [String: String]) async -> Int {
        guard var components = URLComponents(string: base) else { return -1 }
        var items = (components.queryItems ?? []).filter {
            !["cpn", "cmt", "final", "st", "et"].contains($0.name)
        }
        for (key, value) in extra {
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
        guard let url = components.url else { return -1 }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode ?? -1
        } catch {
            return -2
        }
    }

    // MARK: C-6 — /next panel completeness

    func checkNextPanel() {
        Task {
            guard let web = clients.first(where: { $0.name == "WEB_SAFARI" }) else { return }
            for probeEp in [ProbeTargets.freeEp1, ProbeTargets.freeEpisodes[19]] {
                let ids = await fetchNextPanel(videoID: probeEp, client: web)
                let truth = ProbeTargets.freeEpisodes
                var prefix = 0
                for (a, b) in zip(ids, truth) {
                    if a == b { prefix += 1 } else { break }
                }
                log("C-6 /next tại \(probeEp): panel có \(ids.count) tập, ground truth \(truth.count), "
                    + "khớp liên tục từ đầu: \(prefix)\(ids == truth ? " — TRÙNG TOÀN BỘ" : "")")
            }
        }
    }

    private func fetchNextPanel(videoID: String, client: ProbeClientSpec) async -> [String] {
        var collected: [String] = []
        var continuation: String?
        for _ in 0..<8 {
            var body: [String: Any] = [
                "context": ["client": [
                    "clientName": client.clientName,
                    "clientVersion": client.clientVersion,
                    "hl": "en", "gl": "US",
                    "userAgent": client.userAgent,
                ]],
                "videoId": videoID,
            ]
            if let continuation { body["continuation"] = continuation }
            guard let url = URL(string: "https://www.youtube.com/youtubei/v1/next?prettyPrint=false&key=\(client.apiKey ?? "")"),
                  let bodyData = try? JSONSerialization.data(withJSONObject: body)
            else { break }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = bodyData
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(client.clientNumber, forHTTPHeaderField: "X-YouTube-Client-Name")
            req.setValue(client.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
            req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { break }
            var nextToken: String?
            collectPanel(parsed, into: &collected, token: &nextToken)
            guard let token = nextToken, token != continuation else { break }
            continuation = token
        }
        return collected
    }

    /// Recursive walk: playlistPanelVideoRenderer videoIds
    /// in order + the panel continuation token.
    private func collectPanel(_ node: Any, into ids: inout [String], token: inout String?) {
        if let dict = node as? [String: Any] {
            if let renderer = dict["playlistPanelVideoRenderer"] as? [String: Any],
               let vid = renderer["videoId"] as? String {
                ids.append(vid)
            }
            if let cont = dict["playlistPanelContinuation"] as? String {
                token = cont
            }
            if let item = dict["continuationItemRenderer"] as? [String: Any],
               let endpoint = item["continuationEndpoint"] as? [String: Any],
               let command = endpoint["continuationCommand"] as? [String: Any],
               let t = command["token"] as? String {
                token = t
            }
            for value in dict.values { collectPanel(value, into: &ids, token: &token) }
        } else if let array = node as? [Any] {
            for value in array { collectPanel(value, into: &ids, token: &token) }
        }
    }

    // MARK: D-P6 — sync-down seed read (signed-in history)

    func syncDown() {
        Task {
            guard let cookie = await ProbeSession.shared.cookieHeader() else {
                log("D-P6: chưa đăng nhập (Probe 4) — không đọc được lịch sử")
                return
            }
            guard let web = clients.first(where: { $0.name == "WEB_SAFARI" }),
                  let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false&key=\(web.apiKey ?? "")")
            else { return }
            let body: [String: Any] = [
                "context": ["client": [
                    "clientName": web.clientName,
                    "clientVersion": web.clientVersion,
                    "hl": "en", "gl": "US",
                    "userAgent": web.userAgent,
                ]],
                "browseId": "FEhistory",
            ]
            guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = bodyData
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(web.clientNumber, forHTTPHeaderField: "X-YouTube-Client-Name")
            req.setValue(web.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
            req.setValue(web.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue(cookie.header, forHTTPHeaderField: "Cookie")
            guard let (data, response) = try? await URLSession.shared.data(for: req) else {
                log("D-P6: browse lịch sử thất bại (HTTP -1)")
                return
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                log("D-P6: browse lịch sử thất bại (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))")
                return
            }
            var found: [(String, Double)] = []
            collectWatched(parsed, into: &found)
            let mine = found.filter { ProbeTargets.freeEpisodes.contains($0.0) }
            if mine.isEmpty {
                log("D-P6: phản hồi lịch sử có \(found.count) mục có percentDurationWatched; "
                    + "không mục nào thuộc series free (có thể tập chưa từng xem trên tài khoản)")
            } else {
                for (vid, fraction) in mine {
                    log("D-P6: vid=\(vid) percentDurationWatched=\(String(format: "%.3f", fraction))")
                }
            }
        }
    }

    /// Recursive walk pairing a videoId with a
    /// percentDurationWatched found in the same subtree.
    private func collectWatched(_ node: Any, into found: inout [(String, Double)]) {
        if let dict = node as? [String: Any] {
            if let vid = dict["videoId"] as? String {
                var fraction: Double?
                findFraction(dict, into: &fraction)
                if let fraction { found.append((vid, fraction)) }
            }
            for value in dict.values { collectWatched(value, into: &found) }
        } else if let array = node as? [Any] {
            for value in array { collectWatched(value, into: &found) }
        }
    }

    private func findFraction(_ node: Any, into fraction: inout Double?) {
        if fraction != nil { return }
        if let dict = node as? [String: Any] {
            if let value = dict["percentDurationWatched"] as? NSNumber {
                fraction = value.doubleValue
                return
            }
            for value in dict.values { findFraction(value, into: &fraction) }
        } else if let array = node as? [Any] {
            for value in array { findFraction(value, into: &fraction) }
        }
    }
}
