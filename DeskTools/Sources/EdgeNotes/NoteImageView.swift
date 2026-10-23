import AppKit
import DeskCore
import NotesCore
import SwiftUI
import UniformTypeIdentifiers

private enum NoteThumbnailCache {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 16
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()
}

struct NoteImageView: View {
    let attachment: NoteAttachment
    let export: () -> Void
    @State private var image: NSImage?
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: export) {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                } else if failed {
                    Label(L10n.text("圖片暫不可讀取，可另存原檔"), systemImage: "photo.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                }
            }.buttonStyle(.plain).help(L10n.text("另存圖片"))
            Text(attachment.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("notes.image." + attachment.id.uuidString)
        .task(id: attachment.id) {
            let key = attachment.id.uuidString as NSString
            if let cached = NoteThumbnailCache.images.object(forKey: key) {
                image = cached
                return
            }
            let data = attachment.data
            let thumbnail = await Task.detached(priority: .utility) { NoteImages.thumbnail(data) }.value
            guard !Task.isCancelled else { return }
            guard let thumbnail else {
                failed = true
                return
            }
            let rendered = NSImage(cgImage: thumbnail, size: .zero)
            NoteThumbnailCache.images.setObject(rendered, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height)
            image = rendered
        }
        .onDisappear { image = nil }
    }
}
