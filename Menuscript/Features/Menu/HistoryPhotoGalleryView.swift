// Presents persisted menu photos as a memory-conscious, accessible paged gallery
// with UIKit-powered pinch and double-tap zoom.

import SwiftUI
import UIKit

/// Small testable boundary around the persisted page order and lazy image
/// decoding used by `HistoryPhotoGalleryView`.
struct HistoryPhotoGalleryModel {
    let photos: [Data]

    /// Number of persisted pages available to the gallery.
    var pageCount: Int { photos.count }
    /// True when the session has no photo data to display.
    var isEmpty: Bool { photos.isEmpty }

    /// Safely returns page bytes and treats an out-of-range request as missing.
    func data(at index: Int) -> Data? {
        guard photos.indices.contains(index) else { return nil }
        return photos[index]
    }

    /// Decodes one requested page on demand instead of retaining all images.
    func image(at index: Int) -> UIImage? {
        data(at: index).flatMap(UIImage.init(data:))
    }
}

/// Read-only gallery for the compressed menu pages persisted with a session.
/// The page-style TabView instantiates only nearby pages; each page decodes its
/// JPEG on demand and gives the user 1x…5x pinch/double-tap zoom.
struct HistoryPhotoGalleryView: View {
    let photos: [Data]

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPage = 0

    /// Adapts raw photo data to the small model used throughout the view.
    private var model: HistoryPhotoGalleryModel {
        HistoryPhotoGalleryModel(photos: photos)
    }

    /// Composes the empty state or gallery inside a dismissible navigation sheet.
    var body: some View {
        NavigationStack {
            Group {
                if model.isEmpty {
                    ContentUnavailableView("未有菜單相", systemImage: "photo.on.rectangle.angled")
                } else {
                    gallery
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("菜單相片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// Builds a lazy page-style viewer with a separate, accessible page counter.
    private var gallery: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedPage) {
                ForEach(photos.indices, id: \.self) { index in
                    LazyHistoryPhotoPage(
                        data: photos[index],
                        index: index,
                        pageCount: model.pageCount
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            Text(verbatim: "\(selectedPage + 1) / \(model.pageCount)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.65), in: Capsule())
                .padding(.bottom, 16)
                .accessibilityLabel("第 \(selectedPage + 1) 頁，共 \(model.pageCount) 頁")
        }
    }
}

/// Keeps decoding out of the parent TabView build. Only pages that actually
/// appear retain a decoded image; leaving a page releases that memory.
private struct LazyHistoryPhotoPage: View {
    let data: Data
    let index: Int
    let pageCount: Int

    @State private var image: UIImage?
    @State private var didAttemptDecode = false

    /// Decodes only when this page appears, distinguishes corrupt data from
    /// loading, and releases the decoded image when the page leaves the screen.
    var body: some View {
        Group {
            if let image {
                ZoomableHistoryImage(
                    image: image,
                    accessibilityText: L10n.string(
                        "菜單相片，第 %lld 頁，共 %lld 頁",
                        index + 1,
                        pageCount
                    )
                )
            } else if didAttemptDecode {
                ContentUnavailableView(
                    "相片無法顯示",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("第 \(index + 1) 頁嘅相片資料已損壞")
                )
                .foregroundStyle(.white)
                .accessibilityElement(children: .combine)
            } else {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel("正在載入第 \(index + 1) 頁菜單相片")
            }
        }
        .task(id: data) {
            guard !didAttemptDecode else { return }
            image = UIImage(data: data)
            didAttemptDecode = true
        }
        .onDisappear {
            image = nil
            didAttemptDecode = false
        }
    }
}

/// Bridges one image into a zoomable `UIScrollView`, which supplies mature
/// pinch behavior not available from the surrounding SwiftUI page view.
private struct ZoomableHistoryImage: UIViewRepresentable {
    let image: UIImage
    let accessibilityText: String

    /// Creates the delegate and retains UIKit controls shared across updates.
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Builds the zoomable scroll view, constrains its image to the viewport,
    /// and installs a double-tap shortcut between normal and enlarged scales.
    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.delegate = context.coordinator

        let imageView = context.coordinator.imageView
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    /// Updates image and accessibility text when SwiftUI inputs change without
    /// rebuilding the scroll view or losing its zoom behavior.
    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
        context.coordinator.imageView.accessibilityLabel = accessibilityText
    }

    /// Owns the UIKit image view and implements all zoom delegate behavior.
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?

        /// Identifies the image view as the only content that should zoom.
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        /// Toggles between the full image and a useful 3× detail view.
        @objc func doubleTapped() {
            guard let scrollView else { return }
            scrollView.setZoomScale(scrollView.zoomScale > 1 ? 1 : 3, animated: true)
        }
    }
}

#Preview {
    HistoryPhotoGalleryView(photos: [])
}
