import AppKit
import NotesCore

final class NoteInlineAttachment: NSTextAttachment {
    let imageID: UUID
    init(id: UUID) {
        imageID = id
        super.init(data: nil, ofType: nil)
    }
    required init?(coder: NSCoder) { return nil }
}

@MainActor enum NoteAttributedContent {
    static let calculationAttribute = NSAttributedString.Key("EdgeNotes.generatedCalculation")
    private static let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    static func render(
        _ source: String, attachments: [NoteAttachment], calculationAnnotations: [NoteCalculationAnnotation] = []
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: source)
        for item in NoteCalculationText.validAnnotations(calculationAnnotations, in: source) {
            result.addAttribute(calculationAttribute, value: item.text, range: item.range)
        }
        let byID = Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) })
        for reference in NoteImagePlacement.references(in: source).reversed() {
            guard let original = byID[reference.id] else { continue }
            let key = reference.id.uuidString as NSString
            let image: NSImage
            if let cached = thumbnails.object(forKey: key) {
                image = cached
            } else {
                guard let bitmap = NoteImages.thumbnail(original.data, maxPixels: 320) else { continue }
                image = NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
                thumbnails.setObject(image, forKey: key, cost: bitmap.bytesPerRow * bitmap.height)
            }
            let attachment = NoteInlineAttachment(id: reference.id)
            attachment.image = image
            let scale = min(1, 260 / max(1, image.size.width), 220 / max(1, image.size.height))
            attachment.bounds = NSRect(x: 0, y: -2, width: image.size.width * scale, height: image.size.height * scale)
            result.replaceCharacters(in: reference.range, with: NSAttributedString(attachment: attachment))
        }
        return result
    }
    static func calculationAnnotations(in content: NSAttributedString) -> [NoteCalculationAnnotation] {
        let plain = content.string as NSString
        var images: [(NSRange, Int)] = []
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            if let image = value as? NoteInlineAttachment {
                images.append((range, NoteImagePlacement.marker(image.imageID).utf16.count - range.length))
            }
        }
        var result: [NoteCalculationAnnotation] = []
        var imageIndex = 0
        var delta = 0
        content.enumerateAttribute(calculationAttribute, in: NSRange(location: 0, length: content.length)) {
            value, range, _ in
            guard let expected = value as? String, plain.substring(with: range) == expected
            else { return }
            while imageIndex < images.count, NSMaxRange(images[imageIndex].0) <= range.location {
                delta += images[imageIndex].1
                imageIndex += 1
            }
            result.append(.init(location: range.location + delta, text: expected))
        }
        return NoteCalculationText.validAnnotations(result, in: source(content))
    }
    static func displayRanges(_ ranges: [NSRange], source: String) -> [NSRange] {
        let references = NoteImagePlacement.references(in: source)
        func offset(_ position: Int) -> Int {
            position
                - references.reduce(0) { total, reference in
                    total + (NSMaxRange(reference.range) <= position ? reference.range.length - 1 : 0)
                }
        }
        return ranges.map {
            NSRange(location: offset($0.location), length: offset(NSMaxRange($0)) - offset($0.location))
        }
    }
    static func source(_ attributed: NSAttributedString) -> String {
        let result = NSMutableString(string: attributed.string)
        var images: [(NSRange, UUID)] = []
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) {
            value, range, _ in
            if let image = value as? NoteInlineAttachment { images.append((range, image.imageID)) }
        }
        for (range, id) in images.reversed() {
            result.replaceCharacters(in: range, with: NoteImagePlacement.marker(id))
        }
        return result as String
    }
    static func sourceRange(_ selection: NSRange, in content: NSAttributedString) -> NSRange {
        let location = min(content.length, max(0, selection.location))
        let length = min(content.length - location, max(0, selection.length))
        let start = source(content.attributedSubstring(from: NSRange(location: 0, length: location))).utf16.count
        return NSRange(
            location: start,
            length: source(content.attributedSubstring(from: NSRange(location: location, length: length))).utf16.count)
    }
    static func displayOffset(_ offset: Int, source: String) -> Int {
        var delta = 0
        for reference in NoteImagePlacement.references(in: source) {
            if offset >= NSMaxRange(reference.range) {
                delta += reference.range.length - 1
            } else if offset > reference.range.location {
                return reference.range.location - delta + 1
            } else {
                break
            }
        }
        return max(0, offset - delta)
    }
}
