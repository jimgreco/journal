import SwiftUI
import UIKit

/// Photo files on this iPhone, one JPEG per photo id, next to the entry store.
///
/// Like the entry store, files get complete file protection (unreadable while
/// the phone is locked) and the folder is excluded from iCloud/iTunes backups.
struct PhotoFiles: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString.lowercased()).jpg")
    }

    func data(for id: UUID) -> Data? {
        try? Data(contentsOf: url(for: id))
    }

    func contains(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    func write(_ data: Data, for id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
        try data.write(to: url(for: id), options: [.atomic, .completeFileProtection])
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum PhotoProcessing {
    static let maxDimension: CGFloat = 2048
    static let maxBytes = 3_500_000

    /// Re-encodes a picked or captured image as a JPEG of at most 2048 px on the
    /// long side. Redrawing keeps only the pixels, so location and other
    /// camera metadata are dropped.
    nonisolated static func jpeg(from image: UIImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let drawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        for quality in [0.75, 0.6, 0.45, 0.3] {
            if let data = drawn.jpegData(compressionQuality: quality), data.count <= maxBytes { return data }
        }
        return nil
    }

    nonisolated static func jpeg(from data: Data) -> Data? {
        UIImage(data: data).flatMap { jpeg(from: $0) }
    }
}

/// Decoded images, so scrolling the list doesn't decode the same JPEG twice.
@MainActor
enum PhotoCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    static func image(_ id: UUID, maxPixels: CGFloat?) -> UIImage? {
        cache.object(forKey: key(id, maxPixels))
    }

    static func store(_ image: UIImage, _ id: UUID, maxPixels: CGFloat?) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key(id, maxPixels), cost: cost)
    }

    static func removeAll() {
        cache.removeAllObjects()
    }

    private static func key(_ id: UUID, _ maxPixels: CGFloat?) -> NSString {
        "\(id.uuidString)-\(Int(maxPixels ?? 0))" as NSString
    }
}

/// Shows one photo: from this iPhone if it's here, otherwise downloaded once
/// from the server and kept here.
struct PhotoView: View {
    @Environment(EntryStore.self) private var store
    @Environment(Session.self) private var session
    let id: UUID
    /// Decode at most this many pixels on the long side (thumbnails); nil for full size.
    var maxPixels: CGFloat? = 300
    var contentMode: ContentMode = .fill
    /// A photo added in the open edit and not saved yet.
    var unsaved: Data?

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: id) { await load() }
        .accessibilityLabel("Photo")
    }

    private func load() async {
        if let cached = PhotoCache.image(id, maxPixels: maxPixels) {
            image = cached
            return
        }
        let found: Data? = if let unsaved { unsaved } else { await store.photoData(id, remote: SessionRemote(session: session)) }
        guard let data = found else {
            failed = true
            return
        }
        let limit = maxPixels
        let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let full = UIImage(data: data) else { return nil }
            guard let limit else { return full.preparingForDisplay() ?? full }
            let scale = limit / max(full.size.width, full.size.height)
            guard scale < 1 else { return full.preparingForDisplay() ?? full }
            return full.preparingThumbnail(of: CGSize(width: full.size.width * scale, height: full.size.height * scale))
        }.value
        if let decoded {
            PhotoCache.store(decoded, id, maxPixels: maxPixels)
            image = decoded
        } else {
            failed = true
        }
    }
}

/// Full-screen photo, tap or swipe down to close.
struct PhotoViewer: View {
    let id: UUID
    var unsaved: Data?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            PhotoView(id: id, maxPixels: nil, contentMode: .fit, unsaved: unsaved)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .white.opacity(0.3))
            }
            .padding()
            .accessibilityLabel("Close")
        }
        .onTapGesture { dismiss() }
        .gesture(DragGesture().onEnded { if $0.translation.height > 80 { dismiss() } })
    }
}

struct PhotoRef: Identifiable, Hashable {
    let id: UUID
}

/// The system camera. Shots go straight into the entry and are not saved to
/// the photo library.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
