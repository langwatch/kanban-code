import SwiftUI

/// An image of a sent message: loaded from the master that keeps it, shown
/// small, and full screen on a tap.
struct RemoteImageThumbnail: View {
    let load: (() async throws -> Data)?
    var identifier = "messageImage"
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var viewing = false
    @State private var showFailure = false

    var body: some View {
        Button {
            if image != nil { viewing = true } else if failure != nil { showFailure = true }
        } label: {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if failure != nil || load == nil {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 64, height: 64)
            .background(Color(.tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(image != nil ? "Image" : failure != nil ? "Image could not load" : "Image loading")
        .accessibilityIdentifier(identifier)
        .task { await fetch() }
        .fullScreenCover(isPresented: $viewing) {
            if let image { ImageViewer(image: image) }
        }
        .alert("Cannot show the image", isPresented: $showFailure) {
            Button("Try again") { Task { await fetch() } }
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func fetch() async {
        guard image == nil, let load else { return }
        failure = nil
        do {
            let data = try await load()
            if let decoded = UIImage(data: data) {
                image = decoded
            } else {
                failure = "The master sent something that is not an image."
            }
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// One image full screen, with pinch and double tap to zoom.
struct ImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(max(1, scale * pinch))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gesture(MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in scale = min(max(1, scale * value.magnification), 5) })
                .onTapGesture(count: 2) {
                    withAnimation(.snappy) { scale = scale > 1 ? 1 : 2.5 }
                }
                .accessibilityLabel("Image")
                .accessibilityIdentifier("imageViewer")
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(12)
            }
            .buttonStyle(.glass)
            .padding()
            .accessibilityLabel("Close")
            .accessibilityIdentifier("imageViewerClose")
        }
        .statusBarHidden()
    }
}

/// Images fetched from a master, kept in memory so a list that redraws does
/// not fetch them again.
enum RemoteImageCache {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    static func data(_ key: String, load: () async throws -> Data) async throws -> Data {
        if let cached = cache.object(forKey: key as NSString) { return cached as Data }
        let data = try await load()
        cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }
}

/// A row of a message's images, over its bubble.
struct RemoteImageRow: View {
    let count: Int
    var identifier = "messageImage"
    let load: ((Int) async throws -> Data)?

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 48)
            ForEach(0..<count, id: \.self) { index in
                RemoteImageThumbnail(load: load.map { load in { try await load(index) } }, identifier: identifier)
            }
        }
    }
}
