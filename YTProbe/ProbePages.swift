import SwiftUI
import MediaPlayer
import AVFoundation

// MARK: - Page probes (Probes 1, 2, 5, 6, 8 + audit/research cells)
//
// Every page probe writes the same log discipline: a start
// line (levers, UA, target), per-poll lines, the page's own
// playabilityStatus at load and at failure (Audit G-3), and
// an end verdict line. The screen mirrors the last lines +
// one big verdict line, so a photo of the TV tells the
// story; the log alone can rebuild it (owner rule
// 2026-11-20: the log is the product).

struct PageProbeSpec {
    var tag: String
    var title: String
    var note: String
    var url: String
    var userAgent: String?
    var uaLabel: String
    var mse: Bool
    var contentMode: Bool
    var locked: Bool
    var cssOnPlay: Bool
    var leanback: Bool = false
    var pinOnly: Bool = false
    var refusal: Bool = false
    var experience: Bool = false
    var nextURL: String? = nil
    var nextVideoID: String? = nil
    var oscilloscope: Bool = false
    var nowPlaying: Bool = false
    var timeoutSeconds: Int = 60
    var provenance: String = ""
    var videoID: String = ""
}

@MainActor
final class PageProbeModel: ObservableObject {
    let controller = ProbeWebController()
    @Published var screenLines: [String] = []
    @Published var verdict: String = ""
    @Published var running = false

    private var spec: PageProbeSpec?
    private var startedAt: Date?
    private var pollCount = 0
    private var lastState: ProbePollState?
    private var lastLean: ProbeLeanbackState?
    private var errStreak = 0
    private var sawPin = false
    private var pinPolls = 0
    private var playingAt: Date?
    private var phase = "idle"
    private var supervisor: Task<Void, Never>?
    private var userToggledPause = false
    private var lastPressAt: Date?
    private var qualitySet = false

    func log(_ tag: String, _ line: String) {
        DiagLog.write(tag, line)
        screenLines.append(line)
        if screenLines.count > 7 { screenLines.removeFirst(screenLines.count - 7) }
    }

    func start(spec: PageProbeSpec) {
        guard self.spec == nil else { return }
        self.spec = spec
        running = true
        startedAt = Date()
        phase = "waiting"
        let tag = spec.tag
        log(tag, "START \(spec.title) — mse=\(spec.mse ? "ON" : "off") "
            + "contentMode=\(spec.contentMode ? "desktop" : "off") "
            + "ua=\(spec.uaLabel) vid=\(spec.videoID) "
            + "signedIn=\(ProbeSession.shared.signedIn)")
        if !ProbeSession.shared.bridgeAvailable {
            finish("KHÔNG — bridge WebKit không khả dụng trên bản tvOS này")
            return
        }
        registerPressConsumer()
        controller.onFinishLoad = { [weak self] in
            guard let self else { return }
            self.log(tag, "load finished")
            Task { await self.readPlayability(context: "load") }
            if spec.oscilloscope {
                self.controller.evaluate(ProbeJS.oscilloscopeInstall)
            }
            self.controller.evaluate(ProbeJS.mediaSessionInstall)
        }
        controller.onFailLoad = { [weak self] msg in
            self?.log(tag, "load FAILED: \(msg)")
            Task { await self?.readPlayability(context: "fail") }
        }
        controller.onTerminated = { [weak self] in
            self?.log(tag, "web content process TERMINATED")
        }
        controller.onExitURL = { [weak self] url in
            self?.log(tag, "page tried to leave the locked URL (host only): \(URL(string: url)?.host ?? "?")")
        }
        controller.load(url: spec.url, userAgent: spec.userAgent,
                        lockedURL: spec.locked ? spec.url : nil)
        if spec.leanback {
            controller.startPolling(js: ProbeJS.leanbackPoll, interval: 2.0)
            controller.onPoll = { [weak self] result in
                self?.handleLeanback(result)
            }
        } else if spec.oscilloscope {
            // The oscilloscope drives its own 500 ms loop.
        } else {
            controller.startPolling(js: ProbeJS.poll, interval: 2.0)
            controller.onPoll = { [weak self] result in
                self?.handlePoll(result)
            }
        }
        supervisor = Task { [weak self] in
            await self?.supervise()
        }
    }

    func stop() {
        supervisor?.cancel()
        supervisor = nil
        JoeWebBridge.setRemotePressConsumer(nil)
        removeNowPlaying()
        controller.stopPoll()
        running = false
    }

    // MARK: Poll handling

