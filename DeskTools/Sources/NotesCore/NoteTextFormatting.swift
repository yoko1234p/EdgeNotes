import DeskCore
import Foundation

public enum NoteTextStyle: Equatable { case bold, italic, code, heading, bullet, task }
public struct NoteTextEdit {
    public let range: NSRange
    public let replacement: String
    public let selection: NSRange
}
public enum NoteTextFormatting {
    public static func edit(_ text: String, selection: NSRange, style: NoteTextStyle) -> NoteTextEdit? {
        let source = text as NSString
        guard selection.location <= source.length, selection.length <= source.length - selection.location else {
            return nil
        }
        switch style {
        case .bold, .italic, .code:
            let mark = style == .bold ? "**" : style == .italic ? "*" : "`"
            let size = mark.utf16.count
            let value = selection.length == 0 ? L10n.text("文字") : source.substring(with: selection)
            if selection.location >= size, NSMaxRange(selection) + size <= source.length,
                source.substring(with: NSRange(location: selection.location - size, length: size)) == mark,
                source.substring(with: NSRange(location: NSMaxRange(selection), length: size)) == mark
            {
                return NoteTextEdit(
                    range: NSRange(location: selection.location - size, length: selection.length + size * 2),
                    replacement: value,
                    selection: NSRange(location: selection.location - size, length: value.utf16.count))
            }
            return NoteTextEdit(
                range: selection, replacement: mark + value + mark,
                selection: NSRange(location: selection.location + size, length: value.utf16.count))
        case .heading, .bullet, .task:
            var selected = selection
            if selected.length > 0, NSMaxRange(selected) < source.length,
                source.substring(with: NSRange(location: NSMaxRange(selected) - 1, length: 1)) == "\n"
            {
                selected.length -= 1
            }
            let range = source.lineRange(for: selected)
            let prefix = style == .heading ? "# " : style == .bullet ? "- " : "- [ ] "
            let lines = source.substring(with: range).components(separatedBy: "\n")
            let nonempty = lines.filter { !$0.isEmpty }
            let remove =
                !nonempty.isEmpty
                && nonempty.allSatisfy { $0.hasPrefix(prefix) || (style == .task && $0.hasPrefix("- [x] ")) }
            let replacement = lines.enumerated().map { index, line in
                if index == lines.count - 1 && line.isEmpty && range.length > 0 { return line }
                if remove { return String(line.dropFirst(prefix.count)) }
                return prefix + line
            }.joined(separator: "\n")
            return NoteTextEdit(
                range: range, replacement: replacement,
                selection: NSRange(location: range.location, length: replacement.utf16.count))
        }
    }
}
