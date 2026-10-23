import AppKit
import DeskCore
import NotesCore
import UniformTypeIdentifiers

struct NoteClipboardImageSource: Sendable {
    let name: String
    let data: Data
}

enum NotesClipboardImages {
    /// Read only in response to explicit Paste. Finder images take precedence over file-icon TIFFs.
    static func read(_ pasteboard: NSPasteboard) throws -> [NoteClipboardImageSource]? {
        let urls =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let files = urls.filter {
            $0.isFileURL && UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true
        }
        if !files.isEmpty {
            guard files.count <= 20, files.count == urls.count else {
                throw DeskError.invalid(L10n.text("請一次只貼最多 20 個圖片檔案。"))
            }
            var total = 0
            return try files.map { url in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try BoundedFile.read(url, limit: max(0, 64_000_000 - total))
                total += data.count
                return NoteClipboardImageSource(
                    name: String(url.deletingPathExtension().lastPathComponent.prefix(60)), data: data)
            }
        }
        let items = pasteboard.pasteboardItems ?? []
        let images = items.filter { $0.types.contains(.png) || $0.types.contains(.tiff) }
        guard !images.isEmpty else { return nil }
        guard images.count <= 20 else { throw DeskError.invalid(L10n.text("一次最多貼 20 張圖片。")) }
        var total = 0
        return try images.enumerated().map { index, item in
            let type: NSPasteboard.PasteboardType = item.types.contains(.png) ? .png : .tiff
            guard let data = item.data(forType: type) else { throw DeskError.invalid(L10n.text("未能讀取剪貼簿圖片。")) }
            total += data.count
            guard total <= 64_000_000 else { throw DeskError.invalid(L10n.text("一次貼上的圖片原檔最多 64 MB。")) }
            return NoteClipboardImageSource(name: L10n.text("貼上圖片-%1$@", String(describing: index + 1)), data: data)
        }
    }
    static func prepare(_ sources: [NoteClipboardImageSource]) throws -> [NoteAttachment] {
        try sources.map { source in
            let image = try NoteImages.prepare(source.data)
            return NoteAttachment(name: source.name + "." + image.fileExtension, data: image.data)
        }
    }
}