    private func handlePoll(_ result: String?) {
        guard let spec, phase != "done" else { return }
        pollCount += 1
        guard let result,
              let data = result.data(using: .utf8),
              let state = try? JSONDecoder().decode(ProbePollState.self, from: data)
        else {
            if pollCount % 10 == 1 { log(spec.tag, "poll \(pollCount): no page yet") }
            return
        }
        lastState = state
        if state.pin == 1 { sawPin = true; pinPolls += 1 }
        if !state.err.isEmpty { errStreak += 1 } else { errStreak = 0 }
        log(spec.tag, "poll \(pollCount) state=\(state.state) api=\(state.api) "
            + "play=\(state.playing ? 1 : 0) t=\(Int(state.t)) d=\(Int(state.d)) "
            + "pin=\(state.pin) vid=\(state.vid.isEmpty ? "-" : state.vid) "
            + "err=\(state.err.isEmpty ? "-" : state.err)")
        if let pressAt = lastPressAt, state.playing || state.paused {
            // Team B-1: press→effect latency, poll-quantised.
            let ms = Int(Date().timeIntervalSince(pressAt) * 1000)
            log(spec.tag, "press→effect observed within \(ms) ms (poll-quantised)")
            lastPressAt = nil
        }
        if state.playing, playingAt == nil {
            playingAt = Date()
            let secs = Date().timeIntervalSince(startedAt ?? Date())
            log(spec.tag, "PLAYING after \(String(format: "%.1f", secs))s — "
                + "vị trí đầu tiên t=\(Int(state.t))s (D-P3/D-P7 đối chiếu tại đây)")
            if spec.cssOnPlay {
                controller.evaluateForResult(ProbeJS.injectWatchmaxCSS) { [weak self] r in
                    self?.log(spec.tag, "watchmax CSS: \(r ?? "nil")")
                }
            }
            if spec.pinOnly {
                finish("ĐẠT — pin/layout chạy (xem các dòng pin ở trên); decode: đang phát")
                return
            }
            if spec.experience {
                phase = "experience"
                Task { await self.runExperience() }
            } else if !spec.refusal {
                finish("ĐẠT — trang phát được")
            }
        }
        if spec.pinOnly, pollCount >= 15 {
            finish(sawPin
                ? "ĐẠT — pin=1 ở \(pinPolls)/\(pollCount) poll (layout khả thi); decode: \(lastState?.playing == true ? "đang phát" : "chưa phát")"
                : "KHÔNG — pin không bao giờ đứng (layout/CSS không qua được trên tvOS WebKit)")
        }
        if spec.refusal {
            if !state.err.isEmpty || errStreak >= 3 {
                Task { await self.readPlayability(context: "refusal") }
                finish("ĐẠT — tín hiệu từ chối đọc được: err='\(state.err)' (xem dòng playability)")
            } else if state.playing {
                finish("KHÔNG — tập Gold phát khi CHƯA đăng nhập (ngoài kỳ vọng)")
            }
        }
    }

    private func handleLeanback(_ result: String?) {
        guard let spec, phase != "done" else { return }
        pollCount += 1
        guard let result,
              let data = result.data(using: .utf8),
              let state = try? JSONDecoder().decode(ProbeLeanbackState.self, from: data)
        else { return }
        let prev = lastLean
        lastLean = state
        if prev == nil || prev?.booted != state.booted
            || prev?.signin != state.signin || prev?.activate != state.activate
            || prev?.playing != state.playing {
            log(spec.tag, "leanback poll \(pollCount) booted=\(state.booted ? 1 : 0) "
                + "signin=\(state.signin ? 1 : 0) activate=\(state.activate ? 1 : 0) "
                + "play=\(state.playing ? 1 : 0) t=\(Int(state.t)) "
                + "title='\(state.title)' err=\(state.err.isEmpty ? "-" : state.err)")
        }
        if state.playing, playingAt == nil {
            playingAt = Date()
            finish("ĐẠT — leanback phát được (signin=\(state.signin ? 1 : 0) activate=\(state.activate ? 1 : 0))")
        }
    }

    private func supervise() async {
        guard let spec else { return }
        let deadline = Date().addingTimeInterval(Double(spec.timeoutSeconds))
        while !Task.isCancelled, phase != "done", Date() < deadline {
            if spec.oscilloscope {
                await oscilloscopeTick()
            }
            try? await Task.sleep(nanoseconds: spec.oscilloscope ? 500_000_000 : 1_000_000_000)
        }
        guard phase != "done", phase != "experience" else { return }
        if spec.leanback {
            let l = lastLean
            finish("KHÔNG — leanback không phát trong \(spec.timeoutSeconds)s "
                + "(booted=\(l?.booted == true ? 1 : 0) signin=\(l?.signin == true ? 1 : 0) "
                + "activate=\(l?.activate == true ? 1 : 0))")
        } else if spec.refusal {
            finish("KHÔNG — không thấy tín hiệu từ chối rõ trong \(spec.timeoutSeconds)s (errStreak=\(errStreak))")
        } else if playingAt == nil {
            await readPlayability(context: "timeout")
            finish("KHÔNG — không phát trong \(spec.timeoutSeconds)s "
                + "(err cuối: \(lastState?.err ?? "-") state=\(lastState?.state ?? -99))")
        }
    }

    /// Team C-1: the 500 ms oscilloscope tick — drains the
    /// SPA-navigation events and the playlist index, and
    /// timestamps the three end signals (element ended /
    /// API state 0 / videoId change) whenever they occur.
    private func oscilloscopeTick() async {
        guard let spec, phase != "done" else { return }
        let result = await evaluateAwait(ProbeJS.pollX)
        guard let result,
              let data = result.data(using: .utf8),
              let state = try? JSONDecoder().decode(ProbePollXState.self, from: data)
        else { return }
        pollCount += 1
        for event in state.osc {
            log(spec.tag, "osc event: \(event) vid=\(state.vid) pidx=\(state.pidx)")
        }
        if state.ended {
            log(spec.tag, "osc END SIGNAL: element/api ended state=\(state.state) "
                + "vid=\(state.vid) t=\(Int(state.t))/\(Int(state.d))")
        }
        if state.playing, playingAt == nil {
            playingAt = Date()
            log(spec.tag, "osc PLAYING vid=\(state.vid) pidx=\(state.pidx) "
                + "qual=\(state.qual) msHandlers=\(state.msPlay)/\(state.msPause)/\(state.msNext)")
            if spec.experience {
                phase = "experience"
                Task { await self.runExperience() }
            }
        }
        if state.dialog == 1 {
            log(spec.tag, "osc STILL-WATCHING dialog detected (B-2)")
            let r = await evaluateAwait(ProbeJS.dismissDialog)
            log(spec.tag, "osc dialog dismiss attempt: \(r ?? "nil")")
        }
    }

