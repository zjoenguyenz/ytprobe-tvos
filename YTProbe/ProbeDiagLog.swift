import Foundation
import Network

/// v2.0.33 — rolling diagnostic log + LAN export (audit item 6).
///
/// WHY this exists: the owner tests on a real Apple TV and
/// cannot pull logs off it — tvOS gives an app no share sheet,
/// no activity view and no file exporter (Apple's HIG states
/// activity views are not supported on tvOS, and
/// UIActivityViewController / ShareLink / fileExporter are all
/// unavailable on the platform), so the usual "share the log"
/// routes do not even compile here. The route that works is
/// the one this file builds: the app keeps a small rolling log
/// in its own sandbox (below), and when the owner opens
/// Settings → "Gửi log chẩn đoán" a tiny HTTP server
/// (DiagLogServer, bottom of this file) serves that one file
/// over the home LAN; Settings shows the address in large type
/// plus a QR code of it, and the owner downloads the .txt in
/// Safari on his iPhone and sends it into the chat.
///
/// WHAT may be written: short, factual breadcrumbs from the
/// load / playback / settings paths. NEVER a credential value
/// and never a full URL: debrid tokens ride inside Torrentio /
/// MediaFusion URLs, so write() scrubs a message in three
/// passes before the line touches disk — URLs of any scheme
/// or case reduce to scheme://host, scheme-less Torrentio
/// config bases are erased whole, and every credential VALUE
/// in force is erased wherever it appears in any shape
/// (defence in depth — callers are expected to log ids and
/// outcomes, not links, but the scrubber means a careless
/// caller still cannot leak a token through this file). The
/// one deliberate credential-adjacent line is
/// logLaunchPresence(): presence + length ONLY, by design, so
/// a fault report can distinguish "token never arrived" from
/// "token present but the service rejected it" without the
/// log itself becoming a secret.
enum DiagLog {

    // MARK: - Storage

    /// The log's directory: Application Support (created if
    /// needed), falling back to Caches if Application Support
    /// is unavailable. Resolved ONCE — `static let`
    /// initialisation is thread-safe by the runtime's own
    /// guarantee, so no caller ever races the creation.
    private static let storageDirectory: URL = {
        let fm = FileManager.default
        if let base = try? fm.url(for: .applicationSupportDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil, create: true) {
            try? fm.createDirectory(at: base,
                                    withIntermediateDirectories: true)
            return base
        }
        if let base = try? fm.url(for: .cachesDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil, create: true) {
            try? fm.createDirectory(at: base,
                                    withIntermediateDirectories: true)
            return base
        }
        return fm.temporaryDirectory
    }()

    /// The log file itself: Application Support/ytprobe-diag.log.
    static var fileURL: URL {
        storageDirectory.appendingPathComponent("ytprobe-diag.log")
    }

    // MARK: - Serialisation state
    //
    // Every mutable value below is touched ONLY while `lock`
    // is held. NSLock is Sendable, and the `let` statics are
    // immutable references, so the enum is safe to call
    // from ANY thread or actor — URLSession delegate queues
    // and @MainActor view code alike.
    // Swift 6: nonisolated(unsafe) on the two `var` statics —
    // writeCounter is read and written only inside write()'s
    // locked body, and didLogLaunchPresence is flipped only
    // inside logLaunchPresence()'s locked prologue (released
    // BEFORE it calls write(), which takes the same
    // non-recursive lock itself). The access pattern is
    // deliberately synchronous (DiagLog.write is called from
    // hot sync paths and delegate callbacks), so actor
    // isolation would change every call site's signature;
    // the lock discipline is the safety argument, exactly as
    // with SourceHealth's statics.

    private static let lock = NSLock()
    private nonisolated(unsafe) static var writeCounter = 0
    private nonisolated(unsafe) static var didLogLaunchPresence = false

    /// Bounded size: the file is capped at 1 MB; on rotation
    /// the newest ~700 KB are kept (see rotateIfNeededLocked).
    private static let sizeCap = 1_000_000
    private static let rotationKeepBytes = 700_000

