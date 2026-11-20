import SwiftUI

// MARK: - Probe 13 — SABR phase 1 (minimal fetcher)
//
// The LAST native-Gold door (owner approved 2026-11-20 as a
// phase-1 decidability probe, per SABR-STUDY-20261120.md §5):
// Probe 9 proved the identity leg (device-code OAuth →
// TVHTML5 /player → playability=OK, SABR-only formats) and
// Probe 12 proved the cookie-session extraction route dead.
// This cell reuses Probe 9's OAuth identity, takes a fresh
// TVHTML5 /player answer for the Gold episode, then speaks
// JUST ENOUGH SABR to decide three things from the log
// alone: (1) does the server demand attestation
// (StreamProtectionStatus), (2) are AVC/AAC formats offered
// (the AVPlayer-feeding kill question), (3) do complete
// init + media segments actually arrive. NO player, NO
// local-HLS assembly, NO PO-token minting — fetch + parse.
//
// Schema sources (read 2026-11-20, googlevideo protos via
// the ts-proto generated code of googlevideo@4.1.1 —
// field numbers below are wire numbers, not guesses):
//   VideoPlaybackAbrRequest: client_abr_state=1,
//     selected_format_ids=2, buffered_ranges=3,
//     player_time_ms=4, video_playback_ustreamer_config=5,
//     preferred_audio_format_ids=16,
//     preferred_video_format_ids=17,
//     preferred_subtitle_format_ids=18, streamer_context=19
//   ClientAbrState: lastManualSelectedResolution=16,
//     clientViewportWidth=18, clientViewportHeight=19,
//     stickyResolution=21, bandwidthEstimate=23,
//     playerTimeMs=28, playbackRate=35 (float),
//     enabledTrackTypesBitfield=40
//   FormatId (misc/common): itag=1, last_modified=2, xtags=3
//   StreamerContext: client_info=1, po_token=2,
//     playback_cookie=3 (bytes on the wire),
//     sabr_contexts=5
//   StreamerContext.ClientInfo: device_make=12,
//     device_model=13, client_name=16, client_version=17,
//     os_name=18, os_version=19, accept_language=21,
//     accept_region=22
//   MediaHeader: header_id=1, video_id=2, itag=3, lmt=4,
//     xtags=5, is_init_seg=8, sequence_number=9,
//     start_ms=11, duration_ms=12, format_id=13,
//     content_length=14
//   FormatInitializationMetadata: video_id=1, format_id=2,
//     end_time_ms=3, end_segment_number=4, mime_type=5
//   StreamProtectionStatus: status=1, max_retries=2
//     (1=OK, 2=ATTESTATION_PENDING, 3=ATTESTATION_REQUIRED)
//   NextRequestPolicy: backoff_time_ms=4, playback_cookie=7
//   SabrRedirect: url=1 · SabrError: type=1, code=2
//   UMP part ids: MEDIA_HEADER=20, MEDIA=21, MEDIA_END=22,
//     NEXT_REQUEST_POLICY=35,
//     FORMAT_INITIALIZATION_METADATA=42, SABR_REDIRECT=43,
//     SABR_ERROR=44, RELOAD_PLAYER_RESPONSE=46,
//     SABR_CONTEXT_UPDATE=57, STREAM_PROTECTION_STATUS=58
//   UMP framing: [varint type][varint size][payload] with
//     the UMP varint (leading byte <0x80→1B, <0xC0→2B,
//     <0xE0→3B, <0xF0→4B, else 5B; the leading byte's
//     remaining bits are the value's high bits).
//
// VideoPlaybackAbrRequest fields this probe SETS:
//   client_abr_state (viewport 1920x1080, sticky +
//     last-manual resolution = chosen video height,
//     bandwidth_estimate = chosen video bitrate,
//     playback_rate = 1.0; player_time_ms and
//     enabled_track_types_bitfield stay at their proto
//     defaults 0 = position 0 / VIDEO_AND_AUDIO, so they
//     are not written), video_playback_ustreamer_config
//     (the /player blob, base64-decoded, echoed verbatim),
//   preferred_audio/video_format_ids (the chosen pair on
//     BOTH requests), selected_format_ids (media request
//     only — empty on the init request, per the study),
//   streamer_context (client_info = TVHTML5 id 7 +
//     version + en/US; playback_cookie echoed from the
//     init response's NextRequestPolicy when one arrives).
// Fields DELIBERATELY OMITTED, and why:
//   buffered_ranges — the client genuinely holds nothing
//     yet at phase 1; claiming ranges would be lying.
//   streamer_context.po_token — no token is held; whether
//     one is demanded is exactly what this probe measures.
//   streamer_context.sabr_contexts — none received yet;
//     echo policy is a phase-2+ question (study §1.5).
//   preferred_subtitle_format_ids — captions are not part
//     of the phase-1 question.
// Simplifications, stated honestly: responses are parsed
// whole-body (the reference clients parse streaming; the
// part inventory is identical either way); at most 3 SABR
// POSTs (init, media, one redirect follow); one backoff
// wait of at most 5 s is honoured before the media
// request; a RELOAD_PLAYER_RESPONSE is logged, not acted
// on. Token VALUES are never logged — presence, lengths
// and expiry only, same posture as Probe 9.
//
// PHASE 1B ADDENDUM (0.1.9, owner approved 2026-11-20):
// phase 1 measured the token-less door — both SABR POSTs
// answered HTTP 403 with 0 bytes, no UMP parts at all.
// Phase 1B changes exactly ONE variable family: the PO
// token. The sequence is otherwise phase 1 verbatim
// (identity → /player census → init rn=0 → media rn=1 →
// at most one redirect). The mint follows the TV
// living-room recipe (SABR-STUDY-20261120.md §2.4 + §5.2
// phase 2; corroborated by BgUtils PR #44 EDIT 2 and
// Morphe #2533, both read 2026-11-20):
//   1. Scrape https://www.youtube.com/tv (Tizen UA) for
//      the session identifiers — livingRoomPoTokenId if
//      the page carries one, else ytcfg VISITOR_DATA.
//      The identifier is the living-room SESSION, never
//      the video id (the study's binding for TV).
//   2. Challenge from the TV client's own config:
//      GET youtube.com/tv_config?action_get_config=true
//      &client=lb4&theme=cl (Tizen UA, Referer /tv) →
//      strip the )]}' prefix → challengeParams.R (JSON)
//      → bgChallenge {program, globalName, interpreter}
//      + the per-response challengeRequestKey.
//   3. Execute BotGuard inside a WKWebView (the view
//      hosts a small bridge surface for this) — the JS
//      harness is a faithful port of the canonical
//      po_token.html BotGuardClient (BgUtils/NewPipe):
//      loadBotGuard → snapshot → botguardResponse. One
//      deliberate adaptation: vm.a receives document.body
//      as the user-interaction element (the official web
//      client passes a real element; the free-function
//      ports pass undefined via the global object).
//   4. POST the botguardResponse to GenerateIT at
//      www.youtube.com/api/jnn/v1 with the tv_config
//      challengeRequestKey → integrity token (bytes).
//   5. obtainPoToken(webPoSignalOutput, integrityToken,
//      identifier) inside the same WebView → the session
//      PO token (raw bytes) → attached as
//      streamer_context.po_token (field 2 — the raw
//      bytes go in directly; SmartTube base64url-DECODES
//      its token string into this same field).
// A mint failure IS the phase-1B verdict (the study's
// named NO-GO: attestation unsatisfiable on tvOS) — the
// token-less POSTs are NOT repeated, phase 1 already
// measured them. Token values never leave the device
// except inside the SABR request itself; logs carry
// presence + lengths only, like every credential here.

// MARK: - Minimal protobuf writer (encode side)

struct ProtoWriter {
    private(set) var data = Data()

    mutating func appendVarint(_ value: UInt64) {
        var v = value
        while true {
            let byte = UInt8(v & 0x7F)
            v >>= 7
            if v == 0 {
                data.append(byte)
                return
            }
            data.append(byte | 0x80)
        }
    }

    mutating func appendTag(field: Int, wireType: Int) {
        appendVarint(UInt64(field << 3 | wireType))
    }

    /// varint field (wire 0) — int32/int64/enum/bool alike
    /// for the non-negative values this probe sends.
    mutating func fieldVarint(_ field: Int, _ value: UInt64) {
        appendTag(field: field, wireType: 0)
        appendVarint(value)
    }

    /// length-delimited field (wire 2): bytes / string /
    /// embedded message are the same shape on the wire.
    mutating func fieldBytes(_ field: Int, _ bytes: Data) {
        appendTag(field: field, wireType: 2)
        appendVarint(UInt64(bytes.count))
        data.append(bytes)
    }

    mutating func fieldString(_ field: Int, _ string: String) {
        fieldBytes(field, Data(string.utf8))
    }

    /// fixed32 float field (wire 5), little-endian.
    mutating func fieldFloat(_ field: Int, _ value: Float) {
        appendTag(field: field, wireType: 5)
        var bits = value.bitPattern
        for _ in 0..<4 {
            data.append(UInt8(bits & 0xFF))
            bits >>= 8
        }
    }
}

// MARK: - Minimal protobuf reader (decode side, bounds-checked)
//
// Every read is bounds-checked: a malformed payload makes
// the read return nil / the skip return false, and the
// caller logs that honestly. No force-unwraps anywhere in
// this file's parsing path.

