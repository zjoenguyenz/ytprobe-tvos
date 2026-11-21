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
//   (BOTH REMOVED in 0.2.8 — FL-365, see the last bullet)
// - the challenge page's candidate-control DOM inventory
//   (values-free) captured into the log the moment the
//   challenge step appears (Audit requirement)
// - Team E-P3: session-presence reads at load-finish
//   +0 ms / +700 ms / +2 s, so a stale-read lag — if tvOS
//   has one — is measured, not assumed
// - native email/password fields exactly as the production
//   door (the owner signs in himself; values are never
//   logged or stored; the password field clears on fill)
// - the 2SV chooser mechanism (0.1.3): after 'Try another
//   way', a FRESH clickable-row inventory is taken + logged
//   and the detected verification rows (Tap Yes /
//   authenticator / SMS — the 0.1.1 device run proved this
//   account's chooser has NO password row) become native
//   buttons; a row click starts a 120 s step watch
//   (transitions only), and a native code field appears if
//   a code input shows. Codes are never logged — the log
//   records the code's LENGTH only
// - 0.1.4 deltas (from the full 0.1.3 device log): the
//   chooser scan ALSO runs at the challenge step itself
//   (the challenge list carries an SMS row — "Get a
//   verification code at …12" — that the post-expansion
//   list no longer shows), buttons are built from the
//   UNION of all scans, and the legacy password-method
//   retry loop is silenced once a chooser inventory has
//   been captured. The row click is v2: it walks up from
//   the text match to the element Google's handler
//   listens on and fires a full press sequence, with one
//   retry on the row's first interactive descendant
//   (the retry leg was REMOVED in 0.2.8 — FL-365)
// - 0.2.8 (FL-365): ALL auto-drive at the verification /
//   challenge step is DISABLED. The 0.2.7 door burned
//   Google's failed-attempt budget and tripped a
//   temporary account lock (diag_16): 'Try another way'
//   was JS-clicked three times in one session, the Tap
//   Yes click retried itself blind after 3 s, and the
//   password-method loop clicked on a timer. From 0.2.8:
//   no auto-click of 'Try another way' (the native button
//   is gone — the owner taps the control in the page
//   itself), no password-method retry loop, no chooser
//   retry leg, and a chooser-row click fires ONLY after
//   a FRESH inventory scan confirms that row is on the
//   page right now — otherwise nothing is clicked and
//   the stale button removes itself. An unrecognised
//   page STOPS the automation: control stays with the
//   owner and the WebView stays visible and tappable.
//   Automatic sign-in attempts in this door = 0; every
//   attempt is the owner's own tap.

/// One detected row of Google's 2-Step Verification
/// chooser. `needles` are tried in order for the JS click;
/// `avoid` excludes a look-alike row (the authenticator
/// row's own text also mentions "verification code", so an
/// SMS click must skip it).
struct ChooserRow: Identifiable {
    enum Kind { case tapYes, authenticator, sms }
    let kind: Kind
    let label: String
    let needles: [String]
    let avoid: String
    var id: String { label }
}

