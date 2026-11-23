// HAo Studio 2.0 — theme system (Swift native).
//
// 4 themes x light/dark = 8 combinations. Colour VALUES are copied from the
// Flutter build-31 baseline (lib/core/theme/hao_themes.dart, HEAD 2ef902b,
// 1.1.6+31); the STRUCTURE is Swift-native (a plain value type + an
// EnvironmentKey), not a translation of the Flutter ThemeExtension.
// S0 fixed the four light-mode textMuted values to the build-31 WCAG
// contrast values (the scaffold had copied the pre-fix baseline).
//
// Standing rules (chen 2026-11-16, iron law):
// - No hardcoded colours at call sites: every view reads the palette from
//   the environment (`.haoTheme`), never a literal Color.
// - NO purple anywhere in any theme.
// - Red appears ONLY where it truly means something: the LIVE badge and
//   the recording dot (`liveRed`). Buttons / active states use `accent`,
//   never saturated red.
// - Blue accents are black (chen 2026-11-18): the two blue/cyan accents
//   (appleGlass, polarIce) are black in light mode and dark grey #76767A
//   in dark mode (black-on-black would be invisible). Gold and mint
//   accents are not blue and are unchanged.
// - Higher transparency: glass surfaces are low-alpha + strong blur;
//   readability comes from blur, never from darkening the background.

import SwiftUI

/// The four HAo Studio themes.
enum HaoThemeID: String, CaseIterable, Identifiable {
    case appleGlass
    case darkGold
    case freshMint
    case polarIce

    var id: String { rawValue }

    /// Display name (matches the Flutter baseline).
    var displayName: String {
        switch self {
        case .appleGlass: return "苹果毛玻璃"
        case .darkGold: return "暗夜鎏金"
        case .freshMint: return "清新薄荷"
        case .polarIce: return "极夜冰蓝"
        }
    }
}

/// Frosted-glass + semantic colours for one theme/mode combination.
/// (No Equatable: SwiftUI Color is not Equatable, and nothing compares
/// palettes — the store republishes instead.)
struct HaoThemePalette {
    /// Sophisticated theme accent for buttons / active states (never red).
    let accent: Color
    /// Foreground on a filled accent surface.
    let onAccent: Color
    /// Low-alpha accent wash (selected rows, progress fill background).
    let accentSoft: Color
    /// Frosted-glass surface: LOW alpha + strong blur.
    let surface: Color
    /// Slightly less transparent glass (sheets, player).
    let surfaceStrong: Color
    /// Opaque surface for places glass cannot be used.
    let surfaceSolid: Color
    /// Hairline divider / border colour.
    let hairline: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    /// The ONLY red in the app: LIVE badge + recording dot.
    let liveRed: Color
    /// Backdrop blur sigma for frosted glass.
    let glassBlurSigma: CGFloat
    let scaffoldBackground: Color
    let colorScheme: ColorScheme
    /// Tab-bar selected-item colour. Chen's rule: selected is BLACK, not
    /// red and not the theme accent. In dark mode black on dark
    /// glass is invisible, so the dark counterpart is white — the same
    /// readability reasoning the Flutter baseline uses for its dark
    /// accents (#76767A instead of black).
    let tabSelected: Color

