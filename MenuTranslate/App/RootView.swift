import SwiftData
import SwiftUI
#if DEBUG
import UIKit
#endif

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MenuSession.createdAt, order: .reverse) private var sessions: [MenuSession]
    @State private var navigationPath: [MenuSession] = []
    @State private var captureViewModel: CaptureViewModel?
    @State private var showCapture = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "未有菜單記錄",
                        systemImage: "menucard",
                        description: Text("影低張菜單就可以開始")
                    )
                } else {
                    historyList
                }
            }
            .navigationTitle("菜單")
            .navigationDestination(for: MenuSession.self) { session in
                MenuView(session: session)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("設定", systemImage: "gearshape")
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    captureViewModel = CaptureViewModel(modelContext: modelContext)
                    showCapture = true
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
        .fullScreenCover(isPresented: $showCapture) {
            if let captureViewModel {
                NavigationStack {
                    CaptureView(
                        vm: captureViewModel,
                        openSettings: {
                            showCapture = false
                            showSettings = true
                        },
                        onComplete: { session in
                            showCapture = false
                            navigationPath.append(session)
                        }
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showCapture = false }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
        }
        .task {
            await runAutoDemoIfNeeded()
        }
    }

    private var historyList: some View {
        List {
            ForEach(sessions, id: \.persistentModelID) { session in
                NavigationLink(value: session) {
                    HistoryRow(session: session)
                }
                .listRowBackground(Color.mtSurface)
            }
            .onDelete(perform: deleteSessions)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.mtBackground)
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sessions[index])
        }
        try? modelContext.save()
    }

    #if DEBUG
    @MainActor
    private func runAutoDemoIfNeeded() async {
        guard UserDefaults.standard.bool(forKey: "autoDemo"), navigationPath.isEmpty else { return }
        let demoViewModel = CaptureViewModel(modelContext: modelContext)
        demoViewModel.addPhotos([Self.demoImage()])
        await demoViewModel.recognize()
        if let session = demoViewModel.completedSession {
            let sortedItems = session.items.sorted { $0.sortOrder < $1.sortOrder }
            if sortedItems.indices.contains(0) { sortedItems[0].quantity = 1 }
            if sortedItems.indices.contains(1) { sortedItems[1].quantity = 2 }
            navigationPath.append(session)
        }
    }

    private static func demoImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
        }
    }
    #else
    @MainActor
    private func runAutoDemoIfNeeded() async {}
    #endif
}

private struct HistoryRow: View {
    let session: MenuSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title ?? "未命名菜單")
                .font(.headline)
                .foregroundStyle(Color.mtTextPrimary)
            Text(session.createdAt.formatted(.dateTime.month(.abbreviated).day().weekday(.wide)))
                .font(.footnote)
                .foregroundStyle(Color.mtTextSecondary)
            Text("\(session.items.count) 味菜 · \(session.detectedLanguage)")
                .font(.footnote)
                .foregroundStyle(Color.mtTextSecondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    RootView()
        .modelContainer(for: MenuSession.self, inMemory: true)
}
