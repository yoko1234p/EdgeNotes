import Foundation

/// Ownership metadata for an answer that is also ordinary, portable note text.
public struct NoteCalculationAnnotation: Codable, Equatable, Sendable {
    public let location: Int
    public let text: String
    public var range: NSRange { NSRange(location: location, length: text.utf16.count) }
    public init(location: Int, text: String) {
        self.location = location
        self.text = text
    }
}

public struct NoteCalculationTextEdit: Equatable, Sendable {
    public let range: NSRange
    public let text: String
}

public enum NoteCalculationText {
    /// Untrusted or stale metadata never authorizes replacing user text.
    public static func validAnnotations(_ annotations: [NoteCalculationAnnotation], in source: String)
        -> [NoteCalculationAnnotation]
    {
        guard !annotations.isEmpty, annotations.count <= 2000, source.utf8.count <= 1_000_000 else { return [] }
        let text = source as NSString
        let lineEnds = Set(NoteTextLines.ranges(in: source).map(NSMaxRange))
        var end = 0
        return annotations.sorted { $0.location < $1.location }.filter { item in
            guard item.location >= end, item.location <= text.length,
                item.text.utf16.count <= min(256, text.length - item.location),
                item.text.hasPrefix("（"), item.text.hasSuffix("）"), item.text.count > 2,
                !item.text.contains(where: \.isNewline), lineEnds.contains(NSMaxRange(item.range)),
                text.substring(with: item.range) == item.text
            else { return false }
            end = NSMaxRange(item.range)
            return true
        }
    }

    public static func input(_ source: String, annotations: [NoteCalculationAnnotation]) -> String {
        let text = NSMutableString(string: source)
        for item in validAnnotations(annotations, in: source).reversed() {
            text.deleteCharacters(in: item.range)
        }
        return text as String
    }

    /// Edits are ordered by source position and affect only owned answer spans or line ends.
    public static func edits(
        in source: String, annotations: [NoteCalculationAnnotation], results: [NoteCalculationLine]
    ) -> [NoteCalculationTextEdit] {
        guard source.utf8.count <= 1_000_000 else { return [] }
        let owned = validAnnotations(annotations, in: source)
        let byEnd = Dictionary(owned.map { (NSMaxRange($0.range), $0) }, uniquingKeysWith: { first, _ in first })
        let byLine = Dictionary(results.map { ($0.line, $0) }, uniquingKeysWith: { first, _ in first })
        let text = source as NSString
        var edits: [NoteCalculationTextEdit] = []
        for (index, line) in NoteTextLines.ranges(in: source).enumerated() {
            let previous = byEnd[NSMaxRange(line)]
            let expression = text.substring(
                with: NSRange(location: line.location, length: line.length - (previous?.range.length ?? 0))
            )
            .trimmingCharacters(in: .whitespaces)
            let result = byLine[index]
            let replacement: String
            if let result, !result.failed, result.output != expression,
                expression.range(of: #"^\d{1,4}([-/])\d{1,2}\1\d{1,4}$"#, options: .regularExpression) == nil
            {
                replacement = "（" + result.output + "）"
            } else {
                replacement = ""
            }
            if replacement != (previous?.text ?? "") {
                edits.append(
                    .init(range: previous?.range ?? NSRange(location: NSMaxRange(line), length: 0), text: replacement))
            }
        }
        return edits
    }

    /// Preserve ownership around a single text replacement; touching an answer detaches it.
    public static func rebased(
        _ annotations: [NoteCalculationAnnotation], from old: String, to new: String
    ) -> [NoteCalculationAnnotation] {
        guard !annotations.isEmpty else { return [] }
        guard old != new else { return validAnnotations(annotations, in: new) }
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix,
            a[a.count - suffix - 1] == b[b.count - suffix - 1]
        { suffix += 1 }
        let result = validAnnotations(annotations, in: old).compactMap { item -> NoteCalculationAnnotation? in
            if NSMaxRange(item.range) <= prefix { return item }
            if item.location >= a.count - suffix {
                return .init(location: item.location + b.count - a.count, text: item.text)
            }
            return nil
        }
        return validAnnotations(result, in: new)
    }
}
