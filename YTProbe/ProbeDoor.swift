import SwiftUI

// MARK: - Probe 4 — the sign-in door replica
//
// JoeTV's door, copied, plus the probe deltas:
// - capability masking ON/OFF (document-start, door-scoped)
// - focus handover as OBSERVATION ONLY (Audit F-2: the JS
//   click is the primary steering mechanism; focus is
//   logged, never given a pass criterion)
// - the step probe incl. 'challenge' (D-2), with every
//   transition logged
// - the "Dùng mật khẩu thay thế" JS-click button (D-3 /
//   Option A) + the follow-up password-method click
// - the challenge page's candidate-control DOM inventory
//   (values-free) captured into the log the moment the
//   challenge step appears (Audit requirement)
// - Team E-P3: session-presence reads at load-finish
//   +0 ms / +700 ms / +2 s, so a stale-read lag — if tvOS
//   has one — is measured, not assumed
// - native email/password fields exactly as the production
//   door (the owner signs in himself; values are never
//   logged or stored; the password field clears on fill)

@MainActor
final class ProbeDoorModel: ObservableObject {
    let controller = ProbeWebController()
    @Published var fieldKind = "none"
    @Published var verdict: String = ""
    @Published var lines: [String] = []
    private var started = false
    private var lastStep = ""
    private var challengeInventoried = false
    private var passwordMethodArmed = false
    private var passwordMethodTries = 0
    var masking: Bool = true

    func log(_ line: String) {
        DiagLog.write("probe4", line)
        lines.append(line)
        if lines.count > 6 { lines.removeFirst(lines.count - 6) }
    }

    func start() {
        guard !started else { return }
        started = true
        log("START Probe 4 — cửa đăng nhập (masking=\(masking ? "ON" : "off"), "
            + "cơ chế lái CHÍNH = JS-click; focus chỉ quan sát)")
        controller.onFinishLoad = { [weak self] in
            guard let self else { return }
            self.log("door: load finished — đọc phiên tại +0ms/+700ms/+2s (E-P3)")
            Task {
                // E-P3: the stale-read timing series.
                let t0 = await ProbeSession.shared.fetchPresencePublic()
                self.log("E-P3 presence tại +0ms: \(t0)")
                try? await Task.sleep(nanoseconds: 700_000_000)
                let t1 = await ProbeSession.shared.fetchPresencePublic()
                self.log("E-P3 presence tại +700ms: \(t1)")
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                let t2 = await ProbeSession.shared.fetchPresencePublic()
                self.log("E-P3 presence tại +2s: \(t2)")
                await ProbeSession.shared.refresh()
            }
        }
        Task {
            await ProbeSession.shared.ensureSession()
            if masking {
                controller.installDocumentStartScript(ProbeJS.masking)
                log("door: capability masking ĐÃ cài (document-start, chỉ trong cửa này)")
            } else {
                log("door: masking TẮT (chạy đối chứng)")
            }
            controller.load(
                url: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fwww.youtube.com%2F%40TVB_Vietnam",
                userAgent: ProbeJS.safariUA, lockedURL: nil)
        }
    }

    /// The door's 2 s loop tick (driven by the view's task).
    func tick() {
        controller.evaluateForResult(ProbeJS.doorProbe) { [weak self] result in
            guard let self, let result else { return }
            if result != self.lastStep {
                self.log("door: bước chuyển \(self.lastStep.isEmpty ? "?" : self.lastStep) → \(result)")
                self.lastStep = result
                self.fieldKind = result
                if result == "challenge" {
                    self.onChallenge()
                }
            }
            if self.passwordMethodArmed, result != "password",
               self.passwordMethodTries < 6 {
                self.passwordMethodTries += 1
                self.controller.evaluateForResult(ProbeJS.clickPasswordMethod) { [weak self] r in
                    self?.log("door: click phương thức mật khẩu (lần \(self?.passwordMethodTries ?? 0)): \(r ?? "nil")")
                    if r == "clicked" { self?.passwordMethodArmed = false }
                }
            }
        }
    }

    private func onChallenge() {
        log("door: CHALLENGE — chụp DOM inventory (không giá trị) để xây payload production")
        controller.evaluateForResult(ProbeJS.domInventory) { [weak self] result in
            self?.log("door: DOM inventory: \(result ?? "unreadable")")
        }
        if !challengeInventoried {
            challengeInventoried = true
        }
    }

