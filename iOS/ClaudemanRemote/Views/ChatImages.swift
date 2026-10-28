import ClaudemanKit
import SwiftUI

/// Loads conversation images from the Mac, cached in memory for the life of the app.
struct ChatImageLoader {
    var load: (ChatImage) async -> UIImage?

    static let none = ChatImageLoader { _ in nil }

    init(load: @escaping (ChatImage) async -> UIImage?) {
        self.load = load
    }

    init(client: RemoteClient?, sessionID: UUID) {
        load = { image in
            let key = "\(sessionID.uuidString)/\(image.id)" as NSString
            if let cached = ImageCache.shared.object(forKey: key) { return cached }
            guard let client,
                  let data = try? await client.imageData(sessionID: sessionID, imageID: image.id),
                  let decoded = UIImage(data: data) else { return nil }
            ImageCache.shared.setObject(decoded, forKey: key, cost: data.count)
            return decoded
        }
    }
}

private enum ImageCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 150 * 1024 * 1024
        return cache
    }()
}

private struct ChatImageLoaderKey: EnvironmentKey {
    static let defaultValue = ChatImageLoader.none
}

extension EnvironmentValues {
    var chatImageLoader: ChatImageLoader {
        get { self[ChatImageLoaderKey.self] }
        set { self[ChatImageLoaderKey.self] = newValue }
    }
}

/// A row of tappable thumbnails; tapping one opens it full screen.
struct ChatImageStrip: View {
    let images: [ChatImage]
    var size: CGFloat = 120

    @State private var viewing: ViewerItem?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(images) { image in
                    ChatImageThumbnail(image: image, size: size) { loaded in
                        viewing = ViewerItem(image: loaded, name: image.name)
                    }
                }
            }
        }
        .scrollDisabled(images.count < 3)
        .fixedSize(horizontal: images.count < 3, vertical: true)
        .fullScreenCover(item: $viewing) { item in
            ImageViewer(image: item.image, name: item.name)
        }
    }

    private struct ViewerItem: Identifiable {
        let id = UUID()
        let image: UIImage
        let name: String?
    }
}

private struct ChatImageThumbnail: View {
    @Environment(\.chatImageLoader) private var loader
    let image: ChatImage
    let size: CGFloat
    let onOpen: (UIImage) -> Void

    @State private var loaded: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemFill))
            if let loaded {
                Image(uiImage: loaded)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { if let loaded { onOpen(loaded) } }
        .accessibilityElement()
        .accessibilityLabel(image.name ?? "Image")
        .accessibilityHint(loaded == nil ? "" : "Double-tap to view full screen")
        .accessibilityAddTraits(.isButton)
        .task(id: image.id) {
            guard loaded == nil else { return }
            if let result = await loader.load(image) {
                loaded = result
            } else {
                failed = true
            }
        }
    }
}

/// Full-screen image with pinch and double-tap zoom, and sharing (save to Photos, AirDrop…).
struct ImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    let name: String?

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in scale = min(max(lastScale * value.magnification, 1), 6) }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1 { resetZoom() }
                            }
                            .simultaneously(with: DragGesture()
                                .onChanged { value in
                                    guard scale > 1 else { return }
                                    offset = CGSize(width: lastOffset.width + value.translation.width,
                                                    height: lastOffset.height + value.translation.height)
                                }
                                .onEnded { _ in lastOffset = offset })
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(duration: 0.3)) {
                            if scale > 1 { resetZoom() } else { scale = 2.5; lastScale = 2.5 }
                        }
                    }
            }
            .background(Color.black.ignoresSafeArea())
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview(name ?? "Image", image: Image(uiImage: image)))
                }
            }
        }
    }

    private func resetZoom() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}
