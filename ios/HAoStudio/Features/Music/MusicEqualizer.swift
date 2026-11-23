// HAo Studio 2.0 — equalizer data (S2-C leg).
//
// Pure EQ data ported from Flutter lib/services/music/equalizer_store.dart
// + autoeq_presets.dart + lib/features/music/equalizer_page.dart:
// - 10 bands [31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k] Hz, ±12 dB,
//   0.5 dB steps (Beans normalizedGain);
// - 8 built-in presets with Beans' exact gain tables;
// - 8 AutoEq headphone presets. The AutoEq gains are COMMUNITY-STYLE
//   approximations, not complete measured curves (Flutter
//   autoeq_presets.dart says so itself) — the UI must say so, never
//   present them as measured.
// - preamp is a plain dB value here; the native player applies
//   10^(dB/20) (Flutter: preamp linear gain is native-side).
//
// The contract `EqualizerSettings` (player leg) is NOT defined here;
// the equalizer view model builds one from this data when applying.

import Foundation

enum MusicEQMath {
    static let bandFrequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let bandCount = 10
    static let maximumGain: Double = 12
    static let gainStep: Double = 0.5

    /// Beans normalizedGain: clamp ±12 dB, round to 0.5 dB steps.
    static func normalizeGain(_ value: Double) -> Double {
        let clamped = min(maximumGain, max(-maximumGain, value))
        return (clamped / gainStep).rounded() * gainStep
    }

    /// Normalise a 10-band list: pad short lists with 0, normalise
    /// each band, drop extras (Flutter normalizedGains, 10-band form).
    static func normalizeGains(_ values: [Double]) -> [Double] {
        var out: [Double] = []
        for i in 0..<bandCount {
            let value = i < values.count ? values[i] : 0
            out.append(normalizeGain(value))
        }
        return out
    }

    /// Frequency label (Beans EqualizerSettingsView.frequencyLabel):
    /// 31 Hz .. 500 Hz, 1 kHz .. 16 kHz.
    static func frequencyLabel(_ frequency: Double) -> String {
        if frequency >= 1000 {
            let value = frequency / 1000
            if value == value.rounded() {
                return "\(Int(value)) kHz"
            }
            return String(format: "%.1f kHz", value)
        }
        return "\(Int(frequency)) Hz"
    }

    /// Response preview = gains + preamp*0.35, clamped ±12
    /// (Flutter equalizer_page response preview).
    static func previewGains(gains: [Double], preamp: Double) -> [Double] {
        return normalizeGains(gains.map { $0 + preamp * 0.35 })
    }
}

/// Built-in preset ids (Beans `BeansEqualizerPreset`, minus custom).
/// Display names are Chinese, as in Beans.
enum MusicEqualizerPreset: String, CaseIterable {
    case flat
    case bass
    case vocal
    case pop
    case rock
    case classical
    case jazz
    case electronic

    var displayName: String {
        switch self {
        case .flat: return "默认"
        case .bass: return "低音增强"
        case .vocal: return "人声"
        case .pop: return "流行"
        case .rock: return "摇滚"
        case .classical: return "古典"
        case .jazz: return "爵士"
        case .electronic: return "电子"
        }
    }

    /// Beans preset.gains, copied exactly (BeansEqualizer.swift).
    var gains: [Double] {
        switch self {
        case .flat: return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bass: return [6, 5, 3, 1, 0, 0, -1, -1, 0, 0]
        case .vocal: return [-2, -1, 0, 2, 4, 4, 3, 2, 0, -1]
        case .pop: return [2, 2, 1, 0, 2, 3, 2, 1, 2, 2]
        case .rock: return [5, 4, 2, -1, -2, 1, 3, 4, 5, 4]
        case .classical: return [3, 2, 1, 0, 0, 1, 2, 3, 4, 4]
        case .jazz: return [3, 2, 1, 2, -1, -1, 0, 2, 3, 3]
        case .electronic: return [5, 4, 1, -2, -1, 2, 4, 3, 5, 4]
        }
    }

    static func fromId(_ id: String?) -> MusicEqualizerPreset {
        switch id {
        case "bass": return .bass
        case "vocal": return .vocal
        case "pop": return .pop
        case "rock": return .rock
        case "classical": return .classical
        case "jazz": return .jazz
        case "electronic": return .electronic
        default: return .flat
        }
    }
}

/// One user-saved custom preset (Beans `BeansEqualizerCustomPreset`).
struct MusicEqualizerCustomPreset: Equatable {
    var name: String
    var gains: [Double]
    var preamp: Double

    init(name: String, gains: [Double], preamp: Double) {
        self.name = name
        self.gains = MusicEQMath.normalizeGains(gains)
        self.preamp = MusicEQMath.normalizeGain(preamp)
    }

    init(json: [String: Any]) {
        let rawGains = (json["gains"] as? [Double]) ?? (json["gains"] as? [NSNumber])?.map { $0.doubleValue } ?? []
        self.init(
            name: MusicDict.string(json, "name"),
            gains: rawGains,
            preamp: MusicDict.double(json, "preamp")
        )
    }

    func toJSON() -> [String: Any] {
        return ["name": name, "gains": gains, "preamp": preamp]
    }
}

/// AutoEq headphone presets (Flutter autoeq_presets.dart).
/// APPROXIMATIONS, not complete measured curves — the UI labels them
/// as such and never claims measured accuracy.
struct MusicAutoEqPreset: Equatable {
    var name: String
    var gains: [Double]

    static let all: [MusicAutoEqPreset] = [
        MusicAutoEqPreset(name: "AirPods Pro 2", gains: [1.5, 1.0, 0.5, 0.0, 0.0, -0.5, -1.0, -0.5, 0.5, 1.0]),
        MusicAutoEqPreset(name: "AirPods Max", gains: [2.0, 1.5, 1.0, 0.0, -0.5, -0.5, 0.0, 0.5, 1.0, 1.5]),
        MusicAutoEqPreset(name: "Sony WH-1000XM5", gains: [-1.0, -0.5, 0.0, 0.5, 0.5, 0.0, -0.5, -1.0, -0.5, 0.0]),
        MusicAutoEqPreset(name: "Sony WF-1000XM5", gains: [1.0, 0.5, 0.0, 0.0, -0.5, -0.5, 0.0, 0.5, 1.0, 1.5]),
        MusicAutoEqPreset(name: "Bose QC45", gains: [2.5, 2.0, 1.0, 0.0, 0.0, 0.0, -0.5, 0.0, 0.5, 1.0]),
        MusicAutoEqPreset(name: "Sennheiser HD 600", gains: [3.0, 2.0, 1.0, 0.0, 0.0, -1.0, -1.5, -1.0, 0.0, 1.0]),
        MusicAutoEqPreset(name: "Galaxy Buds2 Pro", gains: [1.5, 1.0, 0.5, 0.0, -0.5, -0.5, 0.0, 0.5, 1.0, 0.5]),
        MusicAutoEqPreset(name: "Moondrop Aria", gains: [2.0, 1.0, 0.5, 0.0, 0.0, 0.0, -0.5, -0.5, 0.0, 0.5]),
    ]
}