struct ProtoReader {
    let bytes: [UInt8]
    private(set) var pos: Int
    let end: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.pos = 0
        self.end = bytes.count
    }

    init(_ data: Data) {
        self.init([UInt8](data))
    }

    var atEnd: Bool { pos >= end }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 70 {
            guard pos < end else { return nil }
            let byte = bytes[pos]
            pos += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    mutating func readTag() -> (field: Int, wireType: Int)? {
        guard let tag = readVarint(), tag > 0 else { return nil }
        let field = tag >> 3
        guard field > 0, field <= 0x1FFF_FFFF else { return nil }
        return (Int(field), Int(tag & 0x7))
    }

    mutating func readLengthDelimited() -> [UInt8]? {
        guard let length = readVarint(),
              length <= UInt64(end - pos) else { return nil }
        let n = Int(length)
        let slice = Array(bytes[pos..<(pos + n)])
        pos += n
        return slice
    }

    mutating func readFixed64() -> Bool {
        guard end - pos >= 8 else { return false }
        pos += 8
        return true
    }

    mutating func readFixed32() -> Bool {
        guard end - pos >= 4 else { return false }
        pos += 4
        return true
    }

    /// Skip one field of the given wire type. Groups
    /// (wire 3/4) are not valid in proto3 payloads and are
    /// treated as structural failure.
    mutating func skipField(wireType: Int) -> Bool {
        switch wireType {
        case 0: return readVarint() != nil
        case 1: return readFixed64()
        case 2: return readLengthDelimited() != nil
        case 5: return readFixed32()
        default: return false
        }
    }
}

/// Walk every field of a message payload, calling `handle`
/// for each (fieldNumber, wireType, reader positioned at
/// the value). The handler consumes the value itself
/// (readVarint / readLengthDelimited) or returns false to
/// abort. Returns false when the buffer is structurally
/// broken (bad tag, truncated value, unskippable field).
func protoWalk(_ payload: [UInt8],
               handle: (Int, Int, inout ProtoReader) -> Bool) -> Bool {
    var reader = ProtoReader(payload)
    while !reader.atEnd {
        guard let (field, wireType) = reader.readTag() else { return false }
        if !handle(field, wireType, &reader) { return false }
    }
    return true
}

// MARK: - FormatId (misc/common.proto: itag=1, last_modified=2, xtags=3)

struct SabrFormatId: Equatable {
    var itag: Int = 0
    var lastModified: UInt64 = 0
    var xtags: String = ""

    func encoded() -> Data {
        var writer = ProtoWriter()
        if itag != 0 { writer.fieldVarint(1, UInt64(itag)) }
        if lastModified != 0 { writer.fieldVarint(2, lastModified) }
        if !xtags.isEmpty { writer.fieldString(3, xtags) }
        return writer.data
    }

    static func decode(_ payload: [UInt8]) -> SabrFormatId? {
        var result = SabrFormatId()
        let ok = protoWalk(payload) { field, wireType, reader in
            switch (field, wireType) {
            case (1, 0):
                guard let v = reader.readVarint() else { return false }
                result.itag = Int(v)
                return true
            case (2, 0):
                guard let v = reader.readVarint() else { return false }
                result.lastModified = v
                return true
            case (3, 2):
                guard let raw = reader.readLengthDelimited() else { return false }
                result.xtags = String(decoding: raw, as: UTF8.self)
                return true
            default:
                return reader.skipField(wireType: wireType)
            }
        }
        return ok ? result : nil
    }
}

// MARK: - UMP framing
//
// [varint type][varint size][payload]; the varint is the
// UMP scheme, NOT the protobuf varint: the leading byte's
// top bits select the length (0xxxxxxx=1, 10xxxxxx=2,
// 110xxxxx=3, 1110xxxx=4, 11110xxx=5) and its remaining
// bits are the value's high bits; following bytes are
// big-endian value bytes.

struct UMPPart {
    let type: Int
    let payload: [UInt8]
}

func umpReadVarint(_ bytes: [UInt8], at offset: Int) -> (value: UInt64, length: Int)? {
    guard offset >= 0, offset < bytes.count else { return nil }
    let b0 = bytes[offset]
    func byte(_ i: Int) -> UInt64? {
        let idx = offset + i
        guard idx < bytes.count else { return nil }
        return UInt64(bytes[idx])
    }
    if b0 < 0x80 {
        return (UInt64(b0), 1)
    } else if b0 < 0xC0 {
        guard let b1 = byte(1) else { return nil }
        return ((UInt64(b0 & 0x3F) << 8) | b1, 2)
    } else if b0 < 0xE0 {
        guard let b1 = byte(1), let b2 = byte(2) else { return nil }
        return ((UInt64(b0 & 0x1F) << 16) | (b1 << 8) | b2, 3)
    } else if b0 < 0xF0 {
        guard let b1 = byte(1), let b2 = byte(2), let b3 = byte(3) else { return nil }
        return ((UInt64(b0 & 0x0F) << 24) | (b1 << 16) | (b2 << 8) | b3, 4)
    } else {
        guard let b1 = byte(1), let b2 = byte(2),
              let b3 = byte(3), let b4 = byte(4) else { return nil }
        return ((UInt64(b0 & 0x07) << 32) | (b1 << 24) | (b2 << 16) | (b3 << 8) | b4, 5)
    }
}

/// Split a whole response body into parts. Stops cleanly
/// at a truncated tail (flagged, never a crash).
func umpParse(_ data: Data) -> (parts: [UMPPart], truncatedTail: Bool) {
    let bytes = [UInt8](data)
    var parts: [UMPPart] = []
    var pos = 0
    var truncated = false
    while pos < bytes.count {
        guard let (typeValue, typeLength) = umpReadVarint(bytes, at: pos) else {
            truncated = true
            break
        }
        let sizeOffset = pos + typeLength
        guard let (sizeValue, sizeLength) = umpReadVarint(bytes, at: sizeOffset) else {
            truncated = true
            break
        }
        let payloadStart = sizeOffset + sizeLength
        guard sizeValue <= UInt64(bytes.count - payloadStart) else {
            truncated = true
            break
        }
        let size = Int(sizeValue)
        parts.append(UMPPart(type: Int(typeValue),
                             payload: Array(bytes[payloadStart..<(payloadStart + size)])))
        pos = payloadStart + size
        if parts.count > 200_000 { truncated = true; break }
    }
    return (parts, truncated)
}

enum UMPPartType {
    static let mediaHeader = 20
    static let media = 21
    static let mediaEnd = 22
    static let nextRequestPolicy = 35
    static let formatInit = 42
    static let sabrRedirect = 43
    static let sabrError = 44
    static let reloadPlayer = 46
    static let sabrContextUpdate = 57
    static let protectionStatus = 58

    static func name(_ type: Int) -> String {
        switch type {
        case 10: return "ONESIE_HEADER"
        case 11: return "ONESIE_DATA"
        case 12: return "ONESIE_ENCRYPTED_MEDIA"
        case 20: return "MEDIA_HEADER"
        case 21: return "MEDIA"
        case 22: return "MEDIA_END"
        case 30: return "CONFIG"
        case 31: return "LIVE_METADATA"
        case 35: return "NEXT_REQUEST_POLICY"
        case 36: return "USTREAMER_VIDEO_AND_FORMAT_METADATA"
        case 37: return "FORMAT_SELECTION_CONFIG"
        case 38: return "USTREAMER_SELECTED_MEDIA_STREAM"
        case 42: return "FORMAT_INITIALIZATION_METADATA"
        case 43: return "SABR_REDIRECT"
        case 44: return "SABR_ERROR"
        case 45: return "SABR_SEEK"
        case 46: return "RELOAD_PLAYER_RESPONSE"
        case 47: return "PLAYBACK_START_POLICY"
        case 48: return "ALLOWED_CACHED_FORMATS"
        case 51: return "SELECTABLE_FORMATS"
        case 52: return "REQUEST_IDENTIFIER"
        case 57: return "SABR_CONTEXT_UPDATE"
        case 58: return "STREAM_PROTECTION_STATUS"
        case 59: return "SABR_CONTEXT_SENDING_POLICY"
        case 61: return "SABR_ACK"
        case 62: return "END_OF_TRACK"
        case 65: return "PREWARM_CONNECTION"
        case 66: return "PLAYBACK_DEBUG_INFO"
        case 67: return "SNACKBAR_MESSAGE"
        default: return "UNKNOWN(\(type))"
        }
    }
}

// MARK: - SABR part decoders (all bounds-checked via protoWalk)

struct SabrProtection {
    /// field 1 when present; nil = the part carried no
    /// status field (or was empty).
    var status: Int?
    /// false = the payload was structurally broken.
    var decoded: Bool

    var label: String {
        switch status {
        case 1: return "OK (1)"
        case 2: return "ATTESTATION_PENDING (2)"
        case 3: return "ATTESTATION_REQUIRED (3)"
        case .some(let value): return "UNKNOWN(\(value))"
        case nil: return "KHÔNG CÓ FIELD STATUS"
        }
    }
}

func sabrDecodeProtectionStatus(_ payload: [UInt8]) -> SabrProtection {
    var status: Int?
    let ok = protoWalk(payload) { field, wireType, reader in
        if field == 1, wireType == 0 {
            guard let value = reader.readVarint() else { return false }
            status = Int(value)
            return true
        }
        return reader.skipField(wireType: wireType)
    }
    return SabrProtection(status: status, decoded: ok)
}

