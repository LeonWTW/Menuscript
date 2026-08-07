// Renders and scrolls the menu's category filter while treating nil as the
// explicit “all categories” selection.

import SwiftUI

/// Horizontal category filter. The leading chip is always “All” (all
/// categories, `selection == nil`); tapping the already-selected chip clears
/// the filter back to nil. The selected chip scrolls into view on change.
struct CategoryChipsBar: View {
    let categories: [String]
    @Binding var selection: String?

    @Environment(\.colorScheme) private var colorScheme

    private let allLabel = L10n.string("全部")
    private let allID = "__mt_category_all__"

    /// Builds all filter chips and automatically centers the newly selected one.
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(label: allLabel, isSelected: selection == nil, id: allID) {
                        selection = nil
                    }
                    ForEach(categories, id: \.self) { category in
                        chip(label: category, isSelected: selection == category, id: category) {
                            selection = (selection == category) ? nil : category
                        }
                    }
                }
                .padding(.horizontal, MTSpacing.screenMargin)
            }
            .onChange(of: selection) { _, newValue in
                withAnimation(.default) {
                    proxy.scrollTo(newValue ?? allID, anchor: .center)
                }
            }
        }
    }

    /// Creates one accessible filter button with shared sizing and selected state.
    private func chip(label: String, isSelected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.mtChip)
                .foregroundStyle(isSelected ? .white : Color.mtTextSecondary)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(chipBackground(isSelected: isSelected))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.default, value: isSelected)
        .id(id)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Draws the selected accent or an unselected surface suited to light/dark mode.
    @ViewBuilder
    private func chipBackground(isSelected: Bool) -> some View {
        let shape = Capsule()
        if isSelected {
            shape.fill(Color.mtAccent)
        } else if colorScheme == .light {
            shape
                .fill(Color.mtSurfaceElevated)
                .overlay(shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
        } else {
            shape.fill(Color.mtSurfaceElevated)
        }
    }
}

#Preview {
    @Previewable @State var selection: String? = nil
    return CategoryChipsBar(
        categories: ["刺身", "壽司", "燒物", "湯物", "甜品"],
        selection: $selection
    )
    .padding(.vertical, 12)
    .background(Color.mtBackground)
}
