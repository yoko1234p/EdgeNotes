import Foundation

/// Logical lines share NSString's UTF-16 offsets with the native editor.
/// CRLF is one separator; stop before allocating lines beyond the requested limit.
public enum NoteTextLines {
    public static func ranges(in text: String, limit: Int = 2000) -> [NSRange] {
        guard limit > 0 else { return [] }
        let source = text as NSString
        guard source.length > 0 else { return [NSRange(location: 0, length: 0)] }
        var ranges: [NSRange] = []
        var cursor = 0
        while cursor < source.length, ranges.count < limit {
            var start = 0
            var end = 0
            var contentEnd = 0
            source.getLineStart(
                &start, end: &end, contentsEnd: &contentEnd, for: NSRange(location: cursor, length: 0))
            guard end > cursor else { break }
            ranges.append(NSRange(location: start, length: contentEnd - start))
            cursor = end
            if end == source.length, contentEnd < end, ranges.count < limit {
                ranges.append(NSRange(location: end, length: 0))
            }
        }
        return ranges
    }

    public static func index(atUTF16Offset offset: Int, in text: String) -> Int? {
        guard offset >= 0, offset <= text.utf16.count else { return nil }
        let lines = ranges(in: text)
        for (index, range) in lines.enumerated() {
            let end = index + 1 < lines.count ? lines[index + 1].location - 1 : NSMaxRange(range)
            if range.location <= offset, offset <= end { return index }
        }
        return nil
    }
}
