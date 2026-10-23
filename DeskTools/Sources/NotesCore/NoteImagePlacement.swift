import Foundation

/// Local image references stay in the Markdown source and travel with ordinary text edits.
public enum NoteImagePlacement {
    public struct Reference {
        public let id: UUID
        public let range: NSRange
    }
    public enum Block: Equatable {
        case text(String)
        case image(UUID)
    }
    private static let expression = try! NSRegularExpression(
        pattern: #"!\[image\]\(edgenotes-image:([0-9A-Fa-f-]{36})\)"#)
    public static func marker(_ id: UUID) -> String { "![image](edgenotes-image:\(id.uuidString))" }
    public static func references(in text: String) -> [Reference] {
        let source = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap {
            guard let id = UUID(uuidString: source.substring(with: $0.range(at: 1))) else { return nil }
            return Reference(id: id, range: $0.range)
        }
    }
    public static func blocks(_ text: String) -> [Block] {
        let source = text as NSString
        var cursor = 0
        var result: [Block] = []
        for image in references(in: text) {
            if image.range.location > cursor {
                result.append(
                    .text(source.substring(with: NSRange(location: cursor, length: image.range.location - cursor))))
            }
            result.append(.image(image.id))
            cursor = NSMaxRange(image.range)
        }
        if cursor < source.length { result.append(.text(source.substring(from: cursor))) }
        return result
    }
    public static func replacingIDs(in text: String, with mapping: [UUID: UUID]) -> String {
        let result = NSMutableString(string: text)
        for reference in references(in: text).reversed() {
            if let replacement = mapping[reference.id] {
                result.replaceCharacters(in: reference.range, with: marker(replacement))
            }
        }
        return result as String
    }
    public static func removing(_ id: UUID, from text: String) -> String {
        text.replacingOccurrences(of: marker(id), with: "")
    }
    public static func inserted(_ ids: [UUID], into text: String, at range: NSRange) -> String {
        let source = text as NSString
        let location = min(source.length, max(0, range.location))
        let length = min(max(0, range.length), source.length - location)
        let before = source.substring(to: location)
        let after = source.substring(from: location + length)
        return before + (before.isEmpty || before.hasSuffix("\n") ? "" : "\n")
            + ids.map(marker).joined(separator: "\n") + (after.hasPrefix("\n") ? "" : "\n") + after
    }
    /// Rebase an asynchronous paste after text edits without deleting a newly typed selection.
    public static func rebased(_ range: NSRange, from old: String, to new: String) -> NSRange {
        guard old != new else { return range }
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - suffix - 1] == b[b.count - suffix - 1] {
            suffix += 1
        }
        if NSMaxRange(range) <= prefix { return range }
        if range.location >= a.count - suffix {
            return NSRange(location: max(0, min(b.count, range.location + b.count - a.count)), length: range.length)
        }
        return NSRange(location: b.count - suffix, length: 0)
    }
}
