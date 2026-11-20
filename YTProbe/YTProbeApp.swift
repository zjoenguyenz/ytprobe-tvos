import SwiftUI

// MARK: - YT Probe — the standalone mechanism harness
//
// Owner strategy (2026-11-20 01:52 CST): no unproven
// mechanism goes into JoeTV. This app proves or kills each
// YouTube mechanism on the owner's own tvOS 27.2.1, one
// probe at a time, with the DiagLog as the product: he runs
// probes by hand and exports the log; every verdict must be
// recoverable from the log alone.
//
// The log export control lives HERE, on the main screen,
// always visible (owner order 2026-11-20 02:02): the LAN
// address + one-time PIN, the established JoeTV pattern
// (tvOS has no share sheet).

@main
struct YTProbeApp: App {
    var body: some Scene {
        WindowGroup {
            ProbeRootView()
        }
    }
}

private enum ProbeRoute: Identifiable {
    case probe1, probe2, probe2b, probe2c, probe6, probe5
    case pin, extract, device9, door4, gold11, refusal
    case oracle, botguard, pollCost, embed

    var id: String {
        switch self {
        case .probe1: return "p1"
        case .probe2: return "p2"
        case .probe2b: return "p2b"
        case .probe2c: return "p2c"
        case .probe6: return "p6"
        case .probe5: return "p5"
        case .pin: return "pin"
        case .extract: return "extract"
        case .device9: return "device9"
        case .door4: return "door4"
        case .gold11: return "gold11"
        case .refusal: return "refusal"
        case .oracle: return "oracle"
        case .botguard: return "botguard"
        case .pollCost: return "pollcost"
        case .embed: return "embed"
        }
    }
}

struct ProbeRootView: View {
    @State private var route: ProbeRoute?
    @State private var server = DiagLogServer()
    @State private var serverLine = "Kênh log: đang mở…"
    @State private var serverURL = ""

    var body: some View {
        ZStack {
            if let route {
                probeView(route)
            } else {
                menu
            }
        }
        .task {
            DiagLog.logLaunchPresence()
            DiagLog.write("probe", "YT Probe mở — menu chính, kênh log đang mở trên màn hình chính")
            server.onStateChange = { state in
                switch state {
                case .starting:
                    serverLine = "Kênh log: đang mở…"
                case .serving(let url):
                    serverURL = url
                    serverLine = "Kênh log: ĐANG CHẠY"
                case .failed(let message):
                    serverLine = "Kênh log: \(message)"
                }
            }
            server.start()
        }
    }

    // MARK: Main menu + the always-visible log block

    private var menu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                Text("YT Probe — thử cơ chế YouTube cho Joe TV")
                    .font(.system(size: 44, weight: .heavy))
                logBlock
                group("NHÓM QUYẾT ĐỊNH — chạy trước", [
                    (.probe1, "Probe 1 · Công tắc MSE (4 ô lever)"),
                    (.extract, "Probe 3+7 · Trích xuất — ma trận client + phát native"),
                    (.device9, "Probe 9 · Device-code + TVHTML5 Gold"),
                    (.door4, "Probe 4 · Cửa đăng nhập Gold"),
                    (.gold11, "Probe 11 · Trang Gold sau đăng nhập (G-2)"),
                ])
                group("NHÓM TRANG PHIM", [
                    (.probe2, "Probe 2 · Trang desktop (Safari UA + MSE)"),
                    (.probe2b, "Probe 2b · Safari UA, MSE TẮT (ô G-1)"),
                    (.probe2c, "Probe 2c · Chrome UA + MSE"),
                    (.probe6, "Probe 6 · Trang mobile (iPhone UA)"),
                    (.probe5, "Probe 5 · Leanback youtube.com/tv"),
                    (.pin, "Probe E-P2 · Kiểm tra pin độc lập"),
                    (.refusal, "Probe E-P6 · Từ chối Gold khi chưa đăng nhập"),
                ])
                group("NHÓM NÂNG CAO", [
                    (.oracle, "Probe C-3 · Oracle lai (SPECULATIVE)"),
                    (.botguard, "Probe 10 · BotGuard minting (SPECULATIVE)"),
                    (.pollCost, "Probe E-P4 · Chi phí poll"),
                    (.embed, "Probe 8 · Embed sau đăng nhập (cuối, tùy chọn)"),
                ])
            }
            .padding(60)
        }
    }

    private var logBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LOG CHẨN ĐOÁN — sản phẩm chính của app này")
                .font(.system(size: 28, weight: .bold))
            Text(serverLine)
                .font(.system(size: 24))
                .foregroundStyle(serverURL.isEmpty ? Color.secondary : Color.green)
            if !serverURL.isEmpty {
                Text(serverURL)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                Text("Mở địa chỉ này trên iPhone (cùng Wi-Fi nhà) để tải file log về gửi cho em. Mã PIN nằm ngay trong địa chỉ. Chạy xong probe nào thì tải log luôn cũng được — log ghi liên tục.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 1200, alignment: .leading)
            }
        }
        .padding(26)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func group(_ title: String,
                       _ items: [(ProbeRoute, String)]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.secondary)
            ForEach(items, id: \.0.id) { item in
                Button(item.1) { route = item.0 }
                    .font(.system(size: 28, weight: .semibold))
            }
        }
    }

    @ViewBuilder
    private func probeView(_ route: ProbeRoute) -> some View {
        let exit = { self.route = nil }
        switch route {
        case .probe1: Probe1View(onExit: exit)
        case .probe2: Probe2View(onExit: exit)
        case .probe2b: PageProbeView(spec: PageProbeSpecs.g1Cell(), onExit: exit)
        case .probe2c: PageProbeView(spec: PageProbeSpecs.chromeCell(), onExit: exit)
        case .probe6: PageProbeView(spec: PageProbeSpecs.mobile(), onExit: exit)
        case .probe5: PageProbeView(spec: PageProbeSpecs.leanback(), onExit: exit)
        case .pin: PageProbeView(spec: PageProbeSpecs.pinStandalone(), onExit: exit)
        case .extract: ExtractView(onExit: exit)
        case .device9: DeviceCodeView(onExit: exit)
        case .door4: ProbeDoorView(onExit: exit)
        case .gold11: PageProbeView(spec: PageProbeSpecs.goldWatch(), onExit: exit)
        case .refusal: PageProbeView(spec: PageProbeSpecs.goldRefusal(), onExit: exit)
        case .oracle: OracleView(onExit: exit)
        case .botguard: BotGuardView(onExit: exit)
        case .pollCost: PollCostView(onExit: exit)
        case .embed: PageProbeView(spec: PageProbeSpecs.embed(), onExit: exit)
        }
    }
}