    /// The URL scrubber's pattern: a whole URL run — no
    /// whitespace, no quotes (a quoted URL in a message ends
    /// at its closing quote, which must survive). v2.0.40
    /// (audit P0.3 / H-2): case-insensitive and stremio:// is
    /// a scrubbed scheme too — the app itself accepts
    /// stremio:// MediaFusion links, and an engine error
    /// string may spell a scheme in capitals; the old
    /// lowercase-http(s)-only pattern let both shapes through
    /// with their token-carrying paths intact.
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:https?|stremio)://[^\s"']+"#)

    /// A scheme-less Torrentio config base: a run carrying
    /// realdebrid= / torbox= / premiumize= segments with no
    /// scheme in front of it (the shape a bare base or an
    /// engine error takes). Erased whole — host included —
    /// because the run's path IS the credential.
    private static let configBaseRegex = try! NSRegularExpression(
        pattern: #"(?i)[^\s"']*(?:realdebrid|torbox|premiumize)=[^\s"']*"#)

    // MARK: - Writing

    /// Append ONE line: `[yyyy-MM-dd HH:mm:ss.SSS] [category]
    /// message`. The message is URL-scrubbed first (see the
    /// file header) and flattened to a single line, so one
    /// write is always exactly one log line.
    static func write(_ category: String, _ message: String) {
        let clean = scrubbed(message)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let line = "[\(timestamp())] [\(category)] \(clean)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        appendLocked(data)
        writeCounter += 1
        if writeCounter % 64 == 0 {
            rotateIfNeededLocked()
        }
    }

    /// The file's full current contents ("" when absent or
    /// unreadable) — the export server's body source.
    static func currentText() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Append under the lock: create the file on first use,
    /// then write at its end through a file handle. Failures
    /// are silent by design — a diagnostic log must never be
    /// able to break the feature it is observing.
    private static func appendLocked(_ data: Data) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// Rotation, called under the lock every 64 writes: when
    /// the file is over the cap, drop from the front up to the
    /// first newline AFTER (size − keepBytes) — so the kept
    /// tail starts on a whole line — and prepend a marker
    /// saying the older lines are gone. The newest content is
    /// always kept; the file can only exceed the cap between
    /// two checks by at most 63 lines.
    private static func rotateIfNeededLocked() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > sizeCap,
              let data = try? Data(contentsOf: fileURL),
              data.count > rotationKeepBytes
        else { return }
        let threshold = data.count - rotationKeepBytes
        var start = data.count
        if let newline = data[threshold...].firstIndex(of: 0x0A) {
            start = newline + 1
        }
        let marker = "[\(timestamp())] [diag] log rotated — older lines dropped\n"
        var rotated = Data(marker.utf8)
        if start < data.count {
            rotated.append(data[start...])
        }
        try? rotated.write(to: fileURL)
    }

    // MARK: - Formatting + redaction

    /// One line's timestamp prefix. A fresh DateFormatter per
    /// call: formatters are not thread-safe, writes are rare,
    /// and this keeps the formatter entirely out of the
    /// shared-state story above.
    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    /// Scrub a message in three passes (v2.0.40, audit
    /// P0.3 / H-2):
    /// 1. Every URL (any case; http / https / stremio)
    ///    reduces to scheme://host — paths and queries are
    ///    exactly where debrid tokens live (Torrentio config
    ///    segments, MediaFusion's minted link), so they never
    ///    reach disk. A match URLComponents cannot parse at
    ///    all becomes "[url]".
    /// 2. A scheme-less Torrentio config base (a run carrying
    ///    realdebrid= / torbox= / premiumize= with no scheme)
    ///    is erased whole.
    /// 3. Value pass: every credential value currently in
    ///    force is erased wherever it appears, in any shape —
    ///    this is the pass that catches a bare token inside an
    ///    engine/FFmpeg error string, the one source whose
    ///    wording the app does not control.
    /// Matches are replaced back-to-front so the earlier
    /// ranges stay valid while the string mutates.
    private static func scrubbed(_ message: String) -> String {
        var result = message
        let full = NSRange(location: 0,
                           length: (result as NSString).length)
        for match in urlRegex.matches(in: result, range: full).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let raw = String(result[range])
            if let comps = URLComponents(string: raw),
               let scheme = comps.scheme, let host = comps.host {
                result.replaceSubrange(range, with: "\(scheme)://\(host)")
            } else {
                result.replaceSubrange(range, with: "[url]")
            }
        }
        let rest = NSRange(location: 0,
                           length: (result as NSString).length)
        for match in configBaseRegex.matches(in: result,
                                             range: rest).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "[redacted]")
        }
        for secret in secretValues() {
            result = result.replacingOccurrences(of: secret,
                                                 with: "[redacted]")
        }
        return result
    }

    /// Every credential value in force (stored or bundled),
    /// longest first so a longer value is erased before any
    /// shorter value it contains. Gathered fresh on every
    /// scrub: log writes are breadcrumbs, not a hot loop, and
    /// a cached list would go stale the moment the owner
    /// rotates a token mid-session. Values under 8 characters
    /// are skipped — too short to be a credential, too likely
    /// to be an innocent substring of ordinary text. Every
    /// URL-shaped value is ALSO listed scheme-stripped: an
    /// engine error may carry a link as a bare host/path
    /// fragment with no scheme in front of it, and the
    /// literal value pass can only erase a string it is
    /// given verbatim (review, F-R1-1).
    private static func secretValues() -> [String] {
        // YT PROBE adaptation: the probe app holds NO
        // credentials of its own (the only secret-adjacent
        // state is the YouTube session cookie jar, whose
        // values are never read into Swift at all — presence
        // only, via the session probe). The literal-value
        // pass therefore has an empty list; passes 1 and 2
        // (URL collapse + scheme-less config-base erasure)
        // still run on every line exactly as in JoeTV.
        let raw: [String?] = []
        var seen = Set<String>()
        var out: [String] = []
        for value in raw {
            let v = (value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard v.count >= 8, seen.insert(v).inserted else { continue }
            out.append(v)
        }
        // Scheme-stripped twins of the URL-shaped values (see
        // the header note): same floor, same dedupe; the
        // final sort puts every longer form ahead of any
        // shorter value it contains.
        let originals = out
        for v in originals {
            for scheme in ["https://", "http://", "stremio://"] {
                guard v.lowercased().hasPrefix(scheme) else { continue }
                let stripped = String(v.dropFirst(scheme.count))
                if stripped.count >= 8, seen.insert(stripped).inserted {
                    out.append(stripped)
                }
                break
            }
        }
        return out.sorted { $0.count > $1.count }
    }

    // MARK: - Launch presence (audit item 6)

    /// ONE settings line per process, recording for every
    /// stored credential its PRESENCE + LENGTH ONLY — never a
    /// value (see the file header for why). A session header
    /// line (app build + system version) is written first.
    /// The once-per-process guard is the lock-protected
    /// `didLogLaunchPresence` flag; the flag is flipped under
    /// the lock and released BEFORE the writes, because write()
    /// takes the same (non-recursive) lock itself.
    static func logLaunchPresence() {
        lock.lock()
        if didLogLaunchPresence {
            lock.unlock()
            return
        }
        didLogLaunchPresence = true
        lock.unlock()

        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        // Foundation's ProcessInfo, not UIDevice: this
        // function is nonisolated (any caller may log the
        // launch line), and the version triple is all the
        // session header needs — no UIKit dependency rides
        // along for it.
        let os = ProcessInfo.processInfo.operatingSystemVersion
        write("diag", "session start app=\(short)/\(build) "
              + "system=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")

        // YT PROBE adaptation: no credential presence lines
        // (the app stores nothing of the owner's); the
        // session header above is the whole launch record,
        // plus whether the runtime WebKit bridge resolved.
        write("diag", "probe session header written (no credentials held by this app)")
    }
}

