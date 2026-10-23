import Foundation

public enum NoteChecklist {
    public static func state(_ line: String) -> Bool? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- [ ] ") || trimmed == "- [ ]" { return false }
        if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") || trimmed == "- [x]" || trimmed == "- [X]" {
            return true
        }
        return nil
    }
    public static func toggle(_ text: String, line index: Int) -> String {
        guard index >= 0, index < Int.max else { return text }
        let lines = NoteTextLines.ranges(in: text, limit: index + 1)
        let source = text as NSString
        guard lines.indices.contains(index), let checked = state(source.substring(with: lines[index]))
        else { return text }
        let range = source.range(of: checked ? "[x]" : "[ ]", options: .caseInsensitive, range: lines[index])
        guard range.location != NSNotFound else { return text }
        return source.replacingCharacters(in: range, with: checked ? "[ ]" : "[x]")
    }
}
