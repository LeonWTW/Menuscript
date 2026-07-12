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
    @State private var isLoadingPhotos = false
    @State private var failedPhotoLoadCount = 0

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    private var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

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
                    vm.addPhotos([image])
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
            Task { await loadPickedPhotos(newItems) }
        }
        .onChange(of: vm.completedSession) { _, newSession in
            if let newSession {
                onComplete(newSession)
            }
        }
        .alert("未設定 API key", isPresented: $vm.needsAPIKey) {
            Button("去 Settings") { showSettings = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("請先喺設定入面填返 Gemini API Key，或者開啟示範模式。")
        }
        .alert("辨識失敗", isPresented: errorAlertBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { vm.errorMessage != nil },
            set: { isPresented in
                if !isPresented { vm.errorMessage = nil }
            }
        )
    }

    // MARK: - Photo grid

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
                ForEach(Array(vm.photos.enumerated()), id: \.offset) { index, photo in
                    photoThumbnail(photo, index: index)
                }
            }
        }
    }

    private func photoThumbnail(_ image: UIImage, index: Int) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(height: 110)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .clipped()
            .overlay(alignment: .topTrailing) {
                Button {
                    vm.removePhoto(at: index)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .font(.title3)
                }
                .padding(4)
                .accessibilityLabel("刪除呢張相")
            }
    }

    @ViewBuilder
    private var photoLoadStatus: some View {
        if isLoadingPhotos {
            HStack(spacing: 8) {
                ProgressView()
                Text("載入緊相片…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else if failedPhotoLoadCount > 0 {
            Text("\(failedPhotoLoadCount) 張相載入失敗")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Add photo controls

    private var addButtons: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                PhotosPicker(selection: $pickerSelection, maxSelectionCount: 6, matching: .images) {
                    Label("相簿", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if isCameraAvailable {
                    Button {
                        showCamera = true
                    } label: {
                        Label("相機", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }

            #if DEBUG
            Button {
                vm.addPhotos([Self.demoPhoto()])
            } label: {
                Label("示範相", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            #endif
        }
    }

    private var recognizeButton: some View {
        Button {
            vm.startRecognize()
        } label: {
            Text("開始辨識")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!vm.canRecognize || isLoadingPhotos)
    }

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

    @MainActor
    private func loadPickedPhotos(_ items: [PhotosPickerItem]) async {
        // Reset before awaiting any load: a mid-load re-pick must not
        // re-append the items this call is already loading.
        pickerSelection = []
        isLoadingPhotos = true
        defer { isLoadingPhotos = false }

        var images: [UIImage] = []
        var failedCount = 0
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = ImagePrep.downsampledImage(from: data, maxPixelSize: ImagePrep.captureMaxPixelSize) {
                images.append(image)
            } else {
                failedCount += 1
            }
        }
        if !images.isEmpty {
            vm.addPhotos(images)
        }
        failedPhotoLoadCount = failedCount
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