    // MARK: Experience phase (owner order 2026-11-20 01:56)

    private func runExperience() async {
        guard let spec else { return }
        let tag = spec.tag
        log(tag, "experience: danh sách tập lấy từ \(spec.provenance)")
        await readPlayability(context: "playing")
        // Team E-P7: set a non-default quality, read back in
        // later pollX reads (and again after NEXT).
        let q = await evaluateAwait(ProbeJS.setQuality1080)
        log(tag, "experience: setPlaybackQualityRange(hd1080) → \(q ?? "nil")")
        qualitySet = q == "set"
        if spec.nowPlaying { publishNowPlaying() }
        // Play/pause through the production mechanism: the
        // same togglePlay evaluate the window press consumer
        // fires for a remote Play/Pause press.
        controller.evaluate(ProbeJS.togglePlay)
        userToggledPause = true
        var pausedSeen = false
        for _ in 0..<4 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let s = await readPollX(), s.paused { pausedSeen = true; break }
        }
        log(tag, "experience: play/pause (togglePlay) → \(pausedSeen ? "tạm dừng OK" : "KHÔNG thấy dừng")")
        controller.evaluate(ProbeJS.togglePlay)
        userToggledPause = false
        var resumedSeen = false
        for _ in 0..<4 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let s = await readPollX(), s.playing { resumedSeen = true; break }
        }
        log(tag, "experience: play/pause (togglePlay lần 2) → \(resumedSeen ? "phát lại OK" : "KHÔNG thấy phát lại")")
        let ppOK = pausedSeen && resumedSeen
        // Ten more seconds of observation: still-watching /
        // pause attribution (Team B-2/B-6) ride the pollX
        // reads.
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let s = await readPollX() {
                if s.dialog == 1 {
                    log(tag, "experience: STILL-WATCHING dialog xuất hiện (B-2)")
                    let r = await evaluateAwait(ProbeJS.dismissDialog)
                    log(tag, "experience: dismiss dialog → \(r ?? "nil")")
                }
                if s.paused && !userToggledPause {
                    log(tag, "experience: page tự dừng — attribution: dialog=\(s.dialog) "
                        + "ad=\(s.ad) vis=\(s.vis) readyState=\(s.rs) state=\(s.state) (B-6)")
                }
                if qualitySet {
                    log(tag, "experience: quality readback = \(s.qual.isEmpty ? "-" : s.qual) (E-P7)")
                    qualitySet = false
                }
            }
        }
        // NEXT: the production shape — load the next
        // episode's watch URL in the same view.
        var nextPart = ""
        if let nextURL = spec.nextURL {
            let t0 = Date()
            log(tag, "experience: QUA TẬP — nạp URL tập tiếp theo")
            controller.load(url: nextURL, userAgent: spec.userAgent,
                            lockedURL: spec.locked ? nextURL : nil)
            var ok = false
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if spec.oscilloscope {
                    if let s = await readPollX(), s.playing,
                       spec.nextVideoID == nil || s.vid == spec.nextVideoID || s.vid.isEmpty {
                        ok = true
                        break
                    }
                } else if let s = lastState, s.playing,
                   spec.nextVideoID == nil || s.vid == spec.nextVideoID || s.vid.isEmpty {
                    ok = true
                    break
                }
            }
            let secs = Date().timeIntervalSince(t0)
            nextPart = ok
                ? " · QUA TẬP ĐẠT \(String(format: "%.1f", secs))s"
                : " · QUA TẬP KHÔNG (30s)"
            log(tag, "experience: qua tập → \(ok ? "ĐẠT" : "KHÔNG") sau \(String(format: "%.1f", secs))s")
            if ok, let s = await readPollX() {
                log(tag, "experience: sau qua tập quality = \(s.qual.isEmpty ? "-" : s.qual) (E-P7)")
            }
        }
        finish("PHÁT ĐẠT · PLAY/PAUSE \(ppOK ? "ĐẠT" : "KHÔNG")\(nextPart)")
    }

    // MARK: Helpers

    private func readPlayability(context: String) async {
        guard let spec else { return }
        let result = await evaluateAwait(ProbeJS.playability)
        guard let result,
              let data = result.data(using: .utf8),
              let p = try? JSONDecoder().decode(ProbePlayability.self, from: data)
        else {
            log(spec.tag, "playability[\(context)]: unreadable")
            return
        }
        log(spec.tag, "playability[\(context)]: status=\(p.status) reason=\(p.reason.isEmpty ? "-" : p.reason)")
    }

    private func readPollX() async -> ProbePollXState? {
        let result = await evaluateAwait(ProbeJS.pollX)
        guard let result,
              let data = result.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(ProbePollXState.self, from: data)
    }

    private func evaluateAwait(_ js: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            controller.evaluateForResult(js) { result in
                cont.resume(returning: result)
            }
        }
    }

    /// The production remote path (window-level consumer →
    /// togglePlay), registered for the probe's lifetime so
    /// the owner's own presses are measured too (Team B-1),
    /// plus the arrow tripwire (Team B-5: arrows are logged
    /// and NOT consumed; the poll stream shows whether the
    /// page also sought).
    private func registerPressConsumer() {
        JoeWebBridge.setRemotePressConsumer { [weak self] pressType in
            MainActor.assumeIsolated {
                guard let self, self.phase != "done" else { return false }
                if pressType == UIPress.PressType.playPause.rawValue
                    || pressType == UIPress.PressType.select.rawValue {
                    self.lastPressAt = Date()
                    self.log(self.spec?.tag ?? "page",
                             "remote press \(pressType == UIPress.PressType.playPause.rawValue ? "PlayPause" : "Select") → togglePlay (đường production)")
                    self.controller.evaluate(ProbeJS.togglePlay)
                    return true
                }
                if pressType == UIPress.PressType.leftArrow.rawValue
                    || pressType == UIPress.PressType.rightArrow.rawValue {
                    self.log(self.spec?.tag ?? "page",
                             "remote press \(pressType == UIPress.PressType.leftArrow.rawValue ? "Left" : "Right") — KHÔNG chặn (B-5 tripwire: xem poll t có nhảy không)")
                    return false
                }
                return false
            }
        }
    }

    // MARK: Team B-3 (SPECULATION): Now Playing piggyback

    private var commandTargets: [Any] = []

    private func publishNowPlaying() {
        guard let spec else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "YT Probe — \(spec.videoID)",
        ]
        let commands = MPRemoteCommandCenter.shared()
        let toggle = commands.togglePlayPauseCommand
        toggle.isEnabled = true
        let target = toggle.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log(self?.spec?.tag ?? "page",
                          "B-3: MPRemoteCommandCenter togglePlayPause ĐÃ GỌI (Now Playing tới được trang)")
                self?.controller.evaluate(ProbeJS.togglePlay)
            }
            return .success
        }
        commandTargets.append(target)
        log(spec.tag, "B-3: đã publish MPNowPlayingInfoCenter + đăng ký remote command (SPECULATION — chờ tín hiệu)")
    }

    private func removeNowPlaying() {
        let commands = MPRemoteCommandCenter.shared()
        for target in commandTargets {
            commands.togglePlayPauseCommand.removeTarget(target)
        }
        commandTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func finish(_ text: String) {
        guard let spec, phase != "done" else { return }
        phase = "done"
        verdict = text
        log(spec.tag, "KẾT QUẢ \(spec.tag): \(text)")
        stop()
    }
}

