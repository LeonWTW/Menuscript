import SwiftUI

// MARK: WF-4 replaces this stub comment
struct MenuView: View {
    let session: MenuSession

    private var sortedItems: [MenuItem] {
        session.items.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        List(sortedItems, id: \.persistentModelID) { item in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.translatedName)
                        .font(.headline)
                    if item.lowConfidence {
                        Text("⚠️")
                    }
                    Spacer()
                    if let price = item.priceValue {
                        Text(CurrencyFormat.format(price, code: session.menuCurrency))
                            .font(.subheadline)
                    } else if let priceNote = item.priceNote {
                        Text(priceNote)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.originalName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(session.title ?? "菜單")
    }
}

#Preview {
    NavigationStack {
        MenuView(session: MenuSession(
            detectedLanguage: "日文",
            targetLanguage: "繁體中文",
            menuCurrency: "JPY",
            homeCurrency: "HKD"
        ))
    }
}