@MainActor
final class ProbeDoorModel: ObservableObject {
    let controller = ProbeWebController()
    @Published var fieldKind = "none"
    @Published var verdict: String = ""
    @Published var lines: [String] = []
    @Published var chooserRows: [ChooserRow] = []
    @Published var codeInputPresent = false
    private var started = false
    private var lastStep = ""
    private var challengeInventoried = false
    private var chooserWatchTask: Task<Void, Never>?
    private var lastChooserStep = ""
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
            + "0.2.8: KHÔNG tự lái ở bước xác minh (FL-365) — mỗi lượt thử là "
            + "một cú bấm của anh; focus chỉ quan sát)")
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
            // 0.2.8 (FL-365): the password-method retry
            // loop that used to run here — auto-clicking
            // the password method on this 2 s tick, up to
            // 6 tries — is REMOVED. The tick now only
            // observes the step; it never clicks anything.
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
        // 0.1.4: scan the chooser rows HERE too — the
        // challenge-step list itself carries methods (the
        // SMS row) that the expanded post-'Try another way'
        // list no longer shows. Buttons accumulate as the
        // UNION of every scan (see detectChooserRows).
        scanChooser(afterSeconds: 1.5, allowRetry: false)
    }

    // 0.2.8 (FL-365): clickTryAnotherWay() is REMOVED —
    // the door never JS-clicks 'Try another way'. In
    // 0.2.7 that click fired three times in one session
    // and each one counted as a fresh attempt in Google's
    // eyes. The owner taps 'Try another way' in the page
    // itself (the WebView below stays visible and
    // tappable); the chooser scan still runs at the
    // challenge step so the rows the page offers become
    // native buttons.

    /// After 'Try another way', Google's 2-Step Verification
    /// chooser lists the methods THIS account actually has
    /// (device-proven 2026-11-20: NO password row — Tap Yes /
    /// authenticator / SMS instead). Take a FRESH inventory
    /// of the clickable rows (visible text only, no values),
    /// log it, and surface one native button per detected
    /// row for the owner to choose from.
    private func scanChooser(afterSeconds seconds: Double, allowRetry: Bool) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self else { return }
            let json = await self.evaluateAwait(ProbeJS.chooserRows)
            let rows = self.detectChooserRows(fromJSON: json)
            if rows.isEmpty, allowRetry {
                self.log("door: chưa nhận diện được hàng 2SV nào — quét lại sau 3s")
                self.scanChooser(afterSeconds: 3.0, allowRetry: false)
            }
        }
    }

    private func detectChooserRows(fromJSON json: String?) -> [ChooserRow] {
        guard let json, let data = json.data(using: .utf8),
              let texts = try? JSONDecoder().decode([String].self, from: data)
        else {
            // Union semantics (0.1.4): a failed scan must not
            // wipe buttons an earlier scan already built.
            log("door: chooser inventory: không đọc được — giữ nguyên các nút đã có")
            return []
        }
        log("door: chooser inventory (\(texts.count) hàng bấm được): "
            + texts.joined(separator: " | "))
        let lowered = texts.map { $0.lowercased() }
        var rows: [ChooserRow] = []
        if lowered.contains(where: { $0.contains("tap yes") }) {
            rows.append(ChooserRow(kind: .tapYes,
                                   label: "Chạm Yes trên điện thoại",
                                   needles: ["Tap Yes"], avoid: ""))
        }
        if lowered.contains(where: { $0.contains("authenticator") }) {
            rows.append(ChooserRow(kind: .authenticator,
                                   label: "Mã Authenticator",
                                   needles: ["authenticator"], avoid: ""))
        }
        // SMS: the challenge-step list phrases it "Get a
        // verification code at (•••) •••-••12" (0.1.3 device
        // log) — "verification code at" cannot be the
        // authenticator row ("…code from the Google
        // Authenticator app"). The older phrasings stay as
        // fallback; the authenticator row also contains
        // "verification code", so it stays excluded there.
        let smsHit = lowered.contains { $0.contains("verification code at") }
            || lowered.contains { text in
                (text.contains("text message") || text.contains("verification code"))
                    && !text.contains("authenticator")
            }
        if smsHit {
            rows.append(ChooserRow(kind: .sms, label: "Mã SMS",
                                   needles: ["verification code at",
                                             "text message", "verification code"],
                                   avoid: "authenticator"))
        }
        log(rows.isEmpty
            ? "door: KHÔNG nhận diện được hàng 2SV nào trong inventory này "
                + "— DỪNG tự lái ở bước xác minh (0.2.8/FL-365): app không "
                + "bấm gì thêm; anh thao tác trực tiếp trong trang WebView"
            : "door: inventory này nhận diện \(rows.count) hàng 2SV: "
                + rows.map(\.label).joined(separator: ", "))
        // UNION merge: rows found by ANY scan (challenge
        // step or post-expansion) keep their native button,
        // even when a later list no longer shows them.
        for row in rows where !chooserRows.contains(where: { $0.kind == row.kind }) {
            chooserRows.append(row)
        }
        if !rows.isEmpty {
            log("door: tổng hợp các nút 2SV hiện có (\(chooserRows.count)): "
                + chooserRows.map(\.label).joined(separator: ", "))
        }
        return rows
    }

    /// Owner tapped one of the detected chooser rows: JS-
    /// click it by visible text, then watch the page step
    /// (transitions only) for up to ~120 s. The 0.1.4 click
    /// v2 walks up from the text match to the element
    /// Google's handler listens on and fires a full press
    /// sequence.
    ///
    /// 0.2.8 (FL-365): the click fires ONLY when a FRESH
    /// inventory scan — taken at this moment, not the
    /// union of older scans — confirms the row is on the
    /// page right now. A row the fresh scan no longer
    /// sees is NOT clicked (in 0.2.7 such stale buttons
    /// kept firing at rows that had left the screen), and
    /// its button removes itself. The click also no
    /// longer schedules any retry: one owner tap = at
    /// most one click, ever.
    func clickChooser(_ row: ChooserRow) {
        codeInputPresent = false
        Task { [weak self] in
            guard let self else { return }
            let freshJSON = await self.evaluateAwait(ProbeJS.chooserRows)
            let freshRows = self.detectChooserRows(fromJSON: freshJSON)
            guard freshRows.contains(where: { $0.kind == row.kind }) else {
                self.log("door: hàng 2SV '\(row.label)' KHÔNG còn trên trang "
                    + "(quét tươi ngay lúc bấm không thấy) — KHÔNG bấm; nút tự "
                    + "gỡ. Anh thao tác trực tiếp trong trang WebView")
                self.chooserRows.removeAll { $0.kind == row.kind }
                return
            }
            var outcome = "notfound"
            var clicked = false
            for needle in row.needles {
                let r = await self.evaluateAwait(
                    ProbeJS.clickChooserRow(needle: needle, avoid: row.avoid))
                guard let r else { continue }
                let info = Self.parseClickReport(r)
                if info.outcome == "clicked" {
                    outcome = "clicked (needle='\(needle)', target=\(info.target))"
                    clicked = true
                    break
                }
            }
            self.log("door: click hàng 2SV '\(row.label)' → \(outcome)")
            if clicked {
                self.startChooserWatch()
            }
        }
    }

    /// Parse a chooser click payload's JSON report into
    /// (outcome, target description). The description is
    /// values-free by construction: tag name, role,
    /// jsaction presence, and the qualifier that selected
    /// the target — never page text.
    private static func parseClickReport(_ json: String)
        -> (outcome: String, target: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outcome = obj["outcome"] as? String
        else { return (json, "-") }
        let tag = obj["tag"] as? String ?? "?"
        let role = obj["role"] as? String ?? "-"
        let js = (obj["jsaction"] as? Bool) == true ? "1" : "0"
        let qual = obj["qual"] as? String ?? "-"
        return (outcome, "\(tag) role=\(role) jsaction=\(js) qual=\(qual)")
    }

    // 0.2.8 (FL-365): scheduleChooserRetry is REMOVED.
    // In 0.2.7 it re-clicked the Tap Yes row ~3 s after
    // the owner's tap when the step had not moved — a
    // second attempt Google counted against the account
    // while its prompt never reached the phone. A click
    // in this door is never retried by the app; if a tap
    // did not take, the owner decides what happens next.

    private func startChooserWatch() {
        chooserWatchTask?.cancel()
        lastChooserStep = ""
        log("door: [chooser-watch] bắt đầu — poll bước mỗi 2s, tối đa 120s, chỉ ghi chuyển bước")
        chooserWatchTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(120)
            while !Task.isCancelled, Date() < deadline {
                let raw = await self.evaluateAwait(ProbeJS.chooserStep) ?? "unreadable"
                let mapped = Self.mapChooserStep(raw)
                if mapped != self.lastChooserStep {
                    self.log("door: [chooser-watch] bước "
                        + "\(self.lastChooserStep.isEmpty ? "(đầu)" : self.lastChooserStep) → \(mapped)")
                    self.lastChooserStep = mapped
                }
                if raw == "code-input", !self.codeInputPresent {
                    self.codeInputPresent = true
                    self.log("door: [chooser-watch] ô nhập mã ĐÃ HIỆN — điền ở ô 'Mã xác minh' bên dưới")
                }
                if raw == "signed-in" {
                    self.codeInputPresent = false
                    self.log("door: [chooser-watch] ĐÃ QUA — trang đã rời accounts.google.com")
                    break
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            if !Task.isCancelled {
                self.log("door: [chooser-watch] dừng — bước cuối: \(self.lastChooserStep)")
            }
        }
    }

    private static func mapChooserStep(_ raw: String) -> String {
        if raw.hasPrefix("error:") {
            return "error-class: " + String(raw.dropFirst("error:".count))
        }
        switch raw {
        case "prompt": return "prompt-waiting"
        case "code-input": return "code-input-present"
        case "signed-in": return "signed-in"
        default: return raw
        }
    }

    /// Fill the 2SV code from the native field (same pattern
    /// as email/password: the value goes to the page only;
    /// the log records its LENGTH, never the code), then
    /// JS-click the page's Next/Verify button matched by
    /// text and log which label matched.
    func fillCode(_ code: String) {
        controller.evaluateForResult(ProbeJS.fillCodeValue(code)) { [weak self] result in
            self?.log("door: code filled len=\(code.count) → \(result ?? "nil")")
            guard result == "filled" else { return }
            self?.controller.evaluateForResult(ProbeJS.clickNextVerify) { [weak self] r in
                self?.log("door: click Next/Verify sau khi điền mã → \(r ?? "nil")")
            }
        }
    }

    private func evaluateAwait(_ js: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            controller.evaluateForResult(js) { result in
                cont.resume(returning: result)
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
    @State private var codeText = ""
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
                    Text(model.fieldKind == "challenge"
                        ? "Trang đang ở bước thử thách — bản 0.2.8 KHÔNG tự bấm gì ở bước này (FL-365): 'Try another way' anh tự bấm trong trang; các cách xác minh trang thật sự có sẽ hiện thành nút bên dưới, và mỗi nút chỉ bấm khi hàng còn hiện trên trang."
                        : "Tới bước thử thách, app không tự lái (0.2.8/FL-365) — anh thao tác trực tiếp trong trang.")
                        .font(.system(size: 21))
                        .foregroundStyle(.secondary)
                    Button("Thử focus vào trang (quan sát)") { model.focusPage() }
                        .font(.system(size: 22))
                }
                if !model.chooserRows.isEmpty {
                    HStack(spacing: 14) {
                        Text("Trang mời chọn cách xác minh — bấm đúng cách anh muốn dùng:")
                            .font(.system(size: 21))
                            .foregroundStyle(.secondary)
                        ForEach(model.chooserRows) { row in
                            Button(row.label) { model.clickChooser(row) }
                                .font(.system(size: 24, weight: .bold))
                        }
                    }
                }
                if model.codeInputPresent {
                    HStack(spacing: 14) {
                        TextField("Mã xác minh", text: $codeText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 24))
                            .frame(maxWidth: 380)
                        Button("Điền mã") {
                            let value = codeText
                            codeText = ""
                            model.fillCode(value)
                        }
                        .disabled(codeText.isEmpty)
                        Text("Mã chỉ điền vào trang — log chỉ ghi độ dài mã, không ghi mã.")
                            .font(.system(size: 21))
                            .foregroundStyle(.secondary)
                    }
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

// MARK: - Probe 4 chooser payloads (0.1.3, click v2 in 0.1.4)
//
// The 2SV chooser mechanism the 0.1.1 device run proved
// missing: after 'Try another way', the account's chooser
// has NO password row — it lists Tap Yes / authenticator /
// SMS. These payloads inventory the rows, click one by
// visible text, classify the follow-up step, and fill a
// verification code. Page VALUES are never returned: the
// code goes in one-way, and only its length is logged
// (Swift side).
//
// Click v2 (0.1.4): the 0.1.3 run logged 'clicked' on
// every row yet the page never left the chooser — the
// bare .click() landed on the shortest text-matching
// element, the text shell, not the node Google's handler
// listens on. V2 walks UP from the match to the first
// ancestor carrying jsaction / role link|button / a
// data-challengeid|data-method|data-value attribute (an
// A or BUTTON qualifies too), then fires a full press
// sequence (pointerdown → mousedown → pointerup →
// mouseup → click) at the target's centre. The payload
// reports the chosen target values-free (tag, role,
// jsaction presence, qualifier) as JSON.

extension ProbeJS {
    /// Single-quote a Swift string as a JS string literal
    /// (the same escaping the fill payloads' helper uses).
    private static func doorLiteral(_ value: String) -> String {
        var out = "'"
        for ch in value {
            switch ch {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out + "'"
    }

    /// FRESH inventory of the clickable rows only: visible
    /// text, whitespace-collapsed, deduplicated, capped.
    /// No values — labels are public page UI.
    static let chooserRows = """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var out = [];
          var seen = {};
          var cands = document.querySelectorAll('a, button, [role="button"], [role="link"], [role="listitem"], li');
          for (var i = 0; i < cands.length && out.length < 30; i++) {
            var t = (cands[i].innerText || cands[i].textContent || '').trim().replace(/\\s+/g, ' ');
            if (t && t.length <= 120 && vis(cands[i]) && !seen[t]) {
              seen[t] = 1;
              out.push(t);
            }
          }
          return JSON.stringify(out);
        })()
        """

    /// Click v2: locate the chooser row whose visible
    /// text CONTAINS the needle (shortest matching visible
    /// element wins; rows containing `avoid` are skipped),
    /// walk UP from it (max 6 levels) to the first element
    /// carrying jsaction / role link|button / a
    /// data-challengeid|data-method|data-value attribute
    /// (tag A or BUTTON qualifies; fallback = the match
    /// itself), scroll it to centre, and dispatch the
    /// full press sequence at its centre point. Returns a
    /// values-free JSON report:
    /// {"outcome":"clicked","tag":…,"role":…,
    ///  "jsaction":…,"qual":…} / {"outcome":"notfound"}.
    static func clickChooserRow(needle: String, avoid: String) -> String {
        """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var needle = \(doorLiteral(needle)).toLowerCase();
          var avoid = \(doorLiteral(avoid)).toLowerCase();
          var cands = document.querySelectorAll('a, button, [role="button"], [role="link"], [role="listitem"], li, div');
          var best = null;
          var bestLen = 100000;
          for (var i = 0; i < cands.length; i++) {
            var t = (cands[i].innerText || cands[i].textContent || '').trim().replace(/\\s+/g, ' ');
            if (!t || t.length > 300) { continue; }
            var low = t.toLowerCase();
            if (low.indexOf(needle) < 0) { continue; }
            if (avoid && low.indexOf(avoid) >= 0) { continue; }
            if (!vis(cands[i])) { continue; }
            if (t.length < bestLen) { best = cands[i]; bestLen = t.length; }
          }
          if (!best) { return JSON.stringify({outcome: 'notfound'}); }
          function qualifier(el) {
            if (el.hasAttribute && el.hasAttribute('jsaction')) { return 'jsaction'; }
            var role = el.getAttribute ? (el.getAttribute('role') || '') : '';
            if (role === 'link' || role === 'button') { return 'role'; }
            if (el.hasAttribute && (el.hasAttribute('data-challengeid')
                || el.hasAttribute('data-method')
                || el.hasAttribute('data-value'))) { return 'data'; }
            if (el.tagName === 'A' || el.tagName === 'BUTTON') { return 'tag'; }
            return '';
          }
          var target = null;
          var qual = '';
          var el = best;
          for (var level = 0; el && level <= 6; level++) {
            var q = qualifier(el);
            if (q) { target = el; qual = q; break; }
            el = el.parentElement;
          }
          if (!target) { target = best; qual = 'self'; }
          target.scrollIntoView({block: 'center'});
          var rect = target.getBoundingClientRect();
          var cx = rect.left + rect.width / 2;
          var cy = rect.top + rect.height / 2;
          function fire(type) {
            var Ctor = (type.indexOf('pointer') === 0 && window.PointerEvent)
              ? window.PointerEvent : window.MouseEvent;
            target.dispatchEvent(new Ctor(type,
              {bubbles: true, cancelable: true, clientX: cx, clientY: cy}));
          }
          fire('pointerdown');
          fire('mousedown');
          fire('pointerup');
          fire('mouseup');
          fire('click');
          var role = target.getAttribute ? (target.getAttribute('role') || '-') : '-';
          return JSON.stringify({outcome: 'clicked',
            tag: target.tagName || '?', role: role,
            jsaction: !!(target.hasAttribute && target.hasAttribute('jsaction')),
            qual: qual});
        })()
        """
    }

    // 0.2.8 (FL-365): the clickChooserRowRetry payload is
    // REMOVED with its only caller (scheduleChooserRetry).
    // The door never re-clicks a chooser row on its own.

    /// The post-click step classifier for the chooser
    /// watch: 'signed-in' (the page left
    /// accounts.google.com) / 'error:<ui text>' /
    /// 'code-input' / 'prompt' (the Tap Yes phone prompt)
    /// / 'other'. Error text is public UI text, never a
    /// field value.
    static let chooserStep = """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          if (location.href.indexOf('accounts.google.com') < 0) { return 'signed-in'; }
          var alerts = document.querySelectorAll('[role="alert"], .o6cuMc');
          for (var i = 0; i < alerts.length; i++) {
            var at = (alerts[i].innerText || alerts[i].textContent || '').trim().replace(/\\s+/g, ' ');
            if (at && vis(alerts[i])) { return 'error:' + at.slice(0, 80); }
          }
          var code = document.querySelector('input[type="tel"], input[autocomplete="one-time-code"], input[name="idvPin"], input[name="code"], input[inputmode="numeric"]');
          if (vis(code)) { return 'code-input'; }
          var txt = ((document.body && document.body.innerText) || '').toLowerCase();
          if (txt.indexOf('check your phone') >= 0
              || txt.indexOf('kiểm tra điện thoại') >= 0) { return 'prompt'; }
          return 'other';
        })()
        """

    /// Fill the 2SV code input (native value setter +
    /// input/change events, the fillField pattern). The
    /// code is interpolated one-way; the payload returns
    /// only 'filled' / 'nofield'.
    static func fillCodeValue(_ code: String) -> String {
        """
        (function(){
          var el = document.querySelector('input[type="tel"], input[autocomplete="one-time-code"], input[name="idvPin"], input[name="code"], input[inputmode="numeric"]');
          if (!el) { return 'nofield'; }
          el.focus();
          var setter = Object.getOwnPropertyDescriptor(
            window.HTMLInputElement.prototype, 'value').set;
          setter.call(el, \(doorLiteral(code)));
          el.dispatchEvent(new Event('input', {bubbles: true}));
          el.dispatchEvent(new Event('change', {bubbles: true}));
          return 'filled';
        })()
        """
    }

    /// Click the code page's Next/Verify button, matched by
    /// visible text first (the matched label rides back in
    /// the result), then the known 2SV Next container ids.
    /// Returns 'clicked:<label>' / 'clicked:#idvNext' /
    /// 'notfound'.
    static let clickNextVerify = """
        (function(){
          function vis(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var wanted = ['next', 'verify', 'continue', 'tiếp theo', 'xác minh', 'tiếp tục'];
          var cands = document.querySelectorAll('button, [role="button"]');
          for (var i = 0; i < cands.length; i++) {
            var t = (cands[i].innerText || cands[i].textContent || '').trim().replace(/\\s+/g, ' ').toLowerCase();
            if (wanted.indexOf(t) >= 0 && vis(cands[i])) {
              cands[i].click();
              return 'clicked:' + t;
            }
          }
          var box = document.querySelector('#idvPrnNext button, #idvNext button, #idvPrnNext, #idvNext');
          if (box && vis(box)) { box.click(); return 'clicked:#idvNext'; }
          return 'notfound';
        })()
        """
}
