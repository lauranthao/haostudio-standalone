// HAo Studio 2.0 — Huya anti-code signing + URL lease math (S4 leg B).
//
// Swift port of the pure functions in the Flutter
// `lib/shared/platforms/huya/huya_anti_code.dart` (itself a port of
// the pure functions in Pure Live 3.x `huya_site.dart`):
// `buildAntiCode`, `rotateViewerUid32` / `unrotateViewerUid32`,
// `replaceQueryParameter`, `secureHuyaCdnBase`,
// `getSignedSequenceIssuedAt`, `_signedUrlInvalidAtFromQuery`,
// plus the lease constants.
//
// How it works: decode the base64 `fm` template, substitute
// `$0=rotatedUid, $1=stream, $2=md5("$seqid|$ctype|$platformId"),
// $3=wsTime`, compute `wsSecret=md5(template)`, and emit
// `wsSecret/wsTime/seqid(=uid+millis)/ctype/ver/fs/t/u|uid/uuid`
// (the `fm` template itself is consumed locally and omitted from
// the URL, as the official web player does).
//
// Rules the port keeps verbatim:
// - An anti-code with no `fm` param is returned unchanged (legacy
//   static token — nothing to sign).
// - `wsTime` is never extended locally: a missing/invalid `wsTime`
//   throws, and `now > wsTime + 5 min` throws instead of signing.
// - Only the low 32-bit lane of the viewer UID is rotated; the
//   upper lane is preserved (returning only the rotated low lane
//   truncates real anonymous UIDs — normally > 2^32 — and the CDN
//   rejects the URL with HTTP 403).
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

enum HuyaAntiCodeError: Error {
    case missingWsTime
    case templateIncomplete
    case leaseExpired
    case invalidBase64
}

extension HuyaAntiCodeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingWsTime:
            return "虎牙 anti-code 缺少有效的 wsTime"
        case .templateIncomplete:
            return "虎牙 anti-code fm 模板不完整"
        case .leaseExpired:
            return "虎牙 anti-code 租约已过期"
        case .invalidBase64:
            return "虎牙 anti-code fm 不是合法的 base64"
        }
    }
}

enum HuyaAntiCode {
    /// Proactive refresh: transport lease age after which a fresh
    /// URL should be prefetched (before the transport dies — do not
    /// wait for EOF). Seconds.
    static let transportRefreshAgeSeconds: TimeInterval = 100

    /// Hard transport expiry: CDN transport lifetime after issue.
    /// Seconds.
    static let transportInvalidAgeSeconds: TimeInterval = 125

    /// Signature validity after wsTime: wsTime (hex seconds) + 5 min.
    /// Seconds.
    static let signatureValiditySeconds: TimeInterval = 300

    /// Refresh a signature 30 s before its wsTime+5min expiry.
    /// Seconds.
    static let signatureRefreshLeadSeconds: TimeInterval = 30