struct SabrMediaHeader {
    var headerId: Int = -1
    var itag: Int = 0            // field 3 (legacy slot)
    var formatIdItag: Int?       // field 13 FormatId.itag
    var isInitSeg: Bool = false
    var sequenceNumber: Int64 = 0
    var startMs: Int64 = 0
    var durationMs: Int64 = 0
    var contentLength: Int64 = 0

    /// The itag that actually identifies the stream:
    /// format_id wins over the legacy field, per the
    /// reference processors.
    var effectiveItag: Int { formatIdItag ?? itag }
}

func sabrDecodeMediaHeader(_ payload: [UInt8]) -> SabrMediaHeader? {
    var header = SabrMediaHeader()
    let ok = protoWalk(payload) { field, wireType, reader in
        switch (field, wireType) {
        case (1, 0):
            guard let v = reader.readVarint() else { return false }
            header.headerId = Int(v)
            return true
        case (3, 0):
            guard let v = reader.readVarint() else { return false }
            header.itag = Int(v)
            return true
        case (8, 0):
            guard let v = reader.readVarint() else { return false }
            header.isInitSeg = (v != 0)
            return true
        case (9, 0):
            guard let v = reader.readVarint() else { return false }
            header.sequenceNumber = Int64(bitPattern: v)
            return true
        case (11, 0):
            guard let v = reader.readVarint() else { return false }
            header.startMs = Int64(bitPattern: v)
            return true
        case (12, 0):
            guard let v = reader.readVarint() else { return false }
            header.durationMs = Int64(bitPattern: v)
            return true
        case (13, 2):
            guard let raw = reader.readLengthDelimited() else { return false }
            header.formatIdItag = SabrFormatId.decode(raw)?.itag
            return true
        case (14, 0):
            guard let v = reader.readVarint() else { return false }
            header.contentLength = Int64(bitPattern: v)
            return true
        default:
            return reader.skipField(wireType: wireType)
        }
    }
    return ok ? header : nil
}

struct SabrFormatInit {
    var videoId: String = ""
    var itag: Int = 0
    var endTimeMs: Int64 = 0
    var endSegmentNumber: Int64 = 0
    var mimeType: String = ""
}

func sabrDecodeFormatInit(_ payload: [UInt8]) -> SabrFormatInit? {
    var result = SabrFormatInit()
    let ok = protoWalk(payload) { field, wireType, reader in
        switch (field, wireType) {
        case (1, 2):
            guard let raw = reader.readLengthDelimited() else { return false }
            result.videoId = String(decoding: raw, as: UTF8.self)
            return true
        case (2, 2):
            guard let raw = reader.readLengthDelimited() else { return false }
            result.itag = SabrFormatId.decode(raw)?.itag ?? 0
            return true
        case (3, 0):
            guard let v = reader.readVarint() else { return false }
            result.endTimeMs = Int64(bitPattern: v)
            return true
        case (4, 0):
            guard let v = reader.readVarint() else { return false }
            result.endSegmentNumber = Int64(bitPattern: v)
            return true
        case (5, 2):
            guard let raw = reader.readLengthDelimited() else { return false }
            result.mimeType = String(decoding: raw, as: UTF8.self)
            return true
        default:
            return reader.skipField(wireType: wireType)
        }
    }
    return ok ? result : nil
}

func sabrDecodeRedirect(_ payload: [UInt8]) -> String? {
    var url: String?
    let ok = protoWalk(payload) { field, wireType, reader in
        if field == 1, wireType == 2 {
            guard let raw = reader.readLengthDelimited() else { return false }
            url = String(decoding: raw, as: UTF8.self)
            return true
        }
        return reader.skipField(wireType: wireType)
    }
    return ok ? url : nil
}

struct SabrErrorInfo {
    var type: String = ""
    var code: Int = 0
}

func sabrDecodeError(_ payload: [UInt8]) -> SabrErrorInfo? {
    var result = SabrErrorInfo()
    let ok = protoWalk(payload) { field, wireType, reader in
        switch (field, wireType) {
        case (1, 2):
            guard let raw = reader.readLengthDelimited() else { return false }
            result.type = String(decoding: raw, as: UTF8.self)
            return true
        case (2, 0):
            guard let v = reader.readVarint() else { return false }
            result.code = Int(v)
            return true
        default:
            return reader.skipField(wireType: wireType)
        }
    }
    return ok ? result : nil
}

struct SabrNextRequestPolicy {
    var backoffMs: Int64 = 0
    /// field 7 payload bytes, captured RAW: the
    /// StreamerContext.playback_cookie field is
    /// length-delimited, and the reference clients echo
    /// this payload verbatim as that field's value.
    var playbackCookie: [UInt8]?
}

func sabrDecodeNextRequestPolicy(_ payload: [UInt8]) -> SabrNextRequestPolicy? {
    var result = SabrNextRequestPolicy()
    let ok = protoWalk(payload) { field, wireType, reader in
        switch (field, wireType) {
        case (4, 0):
            guard let v = reader.readVarint() else { return false }
            result.backoffMs = Int64(bitPattern: v)
            return true
        case (7, 2):
            guard let raw = reader.readLengthDelimited() else { return false }
            result.playbackCookie = raw
            return true
        default:
            return reader.skipField(wireType: wireType)
        }
    }
    return ok ? result : nil
}

// MARK: - Segment tracker
//
// Folds every MEDIA_HEADER / MEDIA / MEDIA_END across ALL
// responses of the run: an init or media segment counts
// COMPLETE when its MEDIA_END arrived and the received
// byte count matches the header's content_length (when
// the header declared one).

final class SabrSegmentTracker {
    struct HeaderState {
        var itag: Int
        var isInit: Bool
        var contentLength: Int64
        var receivedBytes: Int = 0
        var ended: Bool = false
    }

    private(set) var headers: [Int: HeaderState] = [:]
    private(set) var mediaBytesByItag: [Int: Int] = [:]
    private(set) var mediaPartCountByItag: [Int: Int] = [:]
    private(set) var danglingMediaBytes = 0
    private(set) var completedInitItags: Set<Int> = []
    private(set) var completedMediaItags: Set<Int> = []

    func registerHeader(_ header: SabrMediaHeader) {
        guard header.headerId >= 0 else { return }
        headers[header.headerId] = HeaderState(
            itag: header.effectiveItag,
            isInit: header.isInitSeg,
            contentLength: header.contentLength)
    }

    func addMedia(headerByte: Int, byteCount: Int) {
        guard let state = headers[headerByte] else {
            danglingMediaBytes += byteCount
            return
        }
        headers[headerByte]?.receivedBytes += byteCount
        mediaBytesByItag[state.itag, default: 0] += byteCount
        mediaPartCountByItag[state.itag, default: 0] += 1
    }

    func endMedia(headerByte: Int) {
        guard var state = headers[headerByte] else { return }
        state.ended = true
        headers[headerByte] = state
        let complete = state.contentLength <= 0
            || Int64(state.receivedBytes) == state.contentLength
        guard complete else { return }
        if state.isInit {
            completedInitItags.insert(state.itag)
        } else {
            completedMediaItags.insert(state.itag)
        }
    }
}

// MARK: - One response's inventory

struct SabrResponseInventory {
    var partCounts: [Int: (count: Int, bytes: Int)] = [:]
    var totalParts: Int { partCounts.values.reduce(0) { $0 + $1.count } }
    var protectionStatuses: [SabrProtection] = []
    var formatInits: [SabrFormatInit] = []
    var mediaHeaders: [SabrMediaHeader] = []
    var sabrErrors: [SabrErrorInfo] = []
    var redirectURL: String?
    var backoffMs: Int64 = 0
    var playbackCookie: [UInt8]?
    var sawReloadPlayer = false
    var sawSabrContextUpdate = false
    var malformedNotes: [String] = []

    mutating func absorb(_ parts: [UMPPart], tracker: SabrSegmentTracker) {
        for part in parts {
            var entry = partCounts[part.type] ?? (count: 0, bytes: 0)
            entry.count += 1
            entry.bytes += part.payload.count
            partCounts[part.type] = entry
            switch part.type {
            case UMPPartType.protectionStatus:
                let protection = sabrDecodeProtectionStatus(part.payload)
                protectionStatuses.append(protection)
                if !protection.decoded {
                    malformedNotes.append(
                        "STREAM_PROTECTION_STATUS payload \(part.payload.count)B không giải mã được")
                }
            case UMPPartType.formatInit:
                if let formatInit = sabrDecodeFormatInit(part.payload) {
                    formatInits.append(formatInit)
                } else {
                    malformedNotes.append(
                        "FORMAT_INITIALIZATION_METADATA payload \(part.payload.count)B không giải mã được")
                }
            case UMPPartType.mediaHeader:
                if let header = sabrDecodeMediaHeader(part.payload) {
                    mediaHeaders.append(header)
                    tracker.registerHeader(header)
                } else {
                    malformedNotes.append(
                        "MEDIA_HEADER payload \(part.payload.count)B không giải mã được")
                }
            case UMPPartType.media:
                if part.payload.isEmpty {
                    malformedNotes.append("MEDIA part rỗng (không có byte headerId)")
                } else {
                    tracker.addMedia(headerByte: Int(part.payload[0]),
                                     byteCount: part.payload.count - 1)
                }
            case UMPPartType.mediaEnd:
                if part.payload.isEmpty {
                    malformedNotes.append("MEDIA_END part rỗng (không có byte headerId)")
                } else {
                    tracker.endMedia(headerByte: Int(part.payload[0]))
                }
            case UMPPartType.sabrRedirect:
                if let url = sabrDecodeRedirect(part.payload) {
                    redirectURL = url
                } else {
                    malformedNotes.append(
                        "SABR_REDIRECT payload \(part.payload.count)B không giải mã được")
                }
            case UMPPartType.sabrError:
                if let error = sabrDecodeError(part.payload) {
                    sabrErrors.append(error)
                } else {
                    malformedNotes.append(
                        "SABR_ERROR payload \(part.payload.count)B không giải mã được")
                }
            case UMPPartType.nextRequestPolicy:
                if let policy = sabrDecodeNextRequestPolicy(part.payload) {
                    if policy.backoffMs > 0 { backoffMs = policy.backoffMs }
                    if let cookie = policy.playbackCookie { playbackCookie = cookie }
                } else {
                    malformedNotes.append(
                        "NEXT_REQUEST_POLICY payload \(part.payload.count)B không giải mã được")
                }
            case UMPPartType.reloadPlayer:
                sawReloadPlayer = true
            case UMPPartType.sabrContextUpdate:
                sawSabrContextUpdate = true
            default:
                break
            }
        }
    }
}

