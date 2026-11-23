// MusicQuality.swift
// Audio-quality mappings and the Master honesty gate.
//
// Codes: the Swift `AudioQuality` cases (contract in
// `PlaybackCoordinator.swift`) map to LX/API codes as follows —
// master->`master`, hiRes->`hires`, flac->`lossless`,
// high320->`320k`, standard128->`128k`. The downgrade chain is
// best-first: `[master, hiRes, flac, high320, standard128]`.
//
// Master honesty gate (Flutter `music_quality.dart` parity):
// only a resolver/script/API that genuinely served Master may
// label its result Master. A lower-tier URL plays immediately as a
// drop-down — it is never labelled Master, and the target tier
// persists to the next track.

import Foundation

extension AudioQuality {
    /// LX / platform-API quality code for this tier.
    var lxCode: String {
        switch self {
        case .master: return "master"
        case .hiRes: return "hires"
        case .flac: return "lossless"
        case .high320: return "320k"
        case .standard128: return "128k"
        }
    }

    /// The quality parameter most direct APIs take. Master maps to
    /// each API's best known parameter — never to a parameter the API
    /// does not understand, never to a low tier. Only the LX APIs
    /// (zddyr/xinghai) get a literal `master` (see `lxCode`).
    var srcCode: String {
        switch self {
        case .master, .hiRes, .flac: return "flac"
        case .high320: return "320k"
        case .standard128: return "128k"
        }
    }

    /// NetEase song-level parameter.
    var songLevel: String {
        switch self {
        case .master, .hiRes, .flac: return "lossless"
        case .high320: return "exhigh"
        case .standard128: return "standard"
        }
    }

    /// Downgrade chain from the requested tier, best first.
    /// `qualityChainFrom(.master)` is the full chain.
    static func chain(from requested: AudioQuality) -> [AudioQuality] {
        let all: [AudioQuality] = [.master, .hiRes, .flac, .high320, .standard128]
        guard let index = all.firstIndex(of: requested) else { return all }
        return Array(all[index...])
    }

    /// Rank for candidate comparison (higher is better).
    var rank: Int {
        switch self {
        case .master: return 5
        case .hiRes: return 4
        case .flac: return 3
        case .high320: return 2
        case .standard128: return 1
        }
    }
}

enum MusicQualityGate {
    /// Pick the quality string to ask an LX script for, given the
    /// qualities that script declares for the platform. Nil when the
    /// script cannot serve the requested tier at all (the caller then
    /// skips the script; the resolver chain downgrades).
    /// - master: only a literal `master` counts — never substitute hires.
    /// - hiRes: `hires`, else `flac24bit`, else `flac`.
    /// - flac: `flac`, else `flac24bit`.
    /// - 320k/128k: literal only.
    static func lxQualityForScript(_ quality: AudioQuality, available: [String]) -> String? {
        switch quality {
        case .master:
            return available.contains("master") ? "master" : nil
        case .hiRes:
            if available.contains("hires") { return "hires" }
            if available.contains("flac24bit") { return "flac24bit" }
            if available.contains("flac") { return "flac" }
            return nil
        case .flac:
            if available.contains("flac") { return "flac" }
            if available.contains("flac24bit") { return "flac24bit" }
            return nil
        case .high320:
            return available.contains("320k") ? "320k" : nil
        case .standard128:
            return available.contains("128k") ? "128k" : nil
        }
    }

    /// What a resolver ACTUALLY returns at the requested tier (the
    /// declared label, used when the resolver reports no tier).
    /// Master gate: only `zddyr` and `xinghai` (LX APIs with a
    /// verified real Master path) may claim Master. Every other
    /// resolver — including LX scripts (`lx:*`) — caps at hires: a
    /// script that returns a bare URL string carries no tier signal.
    /// A script keeps Master ONLY when it returns a
    /// `{url, quality: 'master'}` map (see `reportedTierFor`).
    static func declaredTier(resolverKey: String, requested: AudioQuality) -> AudioQuality {
        guard requested == .master else { return requested }
        switch resolverKey {
        case "zddyr", "xinghai":
            return .master
        default:
            return .hiRes
        }
    }

    /// Pure tier check for a script-reported tier string: at a master
    /// request, only a literal `master` report keeps master; any
    /// other report is hires. Other requests keep the declared label
    /// (nil = no override).
    static func reportedTierFor(reported: String?, requested: AudioQuality) -> AudioQuality? {
        guard requested == .master, let reported = reported else { return nil }
        return reported == "master" ? .master : .hiRes
    }

    /// LX-API served-tier check (zddyr/xinghai response): only
    /// `quality == 'master'` with no `quality_fallback` keeps the
    /// master label at a master request; anything the API actually
    /// served is hires (its best fallback tier). Other tiers carry
    /// no verifiable signal, so they keep the declared label (nil).
    static func lxApiServedTier(response: [String: Any], requested: AudioQuality) -> AudioQuality? {
        guard requested == .master else { return nil }
        let servedMaster = (response["quality"] as? String) == "master"
            && (response["quality_fallback"] as? Bool) != true
        return servedMaster ? .master : .hiRes
    }
}