// MARK: - LAN export server (v2.0.33)

/// The tiny HTTP server behind Settings → "Gửi log chẩn
/// đoán": while the export screen is open it serves
/// DiagLog's file at http://<Apple-TV-LAN-IP>:18080/log, as a
/// download named ytprobe-diag.txt. It exists only for the
/// export screen's lifetime (the view starts it on appear
/// and stops it on disappear) and serves nothing else.
///
/// v2.0.40 (audit P0.2 / H-1): the request must carry a
/// ONE-TIME PIN — a random 4-digit code minted at every
/// start(), shown on the export screen and carried in the
/// address the screen displays (…/log?pin=NNNN, or an
/// X-Diag-Pin header). The log file is token-free by
/// DiagLog's scrubber, but it still holds viewing history,
/// hosts and seek positions, and the old server handed it
/// to ANY device on the LAN that knocked. Three wrong codes
/// stop the server for 60 seconds.
///
/// Swift 6: the server is @MainActor — the listener, the
/// live-connection table and the state callback are touched
/// ONLY on the main actor. Network.framework handlers are
/// @Sendable closures running on the server's private serial
/// queue; each one captures only Sendable values (the
/// listener / connection) plus a weak self, and hops straight
/// back with Task { @MainActor in } before touching any
/// state, so the class needs no unchecked Sendable
/// conformance and no unsafe isolation opt-outs. The
/// listener and every connection
/// are STARTED on that serial queue, which is where their
/// bytes are received; the (≤1 MB, already in memory) reply
/// is assembled and sent from the main actor hop.
@MainActor
final class DiagLogServer {