// MARK: - /player format model

struct SabrPlayerFormat {
    var itag: Int
    var mimeType: String
    var bitrate: Int
    var width: Int
    var height: Int
    var lastModified: UInt64
    var xtags: String

    var isVideo: Bool { mimeType.hasPrefix("video/") }
    var isAudio: Bool { mimeType.hasPrefix("audio/") }
    var isAvc: Bool { mimeType.lowercased().contains("avc1") }
    var isAac: Bool { mimeType.lowercased().contains("mp4a") }
    var formatId: SabrFormatId {
        SabrFormatId(itag: itag, lastModified: lastModified, xtags: xtags)
    }
}

// MARK: - VideoPlaybackAbrRequest builder
//
// Field numbers per the header comment. Omitted fields
// stay at proto defaults ON PURPOSE (documented there):
// player_time_ms = 0, enabled_track_types_bitfield = 0
// (VIDEO_AND_AUDIO), buffered_ranges empty, no
// sabr_contexts, no subtitle preferences. Phase 1B:
// po_token is written whenever the mint produced one.

func sabrBuildRequest(clientVersion: String,
                      ustreamerConfig: Data?,
                      preferredVideo: SabrPlayerFormat?,
                      preferredAudio: SabrPlayerFormat?,
                      selected: [SabrPlayerFormat],
                      playbackCookie: [UInt8]?,
                      poToken: Data?,
                      videoHeight: Int,
                      videoBitrate: Int) -> Data {
    // ClientAbrState
    var abr = ProtoWriter()
    if videoHeight > 0 {
        abr.fieldVarint(16, UInt64(videoHeight))   // last_manual_selected_resolution
        abr.fieldVarint(21, UInt64(videoHeight))   // sticky_resolution
    }
    abr.fieldVarint(18, 1920)                      // client_viewport_width
    abr.fieldVarint(19, 1080)                      // client_viewport_height
    if videoBitrate > 0 {
        abr.fieldVarint(23, UInt64(videoBitrate))  // bandwidth_estimate
    }
    abr.fieldFloat(35, 1.0)                        // playback_rate

    // StreamerContext.ClientInfo — TVHTML5 = client 7.
    var clientInfo = ProtoWriter()
    clientInfo.fieldVarint(16, 7)                  // client_name
    clientInfo.fieldString(17, clientVersion)      // client_version
    clientInfo.fieldString(21, "en")               // accept_language
    clientInfo.fieldString(22, "US")               // accept_region

    var streamerContext = ProtoWriter()
    streamerContext.fieldBytes(1, clientInfo.data)
    if let poToken, !poToken.isEmpty {
        streamerContext.fieldBytes(2, poToken)               // po_token (raw token bytes, phase 1B)
    }
    if let playbackCookie, !playbackCookie.isEmpty {
        streamerContext.fieldBytes(3, Data(playbackCookie))  // playback_cookie (raw echo)
    }

    var request = ProtoWriter()
    request.fieldBytes(1, abr.data)                              // client_abr_state
    for format in selected {
        request.fieldBytes(2, format.formatId.encoded())         // selected_format_ids
    }
    if let ustreamerConfig {
        request.fieldBytes(5, ustreamerConfig)                   // video_playback_ustreamer_config
    }
    if let preferredAudio {
        request.fieldBytes(16, preferredAudio.formatId.encoded())
    }
    if let preferredVideo {
        request.fieldBytes(17, preferredVideo.formatId.encoded())
    }
    request.fieldBytes(19, streamerContext.data)                 // streamer_context
    return request.data
}

// MARK: - Run state (cumulative across the run's responses)

final class SabrRunState {
    let tracker = SabrSegmentTracker()
    var protectionSeen: [Int] = []
    var protectionUndecodable = 0
    var formatInitItags: [Int] = []
    var sabrErrors: [SabrErrorInfo] = []
    var sawReload = false
    var sawContextUpdate = false
    var backoffMs: Int64 = 0
    var playbackCookie: [UInt8]?
    var redirectURL: String?
    var transportNote: String?
    var partCounts: [Int: (count: Int, bytes: Int)] = [:]

    func mergePart(type: Int, count: Int, bytes: Int) {
        var entry = partCounts[type] ?? (count: 0, bytes: 0)
        entry.count += count
        entry.bytes += bytes
        partCounts[type] = entry
    }
}

// MARK: - PO-token mint outcome (phase 1B)

enum SabrMintOutcome {
    /// Raw token bytes, ready for streamer_context.
    case token(Data)
    /// The mint chain broke at a named, concrete step —
    /// the string says exactly where (the verdict text).
    case failed(step: String)
}

// MARK: - Model

@MainActor
final class SabrProbeModel: ObservableObject {
    @Published var lines: [String] = []
    @Published var verdict = ""
    @Published var running = false
    @Published var userCode: String?
    let verificationURL = "https://www.google.com/device"
    private var started = false

    /// Phase 1B: the WebView surface the BotGuard mint
    /// runs in. The view hosts it (a WKWebView only
    /// executes while it sits in the hierarchy); the mint
    /// step below drives it through this controller.
    let mintController = ProbeWebController()

