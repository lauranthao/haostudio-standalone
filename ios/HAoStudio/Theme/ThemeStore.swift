// HAo Studio 2.0 — theme store.
//
// Swift-native equivalent of the Flutter ThemeController: the chosen theme
// and light/dark/system mode persist in UserDefaults and a change takes
// effect immediately everywhere (the palette is re-resolved from the
// @Published values and pushed through the environment — no restart, no
// stale cached colours).
//
// Persistence keys keep the Flutter Hive key NAMES (`haoThemeId`,
// `haoThemeMode`, box `app_settings`) so the mapping in
// docs/storage-mapping.md is one-to-one; only the storage mechanism
// changes (Hive -> UserDefaults, per the foundation storage rules).

import SwiftUI

/// Light / dark / follow-system. Same three modes as Flutter `ThemeMode`.
enum HaoAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// `nil` = follow the system (SwiftUI `.preferredColorScheme(nil)`).
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
final class ThemeStore: ObservableObject {
    /// UserDefaults keys — same names as the Flutter Hive keys.
    static let themeKey = "haoThemeId"
    static let modeKey = "haoThemeMode"

    @Published var themeID: HaoThemeID {
        didSet { defaults.set(themeID.rawValue, forKey: Self.themeKey) }
    }

    @Published var appearance: HaoAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Self.modeKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedTheme = defaults.string(forKey: Self.themeKey)
        self.themeID = HaoThemeID(rawValue: savedTheme ?? "") ?? .appleGlass
        let savedMode = defaults.string(forKey: Self.modeKey)
        self.appearance = HaoAppearance(rawValue: savedMode ?? "") ?? .system
    }

    /// The palette for the EFFECTIVE colour scheme (after the system /
    /// override resolution SwiftUI already performed). Call sites read
    /// the palette from the environment; this is only the resolver.
    func palette(for effectiveScheme: ColorScheme) -> HaoThemePalette {
        HaoThemePalette.palette(for: themeID, scheme: effectiveScheme)
    }

    func setTheme(_ id: HaoThemeID) {
        themeID = id
    }

    func setAppearance(_ mode: HaoAppearance) {
        appearance = mode
    }
}
