// Builds the capture screen and translates user gestures into view-model calls;
// recognition and persistence remain outside the view for clarity and testing.

import PhotosUI
import SwiftData
import SwiftUI

/// Lets the user gather one or more menu photos (from the photo library, the
/// camera, or — in DEBUG builds — a generated placeholder) and kick off
/// recognition via `CaptureViewModel`. The view itself stays dumb: navigation
/// and Settings routing are handed back to the caller through closures.
struct CaptureView: View {
    @Bindable var vm: CaptureViewModel
    var onComplete: (MenuSession) -> Void = { _ in }

    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showSettings = false
    @State private var photoImporter = PhotoImportCoordinator()

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    /// Reports whether this device can offer the camera entry point.
    private var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    /// Composes the photo grid, add controls, recognition actions, sheets, and
    /// alerts from observable state rather than performing business logic here.
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                photoSection
                photoLoadStatus
                addButtons
                recognizeButton
            }
            .padding()
        }
        .navigationTitle("影菜單")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(vm.isRecognizing)
        .overlay {
            if vm.isRecognizing {
                recognizingOverlay
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(
                onImagePicked: { image in
                    if vm.canAddMorePhotos {
                        vm.addPhotos([image])
                    }
                    showCamera = false
                },
                onCancel: {
                    showCamera = false
                }
            )
            .ignoresSafeArea()
        }
        .onChange(of: pickerSelection) { _, newItems in
            guard !newItems.isEmpty else { return }
            importPickedPhotos(newItems)
        }
        .onChange(of: vm.completedSession) { _, newSession in
            if let newSession {
                onComplete(newSession)
            }
        }
        .alert("辨識失敗", isPresented: errorAlertBinding) {
            if let recoveryAction = vm.recoveryAction {
                recoveryButton(for: recoveryAction)
            }
            Button("取消", role: .cancel) {
                vm.clearProviderError()
            }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .alert("傳送資料到 Google Gemini", isPresented: $vm.needsLiveDisclosure) {
            Button("同意並繼續") {
                vm.acceptLiveDisclosure()
                vm.startRecognize()
            }
            Button("取消", role: .cancel) {
                vm.cancelLiveDisclosure()
            }
        } message: {
            Text("使用真實辨識前，請確認：你嘅 Gemini API Key、菜單相片、目標語言、敏感原設定，以及之後要求解釋嘅菜式名稱，會由裝置直接傳送到 Google Gemini。資料保留方式視乎你使用嘅 Google 免費或付費方案。")
        }
        .alert("辨識失敗", isPresented: captureIssueAlertBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(vm.captureIssue?.message ?? "")
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
        }
        .onDisappear {
            CaptureImportLifecycle.handleDisappear(
                isPresentingCamera: showCamera,
                isPresentingSettings: showSettings,
                coordinator: photoImporter,
                viewModel: vm
            )
        }
    }

    /// Bridges the optional provider error message to SwiftUI's Boolean alert
    /// API and clears all related recovery state when the alert closes.
    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { vm.errorMessage != nil },
            set: { isPresented in
                if !isPresented { vm.clearProviderError() }
            }
        )
    }

    /// Builds the action appropriate to a provider's suggested recovery path.
    @ViewBuilder
    private func recoveryButton(for action: ProviderRecoveryAction) -> some View {
        switch action {
        case .openSettings:
            Button("去 Settings") { showSettings = true }
        case .reviewPermissions:
            Button("檢查專案權限") { showSettings = true }
        case .reviewBilling:
            Button("檢查計費設定") { showSettings = true }
        case .reviewModel:
            Button("檢查 Model 設定") { showSettings = true }
        case .retry:
            Button("再試一次") { vm.startRecognize() }
        }
    }

    /// Bridges capture validation issues to an alert and clears the issue when
    /// the user dismisses it.
    private var captureIssueAlertBinding: Binding<Bool> {
        Binding(
            get: { vm.captureIssue != nil },
            set: { isPresented in
                if !isPresented { vm.captureIssue = nil }
            }
        )
    }

    // MARK: - Photo grid

    /// Shows either an empty explanation or the ordered grid of staged photos.
    @ViewBuilder
    private var photoSection: some View {
        if vm.photos.isEmpty {
            ContentUnavailableView(
                "未有菜單相",
                systemImage: "photo.on.rectangle.angled",
                description: Text("影低或者揀返張菜單相")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(vm.photos) { photo in
                    photoThumbnail(photo)
                }
            }
        }
    }

    /// Renders one stable photo slot, including loading/failure state and a
    /// remove action that addresses the slot by ID rather than array position.
    private func photoThumbnail(_ photo: CapturedPhoto) -> some View {
        ZStack {
            if let preview = photo.preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.12)
                if photo.isPending {
                    ProgressView()
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                }
            }
        }
            .frame(height: 110)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .clipped()
            .overlay(alignment: .topTrailing) {
                Button {
                    vm.removePhoto(id: photo.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .font(.title3)
                }
                .padding(4)
                .accessibilityLabel("刪除呢張相")
            }
            .overlay(alignment: .bottomLeading) {
                if photo.failure != nil {
                    Label("載入失敗", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.red.opacity(0.9), in: Capsule())
                        .padding(5)
                }
            }
    }

    /// Summarizes preparation progress, failures, or current photo capacity.
    @ViewBuilder
    private var photoLoadStatus: some View {
        if vm.pendingPhotoCount > 0 {
            HStack(spacing: 8) {
                ProgressView()
                Text("載入緊相片…（\(vm.photos.count)/\(CaptureLimits.maxPhotoCount)）")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else if vm.failedPhotoCount > 0 {
            Text("\(vm.failedPhotoCount) 張相載入失敗；請刪除失敗嘅相，再重新揀選或拍攝。")
                .font(.footnote)
                .foregroundStyle(.red)
        } else if !vm.photos.isEmpty {
            Text("\(vm.photos.count)/\(CaptureLimits.maxPhotoCount) 張相")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Add photo controls

    /// Presents every supported photo source and disables all of them while a
    /// batch is pending, recognition is running, or capacity is exhausted.
    private var addButtons: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                PhotosPicker(
                    selection: $pickerSelection,
                    maxSelectionCount: max(1, vm.remainingPhotoCapacity),
                    matching: .images
                ) {
                    Label("相簿", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!vm.canAddMorePhotos)

                if isCameraAvailable {
                    Button {
                        if vm.canAddMorePhotos {
                            showCamera = true
                        }
                    } label: {
                        Label("相機", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!vm.canAddMorePhotos)
                }
            }

            #if DEBUG
            Button {
                if vm.canAddMorePhotos {
                    vm.addPhotos([Self.demoPhoto()])
                }
            } label: {
                Label("示範相", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!vm.canAddMorePhotos)
            #endif
        }
    }

    /// Starts recognition only when the view model's full readiness rule passes.
    private var recognizeButton: some View {
        Button {
            vm.startRecognize()
        } label: {
            Text("開始辨識")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!vm.canRecognize)
    }

    /// Blocks editing and clearly communicates that recognition is in progress.
    private var recognizingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("辨識緊菜單…")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Photo loading

    /// Converts picker items into independent async loaders, then gives them to
    /// the coordinator so slots are reserved before any load can finish.
    private func importPickedPhotos(_ items: [PhotosPickerItem]) {
        // Clear synchronously and reserve slots before any await. The UI
        // pauses new selections while these slots are pending; if stale or
        // programmatic events do overlap, the coordinator still reserves and
        // resolves them safely.
        pickerSelection = []
        guard vm.canAddMorePhotos else { return }

        let loaders: [PhotoImportCoordinator.Loader] = items.map { item in
            {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        return .failure(.loadFailed)
                    }
                    return await Task.detached(priority: .userInitiated) {
                        guard let prepared = ImagePrep.preparedPhoto(from: data) else {
                            return Result<ImagePrep.PreparedPhoto, CapturedPhotoFailure>.failure(.invalidImage)
                        }
                        return .success(prepared)
                    }.value
                } catch is CancellationError {
                    return .failure(.loadFailed)
                } catch {
                    return .failure(.loadFailed)
                }
            }
        }
        photoImporter.importBatch(loaders: loaders, into: vm)
    }

    #if DEBUG
    /// Generates a solid-colour, text-free placeholder photo so the capture
    /// flow can be exercised on the simulator without a real menu photo.
    private static func demoPhoto() -> UIImage {
        let size = CGSize(width: 400, height: 300)
        let colors: [UIColor] = [.systemTeal, .systemOrange, .systemPink, .systemIndigo, .systemGreen, .systemYellow]
        let color = colors.randomElement() ?? .systemTeal
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            color.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
        }
    }
    #endif
}

#Preview {
    let container = try! ModelContainer(
        for: MenuSession.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    NavigationStack {
        CaptureView(vm: CaptureViewModel(modelContext: container.mainContext, provider: MockVisionProvider()))
    }
}