    /// The Tizen TV UA Probe 9's /tv scrape proved out —
    /// the same UA the phase-1B /tv + tv_config fetches
    /// and the mint page load use.
    static let tizenUA = "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.5) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/5.0 Chrome/85.0.4183.120 TV Safari/537.36"

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
        DiagLog.write("probe13", message)
        lines.append(message)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }

    private func finish(_ verdictLine: String) {
        verdict = verdictLine
        log("KẾT QUẢ probe13b: \(verdictLine)")
        log("Gửi file log về như thường lệ (link ở màn hình chính) — toàn bộ kiểm kê nằm trong log.")
    }

    // MARK: Identity

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

    /// The TVHTML5 spec, taken from the bundled ladder
    /// exactly the way Probe 9 takes it (bundled copy —
    /// no hosted fetch, so the probe works offline of the
    /// playlist repo too).
    private func tvSpec() -> ProbeClientSpec? {
        let clients = (try? JSONDecoder().decode(
            [ProbeClientSpec].self,
            from: Data(ProbeClientLadder.bundledJSON.utf8))) ?? []
        return clients.first(where: { $0.name == "TVHTML5" })
    }

    // MARK: /player (Probe 9's recipe, richer logging)

    private func callPlayer(token: String,
                            spec: ProbeClientSpec) async -> (http: Int, json: [String: Any]?) {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false&key=\(spec.apiKey ?? "")") else {
            return (0, nil)
        }
        // The context carries exactly the five client keys
        // Probe 9 sent when it got playability=OK.
        let clientContext: [String: Any] = [
            "clientName": spec.clientName,
            "clientVersion": spec.clientVersion,
            "hl": "en",
            "gl": "US",
            "userAgent": spec.userAgent,
        ]
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
        request.setValue("\(spec.clientNumber)", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(spec.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (http, json)
        } catch {
            log("player: lỗi mạng — \(error.localizedDescription)")
            return (0, nil)
        }
    }

    private func extractUstreamerConfig(_ json: [String: Any]) -> (data: Data?, source: String) {
        let streaming = json["streamingData"] as? [String: Any]
        if let base64 = streaming?["videoPlaybackUstreamerConfig"] as? String,
           let data = decodeBase64Loose(base64) {
            return (data, "streamingData.videoPlaybackUstreamerConfig")
        }
        let mediaCommon = (json["playerConfig"] as? [String: Any])?["mediaCommonConfig"] as? [String: Any]
        let requestConfig = mediaCommon?["mediaUstreamerRequestConfig"] as? [String: Any]
        if let base64 = requestConfig?["videoPlaybackUstreamerConfig"] as? String,
           let data = decodeBase64Loose(base64) {
            return (data, "playerConfig.mediaCommonConfig.mediaUstreamerRequestConfig")
        }
        return (nil, "KHÔNG CÓ trong cả hai vị trí đã biết")
    }

    private func decodeBase64Loose(_ string: String) -> Data? {
        var normalised = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while normalised.count % 4 != 0 { normalised += "=" }
        return Data(base64Encoded: normalised)
    }

    // MARK: SABR POST + response processing

    private func sabrPost(baseURL: URL, rn: Int, body: Data,
                          userAgent: String) async -> (http: Int, data: Data?, contentType: String?) {
        let base = baseURL.absoluteString
        let separator = base.contains("?") ? "&" : "?"
        guard let url = URL(string: base + separator + "rn=\(rn)") else { return (0, nil, nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.yt-ump", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            return (httpResponse?.statusCode ?? -1, data,
                    httpResponse?.value(forHTTPHeaderField: "Content-Type"))
        } catch {
            log("sabr: POST rn=\(rn) lỗi mạng — \(error.localizedDescription)")
            return (0, nil, nil)
        }
    }

    private func processSabrResponse(label: String, http: Int, data: Data?,
                                     contentType: String?, state: SabrRunState) {
        guard let data else {
            log("sabr[\(label)]: HTTP \(http) — KHÔNG có body")
            state.transportNote = "POST \(label) HTTP \(http), không body"
            return
        }
        log("sabr[\(label)]: HTTP \(http) · \(data.count) bytes · content-type \(contentType ?? "?")")
        if http != 200, state.transportNote == nil {
            state.transportNote = "POST \(label) HTTP \(http)"
        }
        let (parts, truncated) = umpParse(data)
        if parts.isEmpty {
            log("sabr[\(label)]: body không tách được part UMP nào")
            if state.transportNote == nil {
                state.transportNote = "response \(label) không có part UMP nào"
            }
            return
        }
        var inventory = SabrResponseInventory()
        inventory.absorb(parts, tracker: state.tracker)
        for type in inventory.partCounts.keys.sorted() {
            guard let entry = inventory.partCounts[type] else { continue }
            log("sabr[\(label)]: part \(type) \(UMPPartType.name(type)) ×\(entry.count) · \(entry.bytes)B")
            state.mergePart(type: type, count: entry.count, bytes: entry.bytes)
        }
        for protection in inventory.protectionStatuses {
            if protection.decoded, let status = protection.status {
                state.protectionSeen.append(status)
                log("sabr[\(label)]: StreamProtectionStatus = \(protection.label)")
            } else if protection.decoded {
                log("sabr[\(label)]: StreamProtectionStatus part có mặt nhưng KHÔNG có field status")
            } else {
                state.protectionUndecodable += 1
                log("sabr[\(label)]: StreamProtectionStatus part có mặt nhưng payload không giải mã được")
            }
        }
        for formatInit in inventory.formatInits {
            state.formatInitItags.append(formatInit.itag)
            log("sabr[\(label)]: format-init itag \(formatInit.itag) mime \"\(formatInit.mimeType)\" endTimeMs \(formatInit.endTimeMs) endSeg \(formatInit.endSegmentNumber)")
        }
        for header in inventory.mediaHeaders {
            log("sabr[\(label)]: media-header id \(header.headerId) itag \(header.effectiveItag) init \(header.isInitSeg) seq \(header.sequenceNumber) contentLength \(header.contentLength) startMs \(header.startMs) durMs \(header.durationMs)")
        }
        for error in inventory.sabrErrors {
            state.sabrErrors.append(error)
            log("sabr[\(label)]: SabrError type=\"\(error.type)\" code=\(error.code)")
        }
        if let redirect = inventory.redirectURL {
            state.redirectURL = redirect
            let host = URL(string: redirect)?.host ?? "?"
            log("sabr[\(label)]: SABR_REDIRECT → host \(host) (chỉ ghi host, không ghi URL đầy đủ)")
        }
        if inventory.backoffMs > 0 {
            state.backoffMs = inventory.backoffMs
            log("sabr[\(label)]: NextRequestPolicy backoff \(inventory.backoffMs)ms")
        }
        if let cookie = inventory.playbackCookie {
            state.playbackCookie = cookie
            log("sabr[\(label)]: NextRequestPolicy playbackCookie CÓ (\(cookie.count)B) — sẽ echo ở request kế tiếp")
        }
        if inventory.sawReloadPlayer {
            state.sawReload = true
            log("sabr[\(label)]: RELOAD_PLAYER_RESPONSE — server yêu cầu nạp lại /player (probe chỉ ghi nhận)")
        }
        if inventory.sawSabrContextUpdate {
            state.sawContextUpdate = true
            log("sabr[\(label)]: SABR_CONTEXT_UPDATE có mặt — probe pha 1 không echo sabr_contexts (ghi rõ trong code)")
        }
        for note in inventory.malformedNotes {
            log("sabr[\(label)]: LƯU Ý — \(note)")
        }
        if truncated {
            log("sabr[\(label)]: CẢNH BÁO — đuôi response bị cắt giữa một part; đã kiểm kê \(parts.count) part trọn")
        }
    }

    // MARK: PO-token mint (phase 1B — TV living-room recipe)
    //
    // Steps per the header addendum. Every failure returns
    // .failed with the concrete step; every value that
    // crosses a trust boundary (page HTML, tv_config JSON,
    // GenerateIT answer, WebView results) is parsed with
    // guards — no force-unwraps anywhere below.

    private func fetchTextWithStatus(_ urlString: String, userAgent: String,
                                     referer: String?) async -> (http: Int, text: String)? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            return (http, String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }

    private func jnnPost(_ urlString: String, array: [Any],
                         userAgent: String) async -> (http: Int, array: [Any]?, bytes: Int) {
        guard let url = URL(string: urlString),
              let body = try? JSONSerialization.data(withJSONObject: array) else {
            return (0, nil, 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "x-user-agent")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
            return (http, parsed, data.count)
        } catch {
            log("mint: POST jnn lỗi mạng — \(error.localizedDescription)")
            return (0, nil, 0)
        }
    }

    /// JSON-encode one string as a JS-safe literal
    /// (serialise a one-element array, strip the brackets).
    private func jsonEncodedString(_ string: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let text = String(data: data, encoding: .utf8), text.count >= 2 else {
            return nil
        }
        return String(text.dropFirst().dropLast())
    }

    private func jsonEncodedObject(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func evaluateMintJS(_ js: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            mintController.evaluateForResult(js) { result in
                cont.resume(returning: result)
            }
        }
    }

    /// Poll window.__probeMint until a terminal step shows
    /// or the budget runs out; logs every step transition.
    private func pollMintState(terminalSteps: Set<String>,
                               timeoutSeconds: Int) async -> [String: Any]? {
        var lastStep = ""
        var lastState: [String: Any]?
        let polls = max(1, timeoutSeconds * 2 / 3)
        for _ in 0..<polls {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let raw = await evaluateMintJS("JSON.stringify(window.__probeMint || {step: 'gone'})"),
                  let data = raw.data(using: .utf8),
                  let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let step = state["step"] as? String else { continue }
            lastState = state
            if step != lastStep {
                lastStep = step
                log("mint: bước WebView → \(step)")
            }
            if terminalSteps.contains(step) { return state }
        }
        return lastState
    }

    private func mintPoToken() async -> SabrMintOutcome {
        // 1 — Session identifiers from the /tv page.
        guard let tvHTML = await fetchText("https://www.youtube.com/tv",
                                            userAgent: Self.tizenUA) else {
            return .failed(step: "cạo trang /tv — fetch lỗi, không lấy được trang để tìm livingRoomPoTokenId/visitorData")
        }
        let livingRoom = firstRegexCapture(in: tvHTML, pattern: "\"livingRoomPoTokenId\"\\s*:\\s*\"([^\"]+)\"")
            ?? firstRegexCapture(in: tvHTML, pattern: "\"LIVING_ROOM_PO_TOKEN_ID\"\\s*:\\s*\"([^\"]+)\"")
        let visitor = firstRegexCapture(in: tvHTML, pattern: "\"VISITOR_DATA\"\\s*:\\s*\"([^\"]+)\"")
            ?? firstRegexCapture(in: tvHTML, pattern: "\"visitorData\"\\s*:\\s*\"([^\"]+)\"")
        log("mint: /tv scrape (\(tvHTML.count) bytes) — livingRoomPoTokenId \(livingRoom.map { "CÓ (len \($0.count))" } ?? "KHÔNG THẤY") · visitorData \(visitor.map { "CÓ (len \($0.count))" } ?? "KHÔNG THẤY")")
        guard let identifier = livingRoom ?? visitor else {
            return .failed(step: "cạo trang /tv — không thấy livingRoomPoTokenId lẫn VISITOR_DATA trong HTML /tv")
        }
        let identifierKind = livingRoom != nil ? "livingRoomPoTokenId" : "visitorData"
        log("mint: identifier của mint = \(identifierKind) (len \(identifier.count), không ghi giá trị)")

        // 2 — The TV client's own challenge (tv_config).
        let configURL = "https://www.youtube.com/tv_config?action_get_config=true&client=lb4&theme=cl"
        guard let configFetch = await fetchTextWithStatus(configURL, userAgent: Self.tizenUA,
                                                          referer: "https://www.youtube.com/tv") else {
            return .failed(step: "tv_config — fetch lỗi mạng")
        }
        log("mint: tv_config HTTP \(configFetch.http) · \(configFetch.text.count) bytes")
        guard configFetch.http == 200 else {
            return .failed(step: "tv_config — HTTP \(configFetch.http)")
        }
        var configText = configFetch.text
        if configText.hasPrefix(")]}'") { configText = String(configText.dropFirst(4)) }
        configText = configText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configData = configText.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: configData)) as? [String: Any] else {
            return .failed(step: "tv_config — đáp án không phải JSON object")
        }
        let challengeParams = root["challengeParams"] as? [String: Any]
        var rObject: [String: Any]?
        if let rString = challengeParams?["R"] as? String,
           let rData = rString.data(using: .utf8) {
            rObject = (try? JSONSerialization.jsonObject(with: rData)) as? [String: Any]
        } else if let rDict = challengeParams?["R"] as? [String: Any] {
            rObject = rDict
        }
        log("mint: tv_config keys — root: \(root.keys.sorted().joined(separator: ",")) · challengeParams: \(challengeParams?.keys.sorted().joined(separator: ",") ?? "—") · R: \(rObject?.keys.sorted().joined(separator: ",") ?? "—")")
        let bgChallenge = (rObject?["bgChallenge"] as? [String: Any])
            ?? (challengeParams?["bgChallenge"] as? [String: Any])
            ?? (rObject?.keys.contains("program") == true ? rObject : nil)
        let requestKey = (rObject?["challengeRequestKey"] as? String)
            ?? (challengeParams?["challengeRequestKey"] as? String)
            ?? (root["challengeRequestKey"] as? String)
        guard let bgChallenge,
              let program = bgChallenge["program"] as? String,
              let globalName = bgChallenge["globalName"] as? String else {
            return .failed(step: "tv_config — không tìm thấy bgChallenge/program/globalName (kho keys đã ghi ở trên)")
        }
        guard let requestKey else {
            return .failed(step: "tv_config — không tìm thấy challengeRequestKey cho GenerateIT")
        }
        log("mint: bgChallenge CÓ — program len \(program.count) · globalName \"\(globalName)\" · challengeRequestKey len \(requestKey.count)")

        // 2b — The BotGuard interpreter: inline if the
        // challenge carries it, else fetch its URL.
        var interpreterSource: String?
        var interpreterOrigin = ""
        if let wrapped = bgChallenge["interpreterJavascript"] as? [String: Any] {
            if let inline = wrapped["privateDoNotAccessOrElseSafeScriptWrappedValue"] as? String,
               !inline.isEmpty {
                interpreterSource = inline
                interpreterOrigin = "inline trong bgChallenge"
            } else if let urlString = wrapped["privateDoNotAccessOrElseSafeResourceUrlWrappedValue"] as? String,
                      let fetched = await fetchText(urlString, userAgent: Self.tizenUA) {
                interpreterSource = fetched
                interpreterOrigin = "URL trong bgChallenge (host \(URL(string: urlString)?.host ?? "?"))"
            }
        }
        if interpreterSource == nil, let urlValue = bgChallenge["interpreterUrl"] {
            let urlString = (urlValue as? String)
                ?? ((urlValue as? [String: Any])?["privateDoNotAccessOrElseSafeResourceUrlWrappedValue"] as? String)
            if let urlString, let fetched = await fetchText(urlString, userAgent: Self.tizenUA) {
                interpreterSource = fetched
                interpreterOrigin = "interpreterUrl (host \(URL(string: urlString)?.host ?? "?"))"
            }
        }
        guard let interpreter = interpreterSource else {
            return .failed(step: "tv_config — bgChallenge không có interpreter dùng được (inline lẫn URL đều trống/hỏng)")
        }
        log("mint: interpreter từ \(interpreterOrigin) — \(interpreter.count) bytes")

        // 3 — Run BotGuard in the WebView.
        var challengeForJS: [String: Any] = [
            "program": program,
            "globalName": globalName,
            "interpreterJavascript": [
                "privateDoNotAccessOrElseSafeScriptWrappedValue": interpreter,
            ],
        ]
        if let blob = bgChallenge["clientExperimentsStateBlob"] as? String {
            challengeForJS["clientExperimentsStateBlob"] = blob
            log("mint: clientExperimentsStateBlob CÓ (len \(blob.count)) — chuyển kèm vào WebView")
        }
        guard let inputJSON = jsonEncodedObject(["challenge": challengeForJS]) else {
            return .failed(step: "mint — không JSON-encode được challenge để đưa vào WebView")
        }
        log("mint: nạp trang /tv vào WebView mint…")
        mintController.load(url: "https://www.youtube.com/tv",
                            userAgent: Self.tizenUA, lockedURL: nil)
        var pageReady = false
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if await evaluateMintJS("document.readyState") == "complete" {
                pageReady = true
                break
            }
        }
        guard pageReady else {
            return .failed(step: "WebView — trang /tv không load xong trong ~30s (readyState không tới complete)")
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        _ = await evaluateMintJS("window.__probeMintInput = \(inputJSON); 'set'")
        let installResult = await evaluateMintJS(Self.mintHarnessJS)
        log("mint: harness BotGuard cài xong (\(installResult ?? "không đáp")) — chờ snapshot…")
        guard installResult == "started" else {
            return .failed(step: "WebView — script mint không khởi động được (evaluate trả \(installResult ?? "nil"))")
        }
        let snapState = await pollMintState(terminalSteps: ["snapshot-done", "botguard-error", "gone"],
                                            timeoutSeconds: 60)
        guard let snapStep = snapState?["step"] as? String, snapStep == "snapshot-done" else {
            let step = (snapState?["step"] as? String) ?? "timeout"
            let error = (snapState?["error"] as? String) ?? ""
            return .failed(step: "BotGuard trong WebView dừng ở bước '\(step)'\(error.isEmpty ? "" : " — \(error)")")
        }
        guard let botguardResponse = await evaluateMintJS("window.__probeMintResult.botguardResponse"),
              !botguardResponse.isEmpty else {
            return .failed(step: "BotGuard — snapshot báo xong nhưng botguardResponse rỗng/không đọc được từ trang")
        }
        log("mint: snapshot OK — botguardResponse len \(botguardResponse.count) (không ghi giá trị)")

        // 4 — GenerateIT: botguardResponse → integrity token.
        let generateIT = await jnnPost("https://www.youtube.com/api/jnn/v1/GenerateIT",
                                       array: [requestKey, botguardResponse],
                                       userAgent: Self.tizenUA)
        log("mint: GenerateIT HTTP \(generateIT.http) · \(generateIT.bytes)B")
        guard generateIT.http == 200, let answer = generateIT.array,
              let tokenString = answer.first as? String,
              let integrityBytes = decodeBase64Loose(tokenString) else {
            return .failed(step: "GenerateIT — HTTP \(generateIT.http), đáp án không chứa integrity token ở phần tử [0]")
        }
        let ttl = answer.count > 1 ? (answer[1] as? NSNumber)?.intValue : nil
        log("mint: integrity token CÓ — \(integrityBytes.count)B · TTL \(ttl.map { "\($0)s" } ?? "?") (không ghi giá trị)")

        // 5 — obtainPoToken in the page → the session token.
        let bytesJSON = "[" + integrityBytes.map { "\($0)" }.joined(separator: ",") + "]"
        _ = await evaluateMintJS("window.__probeMintInput.integrityTokenBytes = \(bytesJSON); 'set'")
        guard let identifierJSON = jsonEncodedString(identifier) else {
            return .failed(step: "mint — không JSON-encode được identifier")
        }
        _ = await evaluateMintJS("window.__probeMintInput.identifier = \(identifierJSON); 'set'")
        let finishStep = await evaluateMintJS(Self.mintFinishJS)
        guard finishStep == "token-done" else {
            let error = await evaluateMintJS("window.__probeMint.error") ?? ""
            return .failed(step: "obtainPoToken trong WebView dừng ở bước '\(finishStep ?? "không đáp")'\(error.isEmpty ? "" : " — \(error)")")
        }
        guard let tokenB64 = await evaluateMintJS("window.__probeMint.tokenB64"),
              let tokenData = decodeBase64Loose(tokenB64), !tokenData.isEmpty else {
            return .failed(step: "obtainPoToken — tokenB64 không đọc/giải mã được từ trang")
        }
        log("mint: PO token ĐÃ MINT — len \(tokenData.count) (chỉ ghi độ dài; giá trị không rời máy trừ trong request SABR)")
        return .token(tokenData)
    }

    /// The BotGuard harness — a faithful port of the
    /// canonical po_token.html BotGuardClient (BgUtils /
    /// NewPipe), restructured to explicit global state
    /// (the sanctioned this-binding fix). Runs the
    /// interpreter, drives vm.a, snapshots. State lands in
    /// window.__probeMint; the snapshot result in
    /// window.__probeMintResult.
    static let mintHarnessJS = #"""
        (function () {
          var S = window.__probeMint = {
            step: 'init', error: '', tokenB64: '', tokenLen: 0, bgResponseLen: 0
          };
          var BG = { vmFunctions: null, syncSnapshotFunction: null };

          function loadBotGuard(challengeData) {
            var vm = window[challengeData.globalName];
            if (!vm) throw new Error('[BotGuardClient]: VM not found in the global object');
            if (!vm.a) throw new Error('[BotGuardClient]: Could not load program');
            var vmFunctionsCallback = function (asyncSnapshotFunction, shutdownFunction,
                                                passEventFunction, checkCameraFunction) {
              BG.vmFunctions = {
                asyncSnapshotFunction: asyncSnapshotFunction,
                shutdownFunction: shutdownFunction,
                passEventFunction: passEventFunction,
                checkCameraFunction: checkCameraFunction
              };
            };
            BG.syncSnapshotFunction = vm.a(challengeData.program, vmFunctionsCallback, true,
              document.body, function () {}, [[], []])[0];
            return new Promise(function (resolve, reject) {
              var i = 0;
              var refreshIntervalId = setInterval(function () {
                if (BG.vmFunctions && BG.vmFunctions.asyncSnapshotFunction) {
                  resolve(BG);
                  clearInterval(refreshIntervalId);
                }
                if (i >= 10000) {
                  reject(new Error('asyncSnapshotFunction is null even after 10 seconds'));
                  clearInterval(refreshIntervalId);
                }
                i += 1;
              }, 1);
            });
          }

          function snapshot(args) {
            return new Promise(function (resolve, reject) {
              if (!BG.vmFunctions || !BG.vmFunctions.asyncSnapshotFunction) {
                reject(new Error('[BotGuardClient]: Async snapshot function not found'));
                return;
              }
              BG.vmFunctions.asyncSnapshotFunction(function (response) { resolve(response); }, [
                args.contentBinding,
                args.signedTimestamp,
                args.webPoSignalOutput,
                args.skipPrivacyBuffer
              ]);
            });
          }

          function runBotGuard(challengeData) {
            var interpreterJavascript =
              challengeData.interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue;
            if (interpreterJavascript) {
              new Function(interpreterJavascript)();
            } else {
              throw new Error('Could not load VM');
            }
            var webPoSignalOutput = [];
            return loadBotGuard({
              globalName: challengeData.globalName,
              program: challengeData.program
            }).then(function () {
              return snapshot({ webPoSignalOutput: webPoSignalOutput });
            }).then(function (botguardResponse) {
              return { webPoSignalOutput: webPoSignalOutput, botguardResponse: botguardResponse };
            });
          }

          function obtainPoToken(webPoSignalOutput, integrityToken, identifier) {
            var getMinter = webPoSignalOutput[0];
            if (!getMinter) throw new Error('PMD:Undefined');
            var mintCallback = getMinter(integrityToken);
            if (!(mintCallback instanceof Function)) throw new Error('APF:Failed');
            var result = mintCallback(identifier);
            if (!result) throw new Error('YNJ:Undefined');
            if (!(result instanceof Uint8Array)) throw new Error('ODM:Invalid');
            return result;
          }

          window.__probeMintObtain = obtainPoToken;

          var input = window.__probeMintInput || {};
          S.step = 'running-botguard';
          runBotGuard(input.challenge).then(function (result) {
            window.__probeMintResult = result;
            S.bgResponseLen = result.botguardResponse ? String(result.botguardResponse).length : 0;
            S.step = 'snapshot-done';
          }).catch(function (e) {
            S.step = 'botguard-error';
            S.error = String((e && e.message) || e).slice(0, 120);
          });
          return 'started';
        })()
        """#

    /// Second mint half: integrity token + identifier in,
    /// PO token (base64) out via window.__probeMint.
    static let mintFinishJS = #"""
        (function () {
          var S = window.__probeMint;
          var input = window.__probeMintInput || {};
          var result = window.__probeMintResult;
          try {
            if (!result) throw new Error('no snapshot result');
            var integrity = new Uint8Array(input.integrityTokenBytes || []);
            var identifier = new TextEncoder().encode(String(input.identifier || ''));
            var token = window.__probeMintObtain(result.webPoSignalOutput, integrity, identifier);
            var binary = '';
            for (var i = 0; i < token.length; i++) binary += String.fromCharCode(token[i]);
            S.tokenB64 = btoa(binary);
            S.tokenLen = token.length;
            S.step = 'token-done';
          } catch (e) {
            S.step = 'mint-error';
            S.error = String((e && e.message) || e).slice(0, 120);
          }
          return S.step;
        })()
        """#

    // MARK: The run

    private func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        lines = []
        verdict = ""
        userCode = nil

        log("=== PROBE 13 — SABR PHA 1B (fetcher + PO token) ===")
        log("Tập Gold: \(ProbeTargets.goldEp1) · Mục tiêu: mint PO token theo recipe TV rồi gắn vào SABR — attestation qua được không + AVC/AAC? + segment thật? — chỉ fetch + parse, KHÔNG phát hình")

        guard let initialToken = await acquireToken() else {
            finish("SABR PHA 1B: KHÔNG KẾT ÁN ĐƯỢC — không lấy được access token (xem các dòng identity ở trên)")
            return
        }

        guard let spec = tvSpec() else {
            finish("SABR PHA 1B: KHÔNG KẾT ÁN ĐƯỢC — không đọc được spec TVHTML5 từ ladder đóng gói")
            return
        }

        // /player, with one refresh retry and one
        // device-code retry on a 401.
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
            finish("SABR PHA 1B: KHÔNG KẾT ÁN ĐƯỢC — /player HTTP \(player.http) sau mọi lần thử identity")
            return
        }
        let playability = (json["playabilityStatus"] as? [String: Any])?["status"] as? String ?? "?"
        let playabilityReason = (json["playabilityStatus"] as? [String: Any])?["reason"] as? String
        log("player: HTTP 200 · playability=\(playability)\(playabilityReason.map { " · reason \"\($0)\"" } ?? "")")
        guard playability == "OK" else {
            finish("SABR PHA 1B: KHÔNG KẾT ÁN ĐƯỢC — playability=\(playability) (không phải OK) nên không có SABR stream để thử")
            return
        }

        let streaming = json["streamingData"] as? [String: Any]
        guard let sabrURLString = streaming?["serverAbrStreamingUrl"] as? String,
              let sabrBaseURL = URL(string: sabrURLString) else {
            log("player: serverAbrStreamingUrl = NO — response này không phải SABR")
            finish("SABR PHA 1B: KHÔNG KẾT ÁN ĐƯỢC — /player không trả serverAbrStreamingUrl")
            return
        }
        log("player: serverAbrStreamingUrl = YES · host \(sabrBaseURL.host ?? "?")")

        let (ustreamerConfig, ustreamerSource) = extractUstreamerConfig(json)
        if let ustreamerConfig {
            log("player: ustreamerConfig từ \(ustreamerSource) — \(ustreamerConfig.count) bytes (base64 đã giải)")
        } else {
            log("player: ustreamerConfig — \(ustreamerSource); request SABR sẽ thiếu field 5 (server có thể từ chối — đó cũng là một kết quả)")
        }

        // Format inventory — answers the WebM-only kill
        // question before any SABR byte is requested.
        let rawFormats = streaming?["adaptiveFormats"] as? [[String: Any]] ?? []
        let formats: [SabrPlayerFormat] = rawFormats.map { raw in
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
        let muxedCount = (streaming?["formats"] as? [[String: Any]])?.count ?? 0
        log("player: adaptiveFormats=\(formats.count) · muxed=\(muxedCount)")
        for format in formats {
            let dims = format.isVideo ? " \(format.width)x\(format.height)" : ""
            log("player: fmt itag \(format.itag) \"\(format.mimeType)\"\(dims) bitrate \(format.bitrate) lmt \(format.lastModified)")
        }
        let avcVideos = formats.filter { $0.isVideo && $0.isAvc }
        let aacAudios = formats.filter { $0.isAudio && $0.isAac }
        let vp9Count = formats.filter { $0.mimeType.lowercased().contains("vp9") }.count
        let opusCount = formats.filter { $0.mimeType.lowercased().contains("opus") }.count
        log("player: AVC(avc1) video = \(avcVideos.count) · AAC(mp4a) audio = \(aacAudios.count) · VP9 = \(vp9Count) · Opus = \(opusCount)")
        log("player: KẾT LUẬN FORMAT — AVC video: \(avcVideos.isEmpty ? "KHÔNG CÓ" : "CÓ") · AAC audio: \(aacAudios.isEmpty ? "KHÔNG CÓ" : "CÓ")")

        let videoChoice = avcVideos.filter { $0.height <= 1080 }
            .max(by: { ($0.bitrate, $0.height) < ($1.bitrate, $1.height) })
            ?? avcVideos.max(by: { $0.bitrate < $1.bitrate })
        let audioChoice = aacAudios.max(by: { $0.bitrate < $1.bitrate })

        if formats.isEmpty {
            finish("SABR PHA 1B: KHÔNG KẾT ÁN ĐƯỢC — /player OK nhưng adaptiveFormats rỗng")
            return
        }
        if avcVideos.isEmpty {
            log("player: toàn bộ video là VP9/WebM (hoặc codec khác ngoài avc1) — AVPlayer không nạp được")
            finish("SABR PHA 1B: KHÔNG KẾT ÁN ĐƯỢC — chết ở format: không có AVC (avc1), chỉ có WebM/VP9 (AVPlayer không nạp được)")
            return
        }
        if let videoChoice {
            log("chọn: VIDEO itag \(videoChoice.itag) \"\(videoChoice.mimeType)\" \(videoChoice.width)x\(videoChoice.height) bitrate \(videoChoice.bitrate)")
        }
        if let audioChoice {
            log("chọn: AUDIO itag \(audioChoice.itag) \"\(audioChoice.mimeType)\" bitrate \(audioChoice.bitrate)")
        } else {
            log("chọn: AUDIO — KHÔNG có AAC; vẫn thử SABR bằng video đơn lẻ (attestation vẫn kết án được)")
        }

        // Phase 1B: mint the TV session PO token. A mint
        // failure IS the verdict (the study's named
        // NO-GO) — the token-less POSTs are not repeated;
        // phase 1 already measured them (403, 0 bytes).
        log("mint: bắt đầu chặng PO token — recipe TV: /tv scrape → tv_config → BotGuard trong WebView → GenerateIT → obtainPoToken")
        let poToken: Data
        switch await mintPoToken() {
        case .failed(let step):
            finish("SABR PHA 1B: MINT THẤT BẠI — \(step)")
            return
        case .token(let minted):
            poToken = minted
            log("mint: token sẵn sàng (len \(minted.count)) — gắn vào streamer_context.po_token (field 2) cho cả init + media")
        }

        // SABR requests: init (rn=0), media (rn=1), at
        // most one redirect follow (rn=2).
        let state = SabrRunState()
        var currentURL = sabrBaseURL
        var followedRedirect = false

        let initBody = sabrBuildRequest(
            clientVersion: spec.clientVersion,
            ustreamerConfig: ustreamerConfig,
            preferredVideo: videoChoice,
            preferredAudio: audioChoice,
            selected: [],
            playbackCookie: nil,
            poToken: poToken,
            videoHeight: videoChoice?.height ?? 0,
            videoBitrate: videoChoice?.bitrate ?? 0)
        log("sabr[init]: POST rn=0 · body \(initBody.count)B · selected=[] (init) · preferred video \(videoChoice?.itag ?? -1) / audio \(audioChoice?.itag ?? -1) · poToken CÓ (len \(poToken.count))")
        let initResponse = await sabrPost(baseURL: currentURL, rn: 0, body: initBody, userAgent: spec.userAgent)
        let initHTTP = initResponse.http
        processSabrResponse(label: "init rn=0", http: initResponse.http,
                            data: initResponse.data, contentType: initResponse.contentType,
                            state: state)
        if let redirect = state.redirectURL, !followedRedirect {
            followedRedirect = true
            state.redirectURL = nil
            if let newURL = URL(string: redirect) {
                currentURL = newURL
                log("sabr: theo redirect (lượt duy nhất) — request kế tiếp đi host \(newURL.host ?? "?")")
            }
        }

        if state.backoffMs > 0 {
            let waitMs = min(state.backoffMs, 5000)
            log("sabr: server yêu cầu backoff \(state.backoffMs)ms — chờ \(waitMs)ms trước request media")
            try? await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
        }

        let selected = [videoChoice, audioChoice].compactMap { $0 }
        let mediaBody = sabrBuildRequest(
            clientVersion: spec.clientVersion,
            ustreamerConfig: ustreamerConfig,
            preferredVideo: videoChoice,
            preferredAudio: audioChoice,
            selected: selected,
            playbackCookie: state.playbackCookie,
            poToken: poToken,
            videoHeight: videoChoice?.height ?? 0,
            videoBitrate: videoChoice?.bitrate ?? 0)
        log("sabr[media]: POST rn=1 · body \(mediaBody.count)B · selected=\(selected.map { String($0.itag) }.joined(separator: ",")) · playbackCookie \(state.playbackCookie != nil ? "CÓ (echo)" : "không") · poToken CÓ (len \(poToken.count))")
        let mediaResponse = await sabrPost(baseURL: currentURL, rn: 1, body: mediaBody, userAgent: spec.userAgent)
        processSabrResponse(label: "media rn=1", http: mediaResponse.http,
                            data: mediaResponse.data, contentType: mediaResponse.contentType,
                            state: state)
        if let redirect = state.redirectURL {
            if !followedRedirect, let newURL = URL(string: redirect) {
                followedRedirect = true
                state.redirectURL = nil
                log("sabr: theo redirect (lượt duy nhất) — POST lại request media sang host \(newURL.host ?? "?")")
                let followResponse = await sabrPost(baseURL: newURL, rn: 2, body: mediaBody, userAgent: spec.userAgent)
                processSabrResponse(label: "media-redirect rn=2", http: followResponse.http,
                                    data: followResponse.data, contentType: followResponse.contentType,
                                    state: state)
            } else {
                let host = URL(string: redirect)?.host ?? "?"
                log("sabr: redirect NỮA sang host \(host) — KHÔNG theo (đã dùng lượt theo duy nhất)")
            }
        }

        // Per-format completion + final inventory.
        func completionNote(_ format: SabrPlayerFormat?, kind: String) -> Bool {
            guard let format else { return false }
            let initDone = state.tracker.completedInitItags.contains(format.itag)
            let mediaDone = state.tracker.completedMediaItags.contains(format.itag)
            let bytes = state.tracker.mediaBytesByItag[format.itag] ?? 0
            log("soát: \(kind) itag \(format.itag) — init hoàn chỉnh: \(initDone ? "ĐẠT" : "CHƯA") · media segment hoàn chỉnh: \(mediaDone ? "ĐẠT" : "CHƯA") · media bytes: \(bytes)")
            return initDone && mediaDone && bytes > 0
        }
        let videoComplete = completionNote(videoChoice, kind: "VIDEO")
        let audioComplete = completionNote(audioChoice, kind: "AUDIO")
        let mediaComplete = videoComplete || audioComplete
        if state.tracker.danglingMediaBytes > 0 {
            log("soát: \(state.tracker.danglingMediaBytes)B media không khớp header nào đã biết")
        }
        let totalParts = state.partCounts.values.reduce(0) { $0 + $1.count }
        log("soát: tổng \(totalParts) part · format-init itags: \(state.formatInitItags.isEmpty ? "không" : state.formatInitItags.map { "\($0)" }.joined(separator: ",")) · protection statuses: \(state.protectionSeen.isEmpty ? "không có part nào" : state.protectionSeen.map { "\($0)" }.joined(separator: ","))")

        // Verdict — phase 1B strings (the leader's brief,
        // verbatim shapes).
        if state.protectionSeen.contains(3) {
            finish("SABR PHA 1B: CHẶN Ở ATTESTATION — status=ATTESTATION_REQUIRED (3)")
            return
        }
        if state.protectionSeen.last == 2, !mediaComplete {
            finish("SABR PHA 1B: CHẶN Ở ATTESTATION — status=ATTESTATION_PENDING (2)")
            return
        }
        if videoComplete, audioComplete, let videoChoice, let audioChoice {
            let protectionLabel: String
            if let lastStatus = state.protectionSeen.last {
                protectionLabel = lastStatus == 1 ? "OK (1)"
                    : (lastStatus == 2 ? "ATTESTATION_PENDING (2)" : "\(lastStatus)")
            } else {
                protectionLabel = "không có part"
            }
            finish("SABR PHA 1B: ĐẠT — segment thật đã về (video itag \(videoChoice.itag) init+media hoàn chỉnh, audio itag \(audioChoice.itag) init+media hoàn chỉnh), protection=\(protectionLabel)")
            return
        }
        if initHTTP == 403 {
            finish("SABR PHA 1B: MINT OK NHƯNG VẪN 403 — token len \(poToken.count) đã gắn, POST init vẫn HTTP 403")
            return
        }
        var why = "init/media hoàn chỉnh: video \(videoComplete ? "ĐẠT" : "CHƯA"), audio \(audioComplete ? "ĐẠT" : "CHƯA")"
        if let firstError = state.sabrErrors.first {
            why += "; SabrError type=\"\(firstError.type)\" code=\(firstError.code)"
        }
        if state.sawReload { why += "; server trả RELOAD_PLAYER_RESPONSE" }
        if let note = state.transportNote { why += "; \(note)" }
        if state.protectionUndecodable > 0 { why += "; \(state.protectionUndecodable) part protection không giải mã được" }
        why += "; tổng \(totalParts) part đã kiểm kê ở trên"
        finish("SABR PHA 1B: KHÔNG KẾT ÁN ĐƯỢC — \(why)")
    }

    static func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm dd/MM"
        return formatter.string(from: date)
    }
}

// MARK: - View

struct SabrProbeView: View {
    var onExit: () -> Void
    @StateObject private var model = SabrProbeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Probe 13 — SABR pha 1B (fetcher + PO token)")
                .font(.title3).bold()
            Text("Như pha 1 (danh tính OAuth của Probe 9 — mất token thì tự chạy lại cửa device-code tại đây; /player TVHTML5 cho tập Gold; POST thử SABR, kiểm kê từng part UMP) — cộng chặng mới: mint PO token theo recipe TV (tv_config → BotGuard trong WebView bên dưới → GenerateIT) rồi gắn vào request SABR. Chỉ fetch + parse — không phát hình.")
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
                    .foregroundStyle(model.verdict.hasPrefix("SABR PHA 1B: ĐẠT") ? Color.green : Color.red)
            }
            Text("Bề mặt WebView cho chặng mint BotGuard (recipe TV) — nó tự chạy khi tới chặng mint, không cần bấm gì:")
                .font(.footnote).foregroundStyle(.secondary)
            ProbeWebView(controller: model.mintController,
                         navigationMode: .doorRoam,
                         playbackPresses: false)
                .frame(height: 150)
                .background(Color.black)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Button(model.running ? "Đang chạy…" : "Chạy lại Probe 13") {
                model.rerun()
            }
            .disabled(model.running)
        }
        .padding(28)
        .onExitCommand { onExit() }
        .task { model.start() }
    }
}