// MARK: - Generic page-probe screen

struct PageProbeView: View {
    let spec: PageProbeSpec
    let onExit: () -> Void
    @StateObject private var model = PageProbeModel()

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(spec.title)
                        .font(.system(size: 34, weight: .bold))
                    Text(spec.note)
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 900, alignment: .leading)
                }
                Spacer()
                if !model.verdict.isEmpty {
                    Text(model.verdict)
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundStyle(model.verdict.contains("KHÔNG") ? .red : .green)
                        .frame(maxWidth: 700, alignment: .trailing)
                }
            }
            ProbeWebView(controller: model.controller,
                         navigationMode: spec.locked ? .playerLockdown : .doorRoam,
                         playbackPresses: true,
                         mediaSourceSwitch: spec.mse,
                         contentModeDesktop: spec.contentMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.screenLines.enumerated()), id: \.offset) { _, line in
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
        .task { model.start(spec: spec) }
        .onDisappear { model.stop() }
    }
}

// MARK: - Probe 1 — the MSE levers, separately (Audit §1.2 trust conditions)

/// Four cells, each in a FRESH web view: neither lever /
/// private setter only / content-mode only / both. Per cell
/// the log carries all three trust facts: (1) the lever was
/// applied at configuration time (bridge outcome + the
/// selector that accepted it), (2) the getter read-back
/// (outcome distinguishes applied-and-stuck from
/// applied-but-not-stuck), (3) the in-page capability
/// readout in the fresh view.
struct Probe1View: View {
    let onExit: () -> Void
    @StateObject private var model = Probe1Model()

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Probe 1 — Công tắc MSE (4 ô)")
                        .font(.system(size: 34, weight: .bold))
                    Text("Mỗi ô là một web view MỚI: không lever · chỉ setter riêng · chỉ contentMode .desktop · cả hai. Đọc typeof MediaSource + isTypeSupported sau mỗi ô.")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 900, alignment: .leading)
                }
                Spacer()
                if !model.verdict.isEmpty {
                    Text(model.verdict)
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundStyle(model.verdict.contains("KHÔNG") ? .red : .green)
                        .frame(maxWidth: 700, alignment: .trailing)
                }
            }
            ZStack {
                ForEach(0..<4, id: \.self) { idx in
                    if idx == model.cellIndex {
                        ProbeWebView(controller: model.controllers[idx],
                                     navigationMode: .doorRoam,
                                     playbackPresses: false,
                                     mediaSourceSwitch: Probe1Model.cells[idx].mse,
                                     contentModeDesktop: Probe1Model.cells[idx].cm)
                            .id(idx)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(model.results.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 23, weight: .semibold))
                        .lineLimit(2)
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

@MainActor
final class Probe1Model: ObservableObject {
    struct Cell {
        let label: String
        let mse: Bool
        let cm: Bool
    }
    static let cells: [Cell] = [
        Cell(label: "A-không lever", mse: false, cm: false),
        Cell(label: "B-chỉ setter riêng", mse: true, cm: false),
        Cell(label: "C-chỉ contentMode", mse: false, cm: true),
        Cell(label: "D-cả hai", mse: true, cm: true),
    ]
    let controllers: [ProbeWebController] = (0..<4).map { _ in ProbeWebController() }
    @Published var cellIndex = 0
    @Published var results: [String] = []
    @Published var verdict: String = ""
    private var started = false
    private var runTask: Task<Void, Never>?

    func start() {
        guard !started else { return }
        started = true
        DiagLog.write("probe1", "START Probe 1 — 4 ô lever MSE (mỗi ô web view mới)")
        runTask = Task { [weak self] in await self?.run() }
    }

    func stop() { runTask?.cancel() }

    private func run() async {
        var anyMSE = false
        var winning = ""
        for idx in 0..<4 {
            if Task.isCancelled { return }
            cellIndex = idx
            let cell = Self.cells[idx]
            let controller = controllers[idx]
            // The host is created by the SwiftUI view for
            // this cell; wait for it to exist.
            for _ in 0..<20 where controller.host == nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let host = controller.host else {
                DiagLog.write("probe1", "cell \(cell.label): host không xuất hiện")
                continue
            }
            // Trust facts (1)+(2): configuration-time lever
            // outcomes, straight from the bridge.
            let mseOutcome = host.mediaSourceSwitchOutcome
            let selector = host.mediaSourceSelectorUsed
            let cmOutcome = host.contentModeOutcome
            DiagLog.write("probe1", "cell \(cell.label): mseOutcome=\(mseOutcome) "
                + "selector=\(selector.isEmpty ? "-" : selector) cmOutcome=\(cmOutcome) "
                + "(0=không yêu cầu 1=đã áp+đọc lại OK 2=không có 3=áp nhưng không dính)")
            controller.load(url: "about:blank", userAgent: nil, lockedURL: nil)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let result = await withCheckedContinuation {
                (cont: CheckedContinuation<String?, Never>) in
                controller.evaluateForResult(ProbeJS.capability) { r in
                    cont.resume(returning: r)
                }
            }
            var line = "cell \(cell.label): capability không đọc được"
            if let result,
               let data = result.data(using: .utf8),
               let cap = try? JSONDecoder().decode(ProbeCapability.self, from: data) {
                line = "cell \(cell.label): \(cap.summary)"
                DiagLog.write("probe1", line + " ua=\(cap.ua)")
                if cap.ms != "undefined" {
                    anyMSE = true
                    winning = cell.label
                }
            } else {
                DiagLog.write("probe1", line)
            }
            results.append(line)
            controller.stopPoll()
        }
        verdict = anyMSE
            ? "ĐẠT — MediaSource bật được ở ô \(winning)"
            : "KHÔNG — MediaSource vẫn undefined ở cả 4 ô (setter: xem mseOutcome từng ô)"
        DiagLog.write("probe1", "KẾT QUẢ probe1: \(verdict)")
    }
}

// MARK: - Probe 2 family screens (options → run)

/// Probe 2 (desktop page) with its D-P3/D-P7 toggles, and
/// the G-1 / Chrome cells as fixed-spec variants.
struct Probe2View: View {
    let onExit: () -> Void
    @State private var useT = false
    @State private var noList = false
    @State private var started = false

    var body: some View {
        if started {
            PageProbeView(spec: spec, onExit: onExit)
        } else {
            VStack(alignment: .leading, spacing: 26) {
                Text("Probe 2 — Trang desktop (Safari UA + MSE)")
                    .font(.system(size: 38, weight: .bold))
                Text("Đường production: Safari UA, công tắc MSE BẬT, watchmax CSS, poll + pin như JoeTV. Sau khi phát: test play/pause, qua tập, chất lượng, oscilloscope events.")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 1200, alignment: .leading)
                Toggle("D-P3: nạp kèm &t=745 (test vị trí bắt đầu)", isOn: $useT)
                    .font(.system(size: 26))
                    .frame(maxWidth: 900)
                Toggle("D-P7: bỏ &list= khỏi URL", isOn: $noList)
                    .font(.system(size: 26))
                    .frame(maxWidth: 900)
                Button("Bắt đầu Probe 2") { started = true }
                    .font(.system(size: 28, weight: .semibold))
                Spacer()
            }
            .padding(60)
            .onExitCommand { onExit() }
        }
    }

    private var spec: PageProbeSpec {
        var url = ProbeTargets.watchURL(ProbeTargets.freeEp1)
        if noList { url = "https://www.youtube.com/watch?v=\(ProbeTargets.freeEp1)" }
        if useT { url += "&t=745" }
        return PageProbeSpec(
            tag: "probe2", title: "Probe 2 — Trang desktop",
            note: "Safari UA · MSE ON · watchmax · production path",
            url: url, userAgent: ProbeJS.safariUA, uaLabel: "safari-desktop",
            mse: true, contentMode: false, locked: true, cssOnPlay: true,
            experience: true,
            nextURL: ProbeTargets.watchURL(ProbeTargets.freeEp2),
            nextVideoID: ProbeTargets.freeEp2,
            oscilloscope: true, nowPlaying: true,
            provenance: "dữ liệu playlist có sẵn (tvb-yt.json) — trang chỉ là máy phát",
            videoID: ProbeTargets.freeEp1)
    }
}

/// Fixed-spec page probes (menu shortcuts).
enum PageProbeSpecs {
    static func g1Cell() -> PageProbeSpec {
        // Audit G-1: Safari UA with the MSE switch OFF —
        // the behavioural discriminator between the UA
        // theory and the MSE theory.
        PageProbeSpec(
            tag: "probe2b", title: "Probe 2b — Safari UA, MSE TẮT (ô G-1)",
            note: "Cùng trang desktop như Probe 2 nhưng KHÔNG bật công tắc MSE. Nếu ô này phát được thì UA là cửa; nếu không, MSE là cửa.",
            url: ProbeTargets.watchURL(ProbeTargets.freeEp1),
            userAgent: ProbeJS.safariUA, uaLabel: "safari-desktop",
            mse: false, contentMode: false, locked: true, cssOnPlay: true,
            experience: true,
            nextURL: ProbeTargets.watchURL(ProbeTargets.freeEp2),
            nextVideoID: ProbeTargets.freeEp2,
            provenance: "dữ liệu playlist có sẵn (tvb-yt.json)",
            videoID: ProbeTargets.freeEp1)
    }

    static func chromeCell() -> PageProbeSpec {
        // Audit §4.4 (nice-to-have): the Sony-proven
        // Chrome-profile payload with the switch ON.
        PageProbeSpec(
            tag: "probe2c", title: "Probe 2c — Chrome UA, MSE BẬT",
            note: "UA Chrome/Windows như bản 2.0.41 đã dùng, nhưng công tắc MSE BẬT — kiểm tra cặp Chrome+MSE và layout watchmax kiểu Sony.",
            url: ProbeTargets.watchURL(ProbeTargets.freeEp1),
            userAgent: ProbeJS.desktopChromeUA, uaLabel: "chrome-desktop",
            mse: true, contentMode: false, locked: true, cssOnPlay: true,
            experience: true,
            nextURL: ProbeTargets.watchURL(ProbeTargets.freeEp2),
            nextVideoID: ProbeTargets.freeEp2,
            provenance: "dữ liệu playlist có sẵn (tvb-yt.json)",
            videoID: ProbeTargets.freeEp1)
    }

    static func mobile() -> PageProbeSpec {
        // Probe 6: m.youtube.com with an explicit iPhone
        // Safari UA (the identity the practitioner evidence
        // says is served the HLS player; 2.0.41's surface 2
        // used the default UA and never tried it).
        PageProbeSpec(
            tag: "probe6", title: "Probe 6 — Trang mobile (iPhone UA)",
            note: "m.youtube.com với UA iPhone Safari tường minh — đường HLS native nếu có. MSE cũng thử bật (ghi log), poll 60s.",
            url: ProbeTargets.mobileWatchURL(ProbeTargets.freeEp1),
            userAgent: ProbeJS.mobileUA, uaLabel: "iphone-safari",
            mse: true, contentMode: false, locked: true, cssOnPlay: false,
            experience: true,
            nextURL: ProbeTargets.mobileWatchURL(ProbeTargets.freeEp2),
            nextVideoID: ProbeTargets.freeEp2,
            provenance: "dữ liệu playlist có sẵn (tvb-yt.json)",
            videoID: ProbeTargets.freeEp1)
    }

    static func leanback() -> PageProbeSpec {
        // Probe 5: youtube.com/tv — log boot, sign-in /
        // activation demand, and whether a video plays; the
        // deep link aims at the fixed free episode.
        PageProbeSpec(
            tag: "probe5", title: "Probe 5 — Leanback (youtube.com/tv)",
            note: "Trang TV chính thức của YouTube. Ghi: có boot không, có đòi đăng nhập/kích hoạt không, có phát được video không.",
            url: "https://www.youtube.com/tv#/watch?v=\(ProbeTargets.freeEp1)",
            userAgent: ProbeJS.safariUA, uaLabel: "safari-desktop",
            mse: true, contentMode: false, locked: false, cssOnPlay: false,
            leanback: true,
            provenance: "trang tự điều hướng (không dùng dữ liệu của app)",
            videoID: ProbeTargets.freeEp1)
    }

    static func pinStandalone() -> PageProbeSpec {
        // Team E-P2: the pin check alone — watchmax
        // geometry vs decode, separated.
        PageProbeSpec(
            tag: "probeE2", title: "Probe E-P2 — Kiểm tra pin độc lập",
            note: "Chỉ đo hình học watchmax (pin=1?) tách khỏi decode. pin đứng mà không phát = lỗi ở media stack, không phải CSS.",
            url: ProbeTargets.watchURL(ProbeTargets.freeEp1),
            userAgent: ProbeJS.safariUA, uaLabel: "safari-desktop",
            mse: true, contentMode: false, locked: true, cssOnPlay: true,
            pinOnly: true, timeoutSeconds: 40,
            provenance: "không áp dụng",
            videoID: ProbeTargets.freeEp1)
    }

    static func goldRefusal() -> PageProbeSpec {
        // Team E-P6: signed-OUT members episode — does the
        // page expose the same .ytp-error contract?
        PageProbeSpec(
            tag: "probeE6", title: "Probe E-P6 — Từ chối Gold khi chưa đăng nhập",
            note: "Mở tập Gold (Bang Phái Phong Vân 1) KHI CHƯA đăng nhập, 30s: tín hiệu từ chối (.ytp-error / playabilityStatus) có đọc được không — đây là tín hiệu mà Auto-fallback của production dựa vào.",
            url: ProbeTargets.goldWatchURL(ProbeTargets.goldEp1),
            userAgent: ProbeJS.safariUA, uaLabel: "safari-desktop",
            mse: true, contentMode: false, locked: true, cssOnPlay: false,
            refusal: true, timeoutSeconds: 35,
            provenance: "không áp dụng",
            videoID: ProbeTargets.goldEp1)
    }

    static func goldWatch() -> PageProbeSpec {
        // Audit G-2: THE production Gold path — after the
        // door sign-in, a Gold episode's WATCH PAGE through
        // surfaces/poll/pin, full experience phase.
        PageProbeSpec(
            tag: "probe11", title: "Probe 11 — Trang Gold sau đăng nhập (G-2)",
            note: "Đường Gold THẬT của production: chạy SAU Probe 4 (đã đăng nhập). Trang watch của Bang Phái Phong Vân tập 1, Safari UA + MSE, đủ bộ poll/pin/play-pause/qua tập.",
            url: ProbeTargets.goldWatchURL(ProbeTargets.goldEp1),
            userAgent: ProbeJS.safariUA, uaLabel: "safari-desktop",
            mse: true, contentMode: false, locked: true, cssOnPlay: true,
            experience: true,
            provenance: "dữ liệu playlist có sẵn (tvb-yt.json)",
            videoID: ProbeTargets.goldEp1)
    }

    static func embed() -> PageProbeSpec {
        // Probe 8 (demoted per Audit 2 §4.2 — last and
        // optional): the signed-in embed.
        PageProbeSpec(
            tag: "probe8", title: "Probe 8 — Embed sau đăng nhập (tùy chọn, cuối)",
            note: "IFrame embed của tập Gold trong web view dùng chung kho cookie với cửa đăng nhập. Audit đã hạ cấp probe này: embed gần như chắc chắn chết — chạy cuối, chỉ để đóng hồ sơ.",
            url: ProbeTargets.embedURL(ProbeTargets.goldEp1),
            userAgent: ProbeJS.safariUA, uaLabel: "safari-desktop",
            mse: true, contentMode: false, locked: false, cssOnPlay: false,
            timeoutSeconds: 45,
            provenance: "không áp dụng",
            videoID: ProbeTargets.goldEp1)
    }
}

// MARK: - Team E-P4 — poll cost

/// What does a Sony-shaped 2 s poll cost on the Apple TV?
/// Measures evaluate round-trips for the fat poll vs a
/// thin state-only read.
struct PollCostView: View {
    let onExit: () -> Void
    @StateObject private var model = PollCostModel()

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Probe E-P4 — Chi phí poll")
                        .font(.system(size: 34, weight: .bold))
                    Text("Đo thời gian khứ hồi của poll ĐẦY ĐỦ (kiểu Sony, 2s) so với poll GỌN (chỉ state, 1s) trên đúng trang watch này.")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 900, alignment: .leading)
                }
                Spacer()
                if !model.verdict.isEmpty {
                    Text(model.verdict)
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(.green)
                        .frame(maxWidth: 700, alignment: .trailing)
                }
            }
            ProbeWebView(controller: model.controller,
                         navigationMode: .playerLockdown,
                         playbackPresses: true,
                         mediaSourceSwitch: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.screenLines.enumerated()), id: \.offset) { _, line in
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

@MainActor
final class PollCostModel: ObservableObject {
    let controller = ProbeWebController()
    @Published var screenLines: [String] = []
    @Published var verdict: String = ""
    private var task: Task<Void, Never>?
    private var started = false

    private func log(_ line: String) {
        DiagLog.write("probeE4", line)
        screenLines.append(line)
        if screenLines.count > 7 { screenLines.removeFirst(screenLines.count - 7) }
    }

    func start() {
        guard !started else { return }
        started = true
        log("START E-P4 — nạp trang watch, chờ 6s rồi đo")
        controller.load(url: ProbeTargets.watchURL(ProbeTargets.freeEp1),
                        userAgent: ProbeJS.safariUA,
                        lockedURL: ProbeTargets.watchURL(ProbeTargets.freeEp1))
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await self?.measure()
        }
    }

    func stop() { task?.cancel() }

    private func measure() async {
        let thin = "(function(){ var p = document.getElementById('movie_player'); "
            + "try { return p && p.getPlayerState ? String(p.getPlayerState()) : 'x'; } "
            + "catch (e) { return 'x'; } })()"
        var fat: [Int] = []
        var slim: [Int] = []
        for i in 0..<15 {
            if Task.isCancelled { return }
            let t0 = Date()
            _ = await eval(ProbeJS.poll)
            fat.append(Int(Date().timeIntervalSince(t0) * 1000))
            try? await Task.sleep(nanoseconds: 500_000_000)
            if i % 5 == 4 { log("poll đầy đủ \(i + 1)/15: \(fat.last ?? 0) ms") }
        }
        for i in 0..<15 {
            if Task.isCancelled { return }
            let t0 = Date()
            _ = await eval(thin)
            slim.append(Int(Date().timeIntervalSince(t0) * 1000))
            try? await Task.sleep(nanoseconds: 500_000_000)
            if i % 5 == 4 { log("poll gọn \(i + 1)/15: \(slim.last ?? 0) ms") }
        }
        let fatAvg = fat.reduce(0, +) / max(fat.count, 1)
        let slimAvg = slim.reduce(0, +) / max(slim.count, 1)
        verdict = "ĐẠT — poll đầy đủ TB \(fatAvg) ms · poll gọn TB \(slimAvg) ms"
        log("KẾT QUẢ probeE4: \(verdict) (fat max \(fat.max() ?? 0) ms, thin max \(slim.max() ?? 0) ms)")
    }

    private func eval(_ js: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            controller.evaluateForResult(js) { r in cont.resume(returning: r) }
        }
    }
}

