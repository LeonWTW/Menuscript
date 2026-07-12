import SwiftUI

/// Minus/count/plus stepper for a line item's quantity. Clamps to 0...99 and
/// gives sensory feedback on change. VoiceOver treats the whole control as one
/// adjustable element (swipe up/down to change the value); the individual
/// buttons still carry labels for other assistive technologies.
struct QuantityStepper: View {
    @Binding var value: Int

    private let bounds = 0...99

    var body: some View {
        HStack(spacing: 0) {
            minusButton
            countText
            plusButton
        }
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("數量")
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction(handleAdjustment)
    }

    private var minusButton: some View {
        Button(action: decrement) {
            Image(systemName: "minus")
                .font(.subheadline.bold())
                .foregroundStyle(Color.mtAccent)
                .frame(width: 32, height: 32)
                .background(Circle().strokeBorder(Color.mtAccent, lineWidth: 1.5))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(value <= bounds.lowerBound)
        .opacity(value <= bounds.lowerBound ? 0.35 : 1)
        .accessibilityLabel("減少數量")
    }

    private var plusButton: some View {
        Button(action: increment) {
            Image(systemName: "plus")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.mtAccent))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("增加數量")
    }

    private var countText: some View {
        Text("\(value)")
            .font(Font.mtChip.monospacedDigit())
            .foregroundStyle(Color.mtTextPrimary)
            .frame(minWidth: 28)
            .multilineTextAlignment(.center)
    }

    private func increment() {
        value = min(bounds.upperBound, value + 1)
    }

    private func decrement() {
        value = max(bounds.lowerBound, value - 1)
    }

    private func handleAdjustment(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment:
            increment()
        case .decrement:
            decrement()
        @unknown default:
            break
        }
    }
}

#Preview {
    @Previewable @State var value = 2
    return HStack(spacing: 24) {
        QuantityStepper(value: $value)
        QuantityStepper(value: .constant(0))
    }
    .padding()
    .background(Color.mtSurface)
}
