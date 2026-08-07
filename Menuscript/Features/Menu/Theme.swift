// Defines the Menu feature's shared color, type, radius, and spacing tokens so
// every screen uses one accessible visual language in light and dark modes.

import SwiftUI
import UIKit

// MARK: - Menu theme tokens (WF-4, owned by design)
//
// Direction: a wooden price tag, with warm charcoal neutrals from an izakaya wall,
// champagne-gold converted prices, and a vermilion-red accent.
// Accent appears on exactly three things: selected chip, stepper controls,
// checkout CTA. One radius system, SF Pro only, Dynamic Type relative styles,
// monospaced digits on every number.
//
// Contrast ratios in doc comments are WCAG 2.1 approximations, measured
// against the surface the token normally sits on (dark on mtSurface #201C18,
// light on #FFFFFF unless stated). All meet AA for their role in both modes.

/// Builds an sRGB `UIColor` from 0-255 components.
private func mtRGB(_ r: Int, _ g: Int, _ b: Int) -> UIColor {
    UIColor(
        red: CGFloat(r) / 255.0,
        green: CGFloat(g) / 255.0,
        blue: CGFloat(b) / 255.0,
        alpha: 1.0
    )
}

/// Supplies the private initializer used to build every adaptive theme color.
private extension Color {
    /// Dynamic color that resolves per trait collection (light / dark).
    init(mtLight light: UIColor, mtDark dark: UIColor) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

// MARK: - Colors

/// Names the Menu palette by visual purpose so views do not repeat raw colors.
extension Color {
    /// Screen background. Dark #151210 (warm off-black), Light #F5F1EA (warm paper).
    static let mtBackground = Color(
        mtLight: mtRGB(0xF5, 0xF1, 0xEA),
        mtDark: mtRGB(0x15, 0x12, 0x10)
    )

    /// Card surface. Dark #201C18 (lifts ~2x luminance over background), Light #FFFFFF.
    static let mtSurface = Color(
        mtLight: mtRGB(0xFF, 0xFF, 0xFF),
        mtDark: mtRGB(0x20, 0x1C, 0x18)
    )

    /// Elevated surface: cart bar fill, unselected chips. Dark #2A2521, Light #FFFFFF
    /// (light mode separates by shadow + hairline border instead of fill).
    static let mtSurfaceElevated = Color(
        mtLight: mtRGB(0xFF, 0xFF, 0xFF),
        mtDark: mtRGB(0x2A, 0x25, 0x21)
    )

    /// Primary text (translated dish names). Dark #F2EDE6 on surface ≈14.4:1,
    /// Light #26211C on white ≈15.9:1. Never pure white/black.
    static let mtTextPrimary = Color(
        mtLight: mtRGB(0x26, 0x21, 0x1C),
        mtDark: mtRGB(0xF2, 0xED, 0xE6)
    )

    /// Secondary text (original names, counts, captions). Dark #A89E92 on surface
    /// ≈6.4:1 (≈5.8:1 on elevated), Light #6E6659 on white ≈5.7:1.
    static let mtTextSecondary = Color(
        mtLight: mtRGB(0x6E, 0x66, 0x59),
        mtDark: mtRGB(0xA8, 0x9E, 0x92)
    )

    /// The one accent, vermilion red (saturation ≈73-76%, hue ≈13°, not purple).
    /// Used ONLY for: selected chip fill, stepper controls, checkout CTA.
    /// Dark #C94F36: white label ≈4.5:1, fill vs surface ≈3.7:1.
    /// Light #B8432C: white label ≈5.4:1, fill vs white surface ≈5.1:1.
    static let mtAccent = Color(
        mtLight: mtRGB(0xB8, 0x43, 0x2C),
        mtDark: mtRGB(0xC9, 0x4F, 0x36)
    )

    /// Hero money number (converted price; falls back to original when fx is nil).
    /// Champagne gold, the "wooden price tag". Dark #E8C87E on surface ≈10.4:1,
    /// Light #8F6A12 (bronze) on white ≈4.9:1.
    static let mtPriceConverted = Color(
        mtLight: mtRGB(0x8F, 0x6A, 0x12),
        mtDark: mtRGB(0xE8, 0xC8, 0x7E)
    )

    /// Secondary money number (menu-currency price next to the hero).
    /// Dark #948B80 on surface ≈5.0:1, Light #7A7166 on white ≈4.8:1.
    static let mtPriceOriginal = Color(
        mtLight: mtRGB(0x7A, 0x71, 0x66),
        mtDark: mtRGB(0x94, 0x8B, 0x80)
    )

    /// Low-confidence marker (exclamationmark.triangle icon + optional caption).
    /// Muted amber, always paired with an icon, never color-only.
    /// Dark #E0A050 on surface ≈7.4:1, Light #9F6B1A on white ≈4.6:1.
    static let mtWarning = Color(
        mtLight: mtRGB(0x9F, 0x6B, 0x1A),
        mtDark: mtRGB(0xE0, 0xA0, 0x50)
    )
}

// MARK: - Typography (SF Pro, Dynamic Type relative, digits monospaced)

/// Names the Menu typography roles so hierarchy and Dynamic Type stay consistent.
extension Font {
    /// Translated dish name: hierarchy #1. title3 semibold.
    static let mtDishName = Font.system(.title3, design: .default, weight: .semibold)

    /// Original-language name (what the user points at): subheadline regular.
    static let mtOriginalName = Font.system(.subheadline, design: .default, weight: .regular)

    /// Hero price (converted): title2 bold, monospaced digits.
    static let mtPrice = Font.system(.title2, design: .default, weight: .bold).monospacedDigit()

    /// Secondary price (original currency): subheadline regular, monospaced digits.
    static let mtPriceSecondary = Font.system(.subheadline, design: .default, weight: .regular).monospacedDigit()

    /// Category chip label: subheadline medium.
    static let mtChip = Font.system(.subheadline, design: .default, weight: .medium)

    /// Cart bar total: title3 bold, monospaced digits.
    static let mtCartTotal = Font.system(.title3, design: .default, weight: .bold).monospacedDigit()
}

// MARK: - Shape & spacing system

/// The single radius system. No other corner radii anywhere on the Menu screen.
enum MTRadius {
    /// Dish cards and the empty-state container.
    static let card: CGFloat = 16
    /// Category chips (36pt visual height -> capsule) and the checkout CTA capsule.
    static let chip: CGFloat = 18
    /// Floating cart bar.
    static let bar: CGFloat = 24
}

/// The single spacing system for the Menu screen.
enum MTSpacing {
    /// Inset from card edge to card content.
    static let cardPadding: CGFloat = 16
    /// Vertical gap between cards in the list.
    static let cardGap: CGFloat = 12
    /// Horizontal screen margin (HIG standard).
    static let screenMargin: CGFloat = 16
}