    /// Builds the per-open AntiCode for one stream line.
    /// `randomDouble` supplies the two random draws (uuid/ct) so
    /// tests can pin them; production passes the default.
    static func build(
        stream: String,
        viewerUid: Int,
        antiCode: String,
        now: Date = Date(),
        fallbackViewerUid: Int = 0,
        randomDouble: () -> Double = { Double.random(in: 0..<1) }
    ) throws -> String {
        let original = LiveQuery.parse(antiCode)
        let encodedFm = original.first { $0.0 == "fm" }?.1.trimmingCharacters(in: .whitespaces) ?? ""
        if encodedFm.isEmpty {
            return antiCode
        }
        let ctype = nonEmpty(original.first { $0.0 == "ctype" }?.1) ?? "huya_webh5"
        let platformId = nonEmpty(original.first { $0.0 == "t" }?.1) ?? "100"
        let isWap = platformId == "103"
        let nowSeconds = Int(now.timeIntervalSince1970)
        let currentMillis = Int(now.timeIntervalSince1970 * 1000)
        let uid = viewerUid > 0 ? viewerUid : fallbackViewerUid

        let wsTimeRaw = original.first { $0.0 == "wsTime" }?.1.trimmingCharacters(in: .whitespaces) ?? ""
        guard let wsTimeSeconds = Int(wsTimeRaw, radix: 16) else {
            throw HuyaAntiCodeError.missingWsTime
        }
        if nowSeconds > wsTimeSeconds + Int(signatureValiditySeconds) {
            throw HuyaAntiCodeError.leaseExpired
        }
        let wsTime = wsTimeRaw.lowercased()
        let seqId = uid + currentMillis
        let secretHash = LiveCrypto.md5Hex("\(seqId)|\(ctype)|\(platformId)")

        let convertedUid = rotateViewerUid32(uid)
        let calcUid = isWap ? uid : convertedUid
        guard let templateData = Data(base64Encoded: normalizedBase64(encodedFm)) else {
            throw HuyaAntiCodeError.invalidBase64
        }
        guard let secretTemplate = String(data: templateData, encoding: .utf8) else {
            throw HuyaAntiCodeError.templateIncomplete
        }
        for placeholder in ["$0", "$1", "$2", "$3"] {
            if !secretTemplate.contains(placeholder) {
                throw HuyaAntiCodeError.templateIncomplete
            }
        }
        let secretString = secretTemplate
            .replacingFirstOccurrence(of: "$0", with: String(calcUid))
            .replacingFirstOccurrence(of: "$1", with: stream)
            .replacingFirstOccurrence(of: "$2", with: secretHash)
            .replacingFirstOccurrence(of: "$3", with: wsTime)
        let wsSecret = LiveCrypto.md5Hex(secretString)

        let firstRandom = randomDouble()
        let secondRandom = randomDouble()
        let ct = Int((Double(wsTimeSeconds) + firstRandom) * 1000)
        let uuid = Int(((Double(ct % 10000000000) + secondRandom) * 1000).truncatingRemainder(dividingBy: 4294967295))
        var result: [(String, String)] = []
        // Every key the addAll below sets is removed here first:
        // Dart's map addAll REPLACES an existing key in place, so
        // keeping the original would emit the key twice.
        for pair in original {
            if ["wsSecret", "seqid", "u", "uid", "uuid", "fm", "wsTime", "ctype", "ver", "fs", "t"].contains(pair.0) {
                continue
            }
            result.append(pair)
        }
        result.append(("wsSecret", wsSecret))
        result.append(("wsTime", wsTime))
        result.append(("seqid", String(seqId)))
        result.append(("ctype", ctype))
        result.append(("ver", "1"))
        result.append(("fs", original.first { $0.0 == "fs" }?.1 ?? "bgct"))
        result.append(("t", platformId))
        if isWap {
            result.append(("uid", String(uid)))
            result.append(("uuid", String(uuid)))
        } else {
            result.append(("u", String(convertedUid)))
        }
        return LiveQuery.build(result)
    }

    /// Huya's web player names this `rotl64`: only the low 32-bit
    /// lane is rotated, the upper 32-bit lane of the 64-bit viewer
    /// UID is preserved.
    static func rotateViewerUid32(_ value: Int) -> Int {
        let low = UInt64(bitPattern: Int64(value)) & 0xFFFFFFFF
        let high = UInt64(bitPattern: Int64(value)) - low
        let rotatedLow = ((low << 8) | (low >> 24)) & 0xFFFFFFFF
        return Int(Int64(bitPattern: high | rotatedLow))
    }

    static func unrotateViewerUid32(_ value: Int) -> Int {
        let low = UInt64(bitPattern: Int64(value)) & 0xFFFFFFFF
        let high = UInt64(bitPattern: Int64(value)) - low
        let originalLow = ((low >> 8) | (low << 24)) & 0xFFFFFFFF
        return Int(Int64(bitPattern: high | originalLow))
    }

    /// Replaces (or removes, when `value` is nil) one query
    /// parameter in an `a=b&c=d` string, preserving order and
    /// de-duplicating the key.
    static func replaceQueryParameter(_ query: String, key: String, value: String?) -> String {
        var output: [String] = []
        var replaced = false
        for segment in query.split(separator: "&") {
            if segment.isEmpty {
                continue
            }
            let text = String(segment)
            let separator = text.firstIndex(of: "=")
            let segmentKey = separator.map { String(text[..<$0]) } ?? text
            if segmentKey != key {
                output.append(text)
                continue
            }
            if !replaced, let value = value {
                output.append("\(key)=\(value)")
            }
            replaced = true
        }
        if !replaced, let value = value {
            output.append("\(key)=\(value)")
        }
        return output.joined(separator: "&")
    }

