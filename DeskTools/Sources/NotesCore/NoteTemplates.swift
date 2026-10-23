import DeskCore
import Foundation

public struct NoteTemplate: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var text: String
    public init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
            !text.isEmpty, text.utf8.count <= 128_000
        else { throw DeskError.invalid(L10n.text("範本需要名稱及內容（最多 128 KB）。")) }
    }
    public func render(at date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HH:mm"
        return text.replacingOccurrences(of: "{{date}}", with: day)
            .replacingOccurrences(of: "{{time}}", with: formatter.string(from: date))
            .replacingOccurrences(of: "{{title}}", with: name)
    }
    public static let builtIns: [Self] = [
        .init(
            id: UUID(uuidString: "9C29AB7E-741A-4F1B-AB11-000000000001")!, name: L10n.text("會議紀錄"),
            text: L10n.text("# 會議紀錄 · {{date}}\n\n時間：{{time}}\n參與者：\n\n## 議題\n- \n\n## 決定\n- \n\n## 跟進\n- [ ] \n\n#會議")),
        .init(
            id: UUID(uuidString: "9C29AB7E-741A-4F1B-AB11-000000000002")!, name: L10n.text("工作日誌"),
            text: L10n.text("# 工作日誌 · {{date}}\n\n## 今日重點\n- [ ] \n\n## 工作紀錄\n- {{time}} \n\n## 待跟進\n- [ ] \n\n#工作")),
    ]
}

public enum NoteTags {
    private static let expression = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_/#])#([\\p{L}\\p{N}_-]{1,64})")
    public static func parse(_ text: String) -> [String] {
        guard text.contains("#") else { return [] }
        var result: [String] = []
        var seen: Set<String> = []
        expression.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            guard let match, let range = Range(match.range(at: 1), in: text) else { return }
            let tag = String(text[range]).lowercased()
            if seen.insert(tag).inserted { result.append(tag) }
            if result.count == 32 { stop.pointee = true }
        }
        return result
    }
}