    /// All four themes, each with light + dark. No purple anywhere.
    static func palette(for id: HaoThemeID, scheme: ColorScheme) -> HaoThemePalette {
        let liveRed = Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255)
        switch (id, scheme) {
        case (.appleGlass, .light):
            return HaoThemePalette(
                accent: .black, onAccent: .white,
                accentSoft: Color.black.opacity(0.14),
                surface: Color.white.opacity(0.55),
                surfaceStrong: Color.white.opacity(0.68),
                surfaceSolid: .white,
                hairline: Color.black.opacity(0.08),
                textPrimary: Color(hex: 0x1C1C1E), textSecondary: Color(hex: 0x3A3A3C),
                textMuted: Color(hex: 0x6B6B70),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: Color(hex: 0xF2F2F7),
                colorScheme: .light, tabSelected: .black)
        case (.appleGlass, .dark):
            return HaoThemePalette(
                accent: Color(hex: 0x76767A), onAccent: .white,
                accentSoft: Color(hex: 0x76767A).opacity(0.14),
                surface: Color.white.opacity(0.10),
                surfaceStrong: Color.white.opacity(0.16),
                surfaceSolid: Color(hex: 0x1C1C1E),
                hairline: Color.white.opacity(0.12),
                textPrimary: Color(hex: 0xF5F5F7), textSecondary: Color(hex: 0xD1D1D6),
                textMuted: Color(hex: 0x98989D),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: .black,
                colorScheme: .dark, tabSelected: .white)
        case (.darkGold, .light):
            return HaoThemePalette(
                accent: Color(hex: 0x9A7B1E), onAccent: .white,
                accentSoft: Color(hex: 0x9A7B1E).opacity(0.14),
                surface: Color.white.opacity(0.55),
                surfaceStrong: Color.white.opacity(0.68),
                surfaceSolid: Color(hex: 0xFFFDF5),
                hairline: Color(hex: 0x9A7B1E).opacity(0.18),
                textPrimary: Color(hex: 0x2A2113), textSecondary: Color(hex: 0x5C4F33),
                textMuted: Color(hex: 0x7A6C4E),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: Color(hex: 0xFAF6EC),
                colorScheme: .light, tabSelected: .black)
        case (.darkGold, .dark):
            return HaoThemePalette(
                accent: Color(hex: 0xD4AF37), onAccent: Color(hex: 0x0B0B0F),
                accentSoft: Color(hex: 0xD4AF37).opacity(0.14),
                surface: Color.white.opacity(0.08),
                surfaceStrong: Color.white.opacity(0.14),
                surfaceSolid: Color(hex: 0x1D1A14),
                hairline: Color(hex: 0xD4AF37).opacity(0.22),
                textPrimary: Color(hex: 0xF5EDD6), textSecondary: Color(hex: 0xD8C9A3),
                textMuted: Color(hex: 0x9A8B6B),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: Color(hex: 0x0D0B08),
                colorScheme: .dark, tabSelected: .white)
        case (.freshMint, .light):
            return HaoThemePalette(
                accent: Color(hex: 0x00897B), onAccent: .white,
                accentSoft: Color(hex: 0x00897B).opacity(0.14),
                surface: Color.white.opacity(0.55),
                surfaceStrong: Color.white.opacity(0.68),
                surfaceSolid: .white,
                hairline: Color(hex: 0x00897B).opacity(0.14),
                textPrimary: Color(hex: 0x122E29), textSecondary: Color(hex: 0x3D5A54),
                textMuted: Color(hex: 0x58746D),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: Color(hex: 0xEFFAF6),
                colorScheme: .light, tabSelected: .black)
        case (.freshMint, .dark):
            return HaoThemePalette(
                accent: Color(hex: 0x4DD0C4), onAccent: Color(hex: 0x0B0B0F),
                accentSoft: Color(hex: 0x4DD0C4).opacity(0.14),
                surface: Color.white.opacity(0.09),
                surfaceStrong: Color.white.opacity(0.15),
                surfaceSolid: Color(hex: 0x122622),
                hairline: Color.white.opacity(0.12),
                textPrimary: Color(hex: 0xE6F7F3), textSecondary: Color(hex: 0xB9D9D2),
                textMuted: Color(hex: 0x7FA39B),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: Color(hex: 0x07110F),
                colorScheme: .dark, tabSelected: .white)
        case (.polarIce, .light):
            return HaoThemePalette(
                accent: .black, onAccent: .white,
                accentSoft: Color.black.opacity(0.14),
                surface: Color.white.opacity(0.55),
                surfaceStrong: Color.white.opacity(0.68),
                surfaceSolid: .white,
                hairline: Color.black.opacity(0.14),
                textPrimary: Color(hex: 0x0F2436), textSecondary: Color(hex: 0x3A5568),
                textMuted: Color(hex: 0x4F6E84),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: Color(hex: 0xEEF6FB),
                colorScheme: .light, tabSelected: .black)
        case (.polarIce, .dark):
            return HaoThemePalette(
                accent: Color(hex: 0x76767A), onAccent: .white,
                accentSoft: Color(hex: 0x76767A).opacity(0.14),
                surface: Color.white.opacity(0.08),
                surfaceStrong: Color.white.opacity(0.14),
                surfaceSolid: Color(hex: 0x0E1E2E),
                hairline: Color.white.opacity(0.20),
                textPrimary: Color(hex: 0xE8F4FC), textSecondary: Color(hex: 0xB4D2E6),
                textMuted: Color(hex: 0x7D9BB0),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: Color(hex: 0x050B12),
                colorScheme: .dark, tabSelected: .white)
        default:
            // Unreachable in practice — ColorScheme is a struct, so the
            // compiler cannot prove the 8 cases exhaustive. Fall back to
            // the appleGlass light palette.
            return HaoThemePalette(
                accent: .black, onAccent: .white,
                accentSoft: Color.black.opacity(0.14),
                surface: Color.white.opacity(0.55),
                surfaceStrong: Color.white.opacity(0.68),
                surfaceSolid: .white,
                hairline: Color.black.opacity(0.08),
                textPrimary: Color(hex: 0x1C1C1E), textSecondary: Color(hex: 0x3A3A3C),
                textMuted: Color(hex: 0x6B6B70),
                liveRed: liveRed, glassBlurSigma: 24,
                scaffoldBackground: Color(hex: 0xF2F2F7),
                colorScheme: .light, tabSelected: .black)
        }
    }
}

extension Color {
    /// Opaque 0xRRGGBB (alpha 1.0), matching the Flutter `Color(0xFF......)` literals.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Environment

private struct HaoThemeKey: EnvironmentKey {
    // Default before the store loads: appleGlass light (same default as
    // the Flutter ThemeController).
    static let defaultValue = HaoThemePalette.palette(for: .appleGlass, scheme: .light)
}

extension EnvironmentValues {
    var haoTheme: HaoThemePalette {
        get { self[HaoThemeKey.self] }
        set { self[HaoThemeKey.self] = newValue }
    }
}
