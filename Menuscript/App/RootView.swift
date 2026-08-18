// Coordinates the app's top-level history, capture, settings, and navigation
// flows while delegating persistence and feature details to focused types.

import SwiftData
import SwiftUI
#if DEBUG
import UIKit
#endif

/// The home screen and navigation hub for saved menu sessions.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MenuSession.createdAt, order: .reverse) private var sessions: [MenuSession]
    @State private var navigationPath: [MenuSession] = []
    @Binding var captureViewModel: CaptureViewModel?
    @State private var showSettings = false
    @State private var showCancelCaptureConfirm = false
    @State private var persistenceErrorMessage: String?

    /// Selects sessions that can still be edited so they appear separately in history.
    private var unfinishedSessions: [MenuSession] {
        sessions.filter { !$0.isCompleted }
    }

    /// Selects finalized sessions whose bills should no longer change.
    private var completedSessions: [MenuSession] {
        sessions.filter(\.isCompleted)
    }

    /// Builds the history screen and presents capture, settings, errors, and destinations.
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
            .navigationTitle("菜單記錄")
            .navigationDestination(for: MenuSession.self) { session in
                MenuView(session: session) {
                    navigationPath.removeAll()
                    pruneExpiredPhotos()
                }
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
        .fullScreenCover(item: $captureViewModel) { vm in
            NavigationStack {
                CaptureView(
                    vm: vm,
                    onComplete: { session in
                        captureViewModel = nil
                        navigationPath.append(session)
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { requestCancelCapture(vm: vm) }
                    }
                }
            }
            .confirmationDialog(
                "捨棄呢批菜單相？",
                isPresented: $showCancelCaptureConfirm,
                titleVisibility: .visible
            ) {
                Button("捨棄相片", role: .destructive) { captureViewModel = nil }
                Button("繼續影相", role: .cancel) {}
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(onDeleteAllSucceeded: {
                    showSettings = false
                    navigationPath.removeAll()
                })
            }
        }
        .alert("菜單記錄", isPresented: persistenceErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(persistenceErrorMessage ?? "")
        }
        .task {
            pruneExpiredPhotos()
            await runAutoDemoIfNeeded()
        }
    }

    /// Groups unfinished and completed sessions into familiar history sections.
    private var historyList: some View {
        List {
            if !unfinishedSessions.isEmpty {
                historySection(title: "未完成", sessions: unfinishedSessions)
            }
            if !completedSessions.isEmpty {
                historySection(title: "已完成", sessions: completedSessions)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.mtBackground)
    }

    /// Builds one history section and maps swipe-to-delete positions back to its sessions.
    private func historySection(title: LocalizedStringKey, sessions: [MenuSession]) -> some View {
        Section(title) {
            ForEach(sessions, id: \.persistentModelID) { session in
                NavigationLink(value: session) {
                    HistoryRow(session: session)
                }
                .listRowBackground(Color.mtSurface)
            }
            .onDelete { offsets in
                deleteSessions(at: offsets, from: sessions)
            }
        }
    }

    /// Handles the capture cover's toolbar Cancel button. While recognition is
    /// in flight, cancels the underlying task (instead of merely dismissing
    /// the UI while the request keeps running). Otherwise, if the user has
    /// already gathered photos, confirms before discarding them.
    private func requestCancelCapture(vm: CaptureViewModel) {
        if vm.isRecognizing {
            vm.cancelRecognize()
            captureViewModel = nil
        } else if !vm.photos.isEmpty {
            showCancelCaptureConfirm = true
        } else {
            captureViewModel = nil
        }
    }

    /// Converts the optional persistence error into the Boolean binding required
    /// by SwiftUI's alert, clearing the message when the alert closes.
    private var persistenceErrorBinding: Binding<Bool> {
        Binding(
            get: { persistenceErrorMessage != nil },
            set: { if !$0 { persistenceErrorMessage = nil } }
        )
    }

    /// Deletes only the selected rows in the displayed section and surfaces any
    /// storage failure instead of making the rows disappear silently.
    private func deleteSessions(at offsets: IndexSet, from displayedSessions: [MenuSession]) {
        let sessionsToDelete = offsets.compactMap { index in
            displayedSessions.indices.contains(index) ? displayedSessions[index] : nil
        }
        do {
            try SessionStore(context: modelContext).delete(sessionsToDelete)
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
    }

    /// Applies the photo-retention setting. Runs off the user's critical path
    /// (launch and post-finalize); a failure keeps every photo and is surfaced
    /// through the shared persistence alert instead of being swallowed.
    private func pruneExpiredPhotos() {
        do {
            try PhotoRetentionService(context: modelContext)
                .pruneExpiredPhotos(policy: PhotoRetentionPolicy.resolve())
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
    }

    #if DEBUG
    /// Drives a repeatable capture flow for debug screenshots when the hidden
    /// `autoDemo` setting is enabled; production builds never run this helper.
    @MainActor
    private func runAutoDemoIfNeeded() async {
        guard UserDefaults.standard.bool(forKey: "autoDemo"), navigationPath.isEmpty else { return }
        if UserDefaults.standard.string(forKey: "autoDemoScreen") == "settings" {
            showSettings = true
            return
        }
        let demoViewModel = CaptureViewModel(modelContext: modelContext)
        demoViewModel.addPhotos([Self.demoImage()])
        while demoViewModel.pendingPhotoCount > 0 {
            guard !Task.isCancelled else { return }
            await Task.yield()
        }
        guard !Task.isCancelled, demoViewModel.canRecognize else { return }
        await demoViewModel.recognize()
        if let session = demoViewModel.completedSession {
            let sortedItems = session.items.sorted { $0.sortOrder < $1.sortOrder }
            if sortedItems.indices.contains(0) { sortedItems[0].quantity = 1 }
            if sortedItems.indices.contains(1) { sortedItems[1].quantity = 2 }
            navigationPath.append(session)
        }
    }

    /// Creates a tiny valid image that lets the mock recognition flow run without an extra image file.
    private static func demoImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
        }
    }
    #else
    /// Keeps the call site identical in production while deliberately doing no demo work.
    @MainActor
    private func runAutoDemoIfNeeded() async {}
    #endif
}

/// Displays the human-readable summary and completion state for one saved session.
private struct HistoryRow: View {
    let session: MenuSession

    /// Builds a compact row from stable session metadata for quick scanning.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title ?? L10n.string("未命名菜單"))
                .font(.headline)
                .foregroundStyle(Color.mtTextPrimary)
            Text(session.createdAt, format: .dateTime.month(.abbreviated).day().weekday(.wide))
                .font(.footnote)
                .foregroundStyle(Color.mtTextSecondary)
            Text("\(session.items.count) 味菜 · \(session.detectedLanguage)")
                .font(.footnote)
                .foregroundStyle(Color.mtTextSecondary)
            Label(
                session.isCompleted ? LocalizedStringKey("已完成") : LocalizedStringKey("未完成"),
                systemImage: session.isCompleted ? "checkmark.seal.fill" : "clock.fill"
            )
            .font(.caption)
            .foregroundStyle(session.isCompleted ? Color.green : Color.mtWarning)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    RootView(captureViewModel: .constant(nil))
        .modelContainer(for: MenuSession.self, inMemory: true)
}