    enum State {
        case starting
        case serving(url: String)
        case failed(String)
    }

    /// State observer — set by the export view before start().
    /// Always invoked on the main actor (see emit).
    var onStateChange: ((State) -> Void)?

    /// The queue the listener and its connections run on.
    private let queue = DispatchQueue(label: "joetv.diaglog.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// The one-time PIN for this serving session (v2.0.40,
    /// P0.2): minted fresh by every start() that creates a
    /// listener, shown on the export screen, and required on
    /// every request. Read by the view to display it.
    private(set) var pin = ""
    /// Consecutive wrong-PIN requests since the last success.
    private var failedAttempts = 0
    /// After 3 consecutive wrong PINs the server refuses to
    /// start until this instant (the 60-second lockout).
    /// STATIC on purpose (review round 3, R3-1): this server
    /// instance is owned by LogExportView's @State, and the
    /// full-screen cover destroys that state on dismiss — an
    /// instance lockout would die with the screen, and the
    /// failure message itself tells the owner to close and
    /// reopen it. The deadline must live at class level so
    /// the promised 60-second pause survives the only
    /// restart path that exists; reopening inside the window
    /// reports .failed, reopening after it serves with a
    /// fresh PIN. Main-actor isolation comes from the class.
    private static var lockoutUntil: Date?

    /// Start serving on port 18080. Idempotent while a
    /// listener is alive. Reports .starting immediately, then
    /// .serving / .failed from the listener's own state.
    func start() {
        if let until = Self.lockoutUntil, until > Date() {
            emit(.failed("Kênh gửi log đang tạm dừng sau 3 lần nhập sai mã PIN — chờ khoảng 1 phút rồi mở lại màn hình này."))
            return
        }
        guard listener == nil else { return }
        pin = String(format: "%04d", Int.random(in: 0...9999))
        failedAttempts = 0
        emit(.starting)
        guard let port = NWEndpoint.Port(rawValue: 18080) else {
            emit(.failed("Không mở được kênh gửi log (cổng không hợp lệ)."))
            return
        }
        let created: NWListener
        do {
            created = try NWListener(using: NWParameters.tcp, on: port)
        } catch {
            emit(.failed("Không mở được kênh gửi log: \(error.localizedDescription)"))
            return
        }
        listener = created
        created.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.listenerStateChanged(state, listener: created)
            }
        }
        created.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in
                self?.accept(conn)
            }
        }
        created.start(queue: queue)
    }

    /// Cancel the listener and every live connection. The
    /// export view calls this on disappear/dismiss, so the
    /// server never outlives its screen.
    func stop() {
        listener?.cancel()
        listener = nil
        for conn in connections.values { conn.cancel() }
        connections.removeAll()
    }

    // MARK: - Listener / connection handling (main actor)

    private func listenerStateChanged(_ state: NWListener.State,
                                      listener: NWListener) {
        switch state {
        case .ready:
            guard let ip = Self.lanIPAddress(), let port = listener.port else {
                emit(.failed("Không tìm thấy địa chỉ mạng nội bộ"))
                return
            }
            emit(.serving(url: "http://\(ip):\(port.rawValue)/log?pin=\(pin)"))
        case .failed(let error):
            if self.listener === listener { self.listener = nil }
            emit(.failed("Kênh gửi log lỗi: \(error.localizedDescription)"))
        case .cancelled:
            if self.listener === listener { self.listener = nil }
        default:
            break
        }
    }

    /// Accept one connection: register it (so stop() can
    /// cancel it), start it on the server queue, and read ONE
    /// bounded request (8192 bytes is far more than a Safari
    /// request line + headers). Only the PIN is read from the
    /// request (v2.0.40, P0.2 — see handle); the path itself
    /// is not routed on. A client that connects and never
    /// sends is reaped by stop() when the screen closes.
    private func accept(_ conn: NWConnection) {
        connections[ObjectIdentifier(conn)] = conn
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, _, _ in
            Task { @MainActor in
                self?.handle(conn, requestData: data ?? Data())
            }
        }
    }

    /// The PIN gate (v2.0.40, P0.2 / H-1): a request carrying
    /// this session's PIN gets the log and resets the failure
    /// count; any other request gets a 403 and counts. The
    /// third consecutive failure stops the server for 60
    /// seconds (lockoutUntil) — the offending connection
    /// still receives its 403 before the listener goes down.
    /// A connection that closed without sending a single byte
    /// never made a request at all, so it is NOT a wrong-PIN
    /// attempt and never counts: a LAN port scan or a browser
    /// preconnect must not be able to lock the owner out of
    /// his own export (review round 2, F-1).
    private func handle(_ conn: NWConnection, requestData: Data) {
        guard !requestData.isEmpty else {
            conn.cancel()
            connections.removeValue(forKey: ObjectIdentifier(conn))
            return
        }
        if !pin.isEmpty, Self.requestPIN(in: requestData) == pin {
            failedAttempts = 0
            respond(to: conn)
            return
        }
        failedAttempts += 1
        let locking = failedAttempts >= 3
        if locking {
            Self.lockoutUntil = Date().addingTimeInterval(60)
        }
        respondForbidden(to: conn) { [weak self] in
            guard let self, locking else { return }
            self.listener?.cancel()
            self.listener = nil
            for other in self.connections.values { other.cancel() }
            self.connections.removeAll()
            self.emit(.failed("Quá 3 lần nhập sai mã PIN — kênh gửi log đã tạm dừng 60 giây. Đóng màn hình này, chờ một chút rồi mở lại."))
        }
    }

    /// Extract the PIN a request carries: the `pin=` item of
    /// the request line's query, or an `X-Diag-Pin` header.
    /// Nothing else in the request is inspected or stored,
    /// and the PIN itself is only ever compared, never logged.
    nonisolated private static func requestPIN(in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("x-diag-pin:") {
                return lower.dropFirst("x-diag-pin:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
            if lower.hasPrefix("get ") || lower.hasPrefix("head "),
               let r = lower.range(of: "pin=") {
                let tail = lower[r.upperBound...]
                let digits = tail.prefix { $0.isNumber }
                // The digit run must BE the whole query value:
                // it ends at end-of-line, a space (the HTTP
                // version follows), & or # — "pin=0123xyz" is
                // the value "0123xyz", not this session's PIN
                // (review round 2, F-2).
                let next = tail.dropFirst(digits.count).first
                if !digits.isEmpty,
                   next == nil || next == " " || next == "&" || next == "#" {
                    return String(digits)
                }
            }
        }
        return nil
    }

    /// Send the log as a plain-text download and close. The
    /// body is DiagLog.currentText() (already token-free —
    /// see DiagLog's scrubber); an empty log still downloads
    /// as a one-line placeholder so the owner gets a file,
    /// not a hung browser tab.
    private func respond(to conn: NWConnection) {
        let text = DiagLog.currentText()
        let bodyText = text.isEmpty
            ? "Joe TV diagnostic log is empty.\n" : text
        let body = Data(bodyText.utf8)
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Disposition: attachment; filename=\"ytprobe-diag.txt\"\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        sendAndClose(conn, payload: payload)
    }

    /// The wrong/missing-PIN answer: a short 403, no log
    /// content, no hint about the right code. `after` runs
    /// once the answer is on its way (the lockout path uses
    /// it to take the listener down).
    private func respondForbidden(to conn: NWConnection,
                                  after: @escaping @MainActor () -> Void) {
        let body = Data("403 — wrong or missing PIN.\n".utf8)
        let header = "HTTP/1.1 403 Forbidden\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        sendAndClose(conn, payload: payload, after: after)
    }

    /// Send one payload, then close the connection and drop
    /// it from the live table.
    private func sendAndClose(_ conn: NWConnection, payload: Data,
                              after: (@MainActor () -> Void)? = nil) {
        conn.send(content: payload, completion: .contentProcessed {
            [weak self] _ in
            conn.cancel()
            Task { @MainActor in
                self?.connections.removeValue(
                    forKey: ObjectIdentifier(conn))
                after?()
            }
        })
    }

    /// Deliver a state change on the main actor, as the
    /// contract promises the view — the hop is explicit even
    /// though this class is already main-actor isolated, so
    /// the guarantee survives any future re-isolation.
    private func emit(_ state: State) {
        let callback = onStateChange
        Task { @MainActor in
            callback?(state)
        }
    }

    // MARK: - LAN address

    /// The box's first LAN IPv4 address: the first AF_INET
    /// address on en0/en1/en2 (the Apple TV's Ethernet / Wi-Fi
    /// interfaces) that is up, not loopback and not 127.*.
    /// nil when the box has no LAN address at all — the
    /// caller then reports .failed instead of showing an
    /// address that could never answer. getifaddrs lives in
    /// the Darwin module Foundation re-exports on tvOS.
    nonisolated static func lanIPAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let ptr = cursor {
            cursor = ptr.pointee.ifa_next
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" || name == "en2"
            else { continue }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr,
                              socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("127.") { return ip }
        }
        return nil
    }
}
