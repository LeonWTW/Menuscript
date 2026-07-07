import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "未有菜單記錄",
                systemImage: "menucard",
                description: Text("影低張菜單就可以開始")
            )
            .navigationTitle("菜單")
            .overlay(alignment: .bottomTrailing) {
                Button {
                } label: {
                    Label("影菜單", systemImage: "camera.fill")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .padding(8)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .padding()
            }
        }
        .preferredColorScheme(nil)
    }
}

#Preview {
    RootView()
}