    func clickTryAnotherWay() {
        log("door: bấm nút 'Dùng mật khẩu thay thế' → JS-click 'Try another way'")
        controller.evaluateForResult(ProbeJS.clickTryAnotherWay) { [weak self] result in
            self?.log("door: click Try another way → \(result ?? "nil")")
            if result == "clicked" {
                self?.passwordMethodArmed = true
                self?.passwordMethodTries = 0
            }
        }
    }

    func fillEmail(_ email: String) {
        controller.evaluate(ProbeJS.fillIdentifier(email))
        log("door: đã điền email từ ô native")
    }

    func fillPassword(_ password: String) {
        controller.evaluate(ProbeJS.fillPassword(password))
        log("door: đã điền mật khẩu từ ô native")
    }

    func focusPage() {
        controller.focusPage()
        log("door: focusContent đã gọi (QUAN SÁT — anh thử bấm ↓/Select trong trang; ghi nhận được gì xảy ra)")
    }

    func markSignedIn() {
        verdict = "ĐẠT — đăng nhập xong; phiên đã lưu (Probe 11/9 dùng được)"
        log("KẾT QUẢ probe4: \(verdict)")
        Task { await ProbeSession.shared.mirrorNow() }
    }
}

struct ProbeDoorView: View {
    let onExit: () -> Void
    @ObservedObject private var session = ProbeSession.shared
    @StateObject private var model = ProbeDoorModel()
    @State private var maskingOn = true
    @State private var emailText = ""
    @State private var passwordText = ""
    @State private var doorStarted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Probe 4 — Cửa đăng nhập Gold")
                        .font(.system(size: 36, weight: .bold))
                    Text(session.signedIn
                        ? "✓ ĐÃ ĐĂNG NHẬP — phiên đã sẵn cho Probe 11 (trang Gold) và Probe 9."
                        : "○ Chưa đăng nhập — bước trang hiện tại: \(model.fieldKind)")
                        .font(.system(size: 24))
                        .foregroundStyle(session.signedIn ? Color.green : Color.secondary)
                }
                Spacer()
                if !model.verdict.isEmpty {
                    Text(model.verdict)
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(.green)
                        .frame(maxWidth: 620, alignment: .trailing)
                }
            }
            if !doorStarted {
                HStack(spacing: 18) {
                    Toggle("Capability masking (che WebAuthn)", isOn: $maskingOn)
                        .font(.system(size: 24))
                        .frame(maxWidth: 640)
                    Button("Mở cửa đăng nhập") {
                        model.masking = maskingOn
                        doorStarted = true
                        model.start()
                    }
                    .font(.system(size: 26, weight: .semibold))
                }
            } else {
                HStack(spacing: 14) {
                    TextField("Email Google", text: $emailText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 24))
                        .frame(maxWidth: 460)
                    Button("Điền email & Tiếp tục") { model.fillEmail(emailText) }
                        .disabled(emailText.isEmpty || model.fieldKind != "email")
                    SecureField("Mật khẩu", text: $passwordText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 24))
                        .frame(maxWidth: 380)
                    Button("Điền mật khẩu & Đăng nhập") {
                        let value = passwordText
                        passwordText = ""
                        model.fillPassword(value)
                    }
                    .disabled(passwordText.isEmpty || model.fieldKind != "password")
                }
                .font(.system(size: 22))
                HStack(spacing: 14) {
                    Button("Dùng mật khẩu thay thế") { model.clickTryAnotherWay() }
                        .font(.system(size: 24, weight: .bold))
                        .disabled(model.fieldKind != "challenge")
                    Text(model.fieldKind == "challenge"
                        ? "Trang đang ở bước thử thách (passkey) — bấm nút này để app JS-click 'Try another way' → chọn mật khẩu."
                        : "Nút này sáng khi trang tới bước thử thách.")
                        .font(.system(size: 21))
                        .foregroundStyle(.secondary)
                    Button("Thử focus vào trang (quan sát)") { model.focusPage() }
                        .font(.system(size: 22))
                }
                ProbeWebView(controller: model.controller,
                             navigationMode: .doorRoam,
                             playbackPresses: false,
                             pageFocus: true)
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
            Spacer(minLength: 0)
        }
        .padding(50)
        .onExitCommand { onExit() }
        .task {
            while !Task.isCancelled {
                if doorStarted {
                    model.tick()
                    await session.refresh()
                    if session.signedIn, model.verdict.isEmpty {
                        model.markSignedIn()
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
