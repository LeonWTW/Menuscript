// Renders the floating selected-item summary and checkout entry point using
// already-calculated, already-formatted values from the Menu feature.

import SwiftUI

/// Floating cart summary. Purely presentational — `MenuView` decides when it
/// is visible (per `MenuLogic.totals`) and supplies already-formatted totals;
/// this view just lays them out and exposes the checkout button.
struct CartBar: View {
    let kindCount: Int
    let totalQuantity: Int
    let totalOriginalText: String
    let totalConvertedText: String?
    var hasUnpriced: Bool = false
    var isCompleted: Bool = false
    var onCheckout: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Applies the shared floating-bar surface and accessibility grouping around
    /// a layout that adapts to the user's text size.
    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 68)
            .background(barBackground)
            .padding(.horizontal, MTSpacing.screenMargin)
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
    }

    /// Stacks content at accessibility sizes and uses a compact row otherwise.
    @ViewBuilder
    private var content: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                summary
                checkoutButton
            }
        } else {
            HStack(spacing: 12) {
                summary
                Spacer(minLength: 12)
                checkoutButton
            }
        }
    }

    /// Shows selection counts and the preferred converted total, while exposing
    /// one complete spoken summary rather than separate fragments.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kindsAndCountText)
                .font(.footnote)
                .foregroundStyle(Color.mtTextSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(totalConvertedText ?? totalOriginalText)
                    .font(.mtCartTotal)
                    .foregroundStyle(Color.mtPriceConverted)
                if totalConvertedText != nil {
                    Text(totalOriginalText)
                        .font(.mtPriceSecondary)
                        .foregroundStyle(Color.mtPriceOriginal)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string(
            "已選 %lld 款共 %lld 件%@，合共 %@",
            kindCount,
            totalQuantity,
            hasUnpriced ? L10n.string("，部分未計時價") : "",
            totalConvertedText ?? totalOriginalText
        ))
    }

    /// Formats the item-kind/count caption and flags totals that exclude unpriced dishes.
    private var kindsAndCountText: String {
        let base = L10n.string("%lld 款 · %lld 件", kindCount, totalQuantity)
        return hasUnpriced ? L10n.string("%@ · 未計時價", base) : base
    }

    /// Labels the same action as checkout for drafts and bill review for completed orders.
    private var checkoutButton: some View {
        Button(action: onCheckout) {
            Text(isCompleted ? LocalizedStringKey("帳單") : LocalizedStringKey("埋單"))
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 44)
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
                .background(Capsule().fill(Color.mtAccent))
        }
        .buttonStyle(.plain)
    }

    /// Uses an opaque accessible surface when transparency is reduced and a
    /// material surface otherwise, with the same shape in both cases.
    @ViewBuilder
    private var barBackground: some View {
        let shape = RoundedRectangle(cornerRadius: MTRadius.bar, style: .continuous)
        Group {
            if reduceTransparency {
                shape.fill(Color.mtSurfaceElevated)
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(Color.mtSurfaceElevated.opacity(0.6)))
            }
        }
        .overlay(shape.strokeBorder(hairlineColor, lineWidth: 1))
        .shadow(color: shadowColor, radius: 24, x: 0, y: 8)
    }

    /// Chooses a low-contrast edge that remains visible in the active color scheme.
    private var hairlineColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.08)
    }

    /// Uses a stronger shadow in dark mode to separate the floating surface.
    private var shadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.25) : Color.black.opacity(0.10)
    }
}

#Preview {
    ZStack(alignment: .bottom) {
        Color.mtBackground.ignoresSafeArea()
        CartBar(
            kindCount: 3,
            totalQuantity: 5,
            totalOriginalText: "¥3,200",
            totalConvertedText: "≈ HK$166",
            onCheckout: {}
        )
    }
}