// MARK: - Team C-3 — page-as-oracle hybrid (SPECULATIVE)
//
// A muted page plays the &list= URL purely as an ORDER
// ORACLE while the native player produces the actual
// picture/sound from the extraction route. The log records
// whether the oracle stays in list context (vid sequence +
// playlist index) — the design question is whether the
// page can be trusted as the advance oracle for Gold.

struct OracleView: View {
    let onExit: () -> Void
    @StateObject private var model = OracleModel()

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Probe C-3 — Oracle lai (SPECULATIVE)")
                        .font(.system(size: 34, weight: .bold))
                    Text("Trang (tắt tiếng) chạy ngầm làm 'oracle' thứ tự tập; trình phát native (trích xuất) cho hình/tiếng thật. Log ghi oracle có giữ list context không.")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 900, alignment: .leading)
                }
                Spacer()
                Text(model.statusLine)
                    .font(.system(size: 24, weight: .semibold))
                    .frame(maxWidth: 640, alignment: .trailing)
            }
            HStack(spacing: 20) {
                NativePlayerView(player: model.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                ProbeWebView(controller: model.controller,
                             navigationMode: .playerLockdown,
                             playbackPresses: false,
                             mediaSourceSwitch: true)
                    .frame(maxWidth: 700, maxHeight: .infinity)
                    .background(Color.black)
            }
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

@MainActor
final class OracleModel: ObservableObject {
    let controller = ProbeWebController()
    let player = AVQueuePlayer()
    @Published var lines: [String] = []
    @Published var statusLine = ""
    private var started = false
    private var task: Task<Void, Never>?

    private func log(_ line: String) {
        DiagLog.write("probeC3", line)
        lines.append(line)
        if lines.count > 6 { lines.removeFirst(lines.count - 6) }
    }

    func start() {
        guard !started else { return }
        started = true
        log("START C-3 oracle — native phát tập 1 (VISIONOS), trang oracle nạp cùng URL &list=")
        // Native leg: extraction resolve + play.
        Task {
            let clients = await ProbeClientLadder.load().clients
            guard let visionos = clients.first(where: { $0.name == "VISIONOS" }) else { return }
            let resolver = ProbeResolver()
            let outcome = await resolver.resolve(videoID: ProbeTargets.freeEp1, client: visionos)
            if let url = resolver.playableURL {
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                player.play()
                log("oracle: native đang phát (resolve status=\(outcome.status))")
            } else {
                log("oracle: native resolve THẤT BẠI status=\(outcome.status)")
            }
        }
        // Oracle leg: the page, muted.
        controller.onFinishLoad = { [weak self] in
            self?.controller.evaluate("""
                (function(){ var v = document.querySelector('video');
                  if (v) { v.muted = true; v.play(); return 'muted'; } return 'novideo'; })()
                """)
        }
        controller.load(url: ProbeTargets.watchURL(ProbeTargets.freeEp1),
                        userAgent: ProbeJS.safariUA,
                        lockedURL: ProbeTargets.watchURL(ProbeTargets.freeEp1))
        controller.startPolling(js: ProbeJS.pollX, interval: 2.0)
        controller.onPoll = { [weak self] result in
            guard let self,
                  let result,
                  let data = result.data(using: .utf8),
                  let state = try? JSONDecoder().decode(ProbePollXState.self, from: data)
            else { return }
            let inList = ProbeTargets.freeEpisodes.contains(state.vid)
            self.statusLine = "oracle vid=\(state.vid.isEmpty ? "-" : state.vid) "
                + "pidx=\(state.pidx) list=\(inList ? "YES" : "NO") "
                + "play=\(state.playing ? 1 : 0)"
            if state.playing || state.pidx >= 0 {
                self.log("oracle poll: vid=\(state.vid) pidx=\(state.pidx) "
                    + "listContext=\(inList ? "YES" : "NO") t=\(Int(state.t)) native-t=\(Int(self.player.currentTime().seconds))")
            }
        }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            self?.log("KẾT QUẢ probeC3: oracle giữ list context qua các poll ở trên — đối chiếu vid/pidx từng dòng")
        }
    }

    func stop() {
        task?.cancel()
        player.pause()
        controller.stopPoll()
        JoeWebBridge.setRemotePressConsumer(nil)
    }
}
