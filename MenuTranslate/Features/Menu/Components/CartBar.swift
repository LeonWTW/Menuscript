import SwiftUI

/// Floating cart summary. Purely presentational — `MenuView` decides when it
/// is visible (per `MenuLogic.totals`) and supplies already-formatted totals;
/// this view just lays them out and exposes a 埋單 checkout button.
struct CartBar: View {
    let kindCount: Int
    let totalQuantity: Int
    let totalOriginalText: String
    let totalConvertedText: String?
    var hasUnpriced: Bool = false
    var onCheckout: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
        .accessibilityLabel("已選 \(kindCount) 款共 \(totalQuantity) 件\(hasUnpriced ? "，部分未計時價" : "")，合共 \(totalConvertedText ?? totalOriginalText)")
    }

    private var kindsAndCountText: String {
        let base = "\(kindCount) 款 · \(totalQuantity) 件"
        return hasUnpriced ? "\(base) · 未計時價" : base
    }

    private var checkoutButton: some View {
        Button(action: onCheckout) {
            Text("埋單")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 44)
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
                .background(Capsule().fill(Color.mtAccent))
        }
        .buttonStyle(.plain)
    }

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

    private var hairlineColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.08)
    }

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
