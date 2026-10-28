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

/// A row of tappable thumbnails; tapping one opens a full-screen viewer you can swipe through.
struct ChatImageStrip: View {
    let images: [ChatImage]
    var size: CGFloat = 120

    @State private var viewing: ViewerItem?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(images) { image in
                    ChatImageThumbnail(image: image, size: size) {
                        viewing = ViewerItem(startID: image.id)
                    }
                }
            }
        }
        .scrollDisabled(images.count < 3)
        .fixedSize(horizontal: images.count < 3, vertical: true)
        .fullScreenCover(item: $viewing) { item in
            ImageViewer(images: images, startID: item.startID)
        }
    }

    private struct ViewerItem: Identifiable {
        let id = UUID()
        let startID: String
    }
}

private struct ChatImageThumbnail: View {
    @Environment(\.chatImageLoader) private var loader
    let image: ChatImage
    let size: CGFloat
    let onOpen: () -> Void

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
        .onTapGesture { if loaded != nil { onOpen() } }
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

/// Full-screen images you can swipe between, with pinch and double-tap zoom on each,
/// and sharing (save to Photos, AirDrop…) for the one showing.
struct ImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatImageLoader) private var loader
    let images: [ChatImage]

    @State private var selection: String
    @State private var loaded: [String: UIImage] = [:]

    init(images: [ChatImage], startID: String) {
        self.images = images
        _selection = State(initialValue: startID)
    }

    private var current: (image: UIImage, name: String?)? {
        guard let image = loaded[selection] else { return nil }
        return (image, images.first { $0.id == selection }?.name)
    }

    private var position: Int {
        (images.firstIndex { $0.id == selection } ?? 0) + 1
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(images) { image in
                    ZoomableImage(image: loaded[image.id])
                        .tag(image.id)
                        .task {
                            // Thumbnails are cached, so this is usually instant.
                            if loaded[image.id] == nil, let result = await loader.load(image) {
                                loaded[image.id] = result
                            }
                        }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            .background(Color.black.ignoresSafeArea())
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationTitle(images.count > 1 ? "\(position) of \(images.count)" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let current {
                        ShareLink(item: Image(uiImage: current.image),
                                  preview: SharePreview(current.name ?? "Image", image: Image(uiImage: current.image)))
                    }
                }
            }
        }
    }
}

/// One page of the viewer. Dragging pans only while zoomed in, so swipes still change pages.
private struct ZoomableImage: View {
    let image: UIImage?

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { value in scale = min(max(lastScale * value.magnification, 1), 6) }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1 { withAnimation(.spring(duration: 0.25)) { reset() } }
                    }
            )
            .simultaneousGesture(scale > 1 ? pan : nil)
            .onTapGesture(count: 2) {
                withAnimation(.spring(duration: 0.3)) {
                    if scale > 1 { reset() } else { scale = 2.5; lastScale = 2.5 }
                }
            }
            .onDisappear { reset() }
        }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}