    /// Upgrades an http:// Huya CDN base to https://; anything else
    /// is returned unchanged.
    static func secureCdnBase(_ base: String) -> String {
        guard let url = URL(string: base), url.scheme == "http" else {
            return base
        }
        guard let host = url.host, host == "huya.com" || host.hasSuffix(".huya.com") else {
            return base
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url?.absoluteString ?? base
    }

    /// Hard signature expiry of a signed URL: wsTime (hex) + 5 min.
    /// Nil when the URL carries no parseable wsTime.
    static func signedUrlInvalidAt(_ url: String) -> Date? {
        guard let query = URL(string: url)?.query else {
            return nil
        }
        guard let wsTimeRaw = LiveQuery.value(query, key: "wsTime") else {
            return nil
        }
        guard let wsTimeSeconds = Int(wsTimeRaw, radix: 16) else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(wsTimeSeconds) + signatureValiditySeconds)
    }

    /// Recovers the issue time encoded by the official web player's
    /// `seqid = viewerUid + Date.now()` contract. The CDN can close
    /// a signed transport roughly two minutes after this point while
    /// `wsTime` is still valid, so the issue time is the stable
    /// transport-age anchor. It must not be recomputed from the time
    /// this method happens to be called.
    static func signedSequenceIssuedAt(_ url: String) -> Date? {
        guard let query = URL(string: url)?.query else {
            return nil
        }
        guard let seqId = Int(LiveQuery.value(query, key: "seqid") ?? "") else {
            return nil
        }
        let isWap = LiveQuery.value(query, key: "t") == "103"
        let encodedKey = isWap ? "uid" : "u"
        guard let encodedUid = Int(LiveQuery.value(query, key: encodedKey) ?? "") else {
            return nil
        }
        let viewerUid = isWap ? encodedUid : unrotateViewerUid32(encodedUid)
        let issuedMillis = seqId - viewerUid
        if issuedMillis <= 0 {
            return nil
        }
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(issuedMillis) / 1000)
        if issuedAt < Date(timeIntervalSince1970: 1577836800) {
            return nil
        }
        if issuedAt > Date(timeIntervalSince1970: 4102444800) {
            return nil
        }
        if let signedInvalidAt = signedUrlInvalidAt(url), issuedAt > signedInvalidAt {
            return nil
        }
        return issuedAt
    }

    /// Proactive refresh deadline for one signed URL: the earliest
    /// of (wsTime expiry minus 30 s) and (transport issue + 100 s).
    /// Nil when no expiry can be derived from the URL at all.
    /// `transportIssuedAt` overrides the seqid-derived issue time
    /// (used for legacy/static-token lines whose seqid carries no
    /// issue instant).
    static func playUrlRefreshAt(_ url: String, now: Date = Date(), transportIssuedAt: Date? = nil) -> Date? {
        let current = now
        let signedInvalidAt = signedUrlInvalidAt(url)
        let issuedAt = transportIssuedAt ?? signedSequenceIssuedAt(url)
        var refreshAt: Date?
        if let signedInvalidAt = signedInvalidAt {
            refreshAt = signedInvalidAt.addingTimeInterval(-signatureRefreshLeadSeconds)
        }
        if let issuedAt = issuedAt {
            let transportRefreshAt = issuedAt.addingTimeInterval(transportRefreshAgeSeconds)
            if refreshAt == nil || transportRefreshAt < refreshAt! {
                refreshAt = transportRefreshAt
            }
        }
        guard let deadline = refreshAt else {
            return nil
        }
        return deadline > current ? deadline : current
    }

    // MARK: - Helpers

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// Dart's `base64.normalize` pads a base64 string to a multiple
    /// of four; Swift's decoder requires the padding.
    private static func normalizedBase64(_ value: String) -> String {
        let stripped = value.trimmingCharacters(in: .whitespaces)
        let remainder = stripped.count % 4
        if remainder == 0 {
            return stripped
        }
        return stripped + String(repeating: "=", count: 4 - remainder)
    }
}

private extension String {
    /// Replace only the FIRST occurrence (Dart `replaceFirst`).
    func replacingFirstOccurrence(of target: String, with replacement: String) -> String {
        guard let range = self.range(of: target) else {
            return self
        }
        var result = self
        result.replaceSubrange(range, with: replacement)
        return result
    }
}
