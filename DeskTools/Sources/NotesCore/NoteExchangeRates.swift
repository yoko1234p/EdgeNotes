import DeskCore
import Foundation

public struct NoteExchangeRates: Codable, Equatable, Sendable {
    public let date: String
    public let rates: [String: Double]
    public static func decodeECB(_ data: Data) throws -> Self {
        guard data.count <= 128_000, !data.isEmpty,
            !String(decoding: data, as: UTF8.self).contains("<!DOCTYPE")
        else { throw DeskError.invalid(L10n.text("匯率資料無效。")) }
        let delegate = ECBParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let date = delegate.date, delegate.rates.count >= 2 else {
            throw DeskError.invalid(L10n.text("無法讀取 ECB 匯率。"))
        }
        let snapshot = Self(date: date, rates: delegate.rates.merging(["EUR": 1]) { _, new in new })
        try snapshot.validate()
        return snapshot
    }
    public func validate() throws {
        let calendar = DateFormatter()
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)
        calendar.dateFormat = "yyyy-MM-dd"
        calendar.isLenient = false
        guard date.count == 10, date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
            calendar.date(from: date) != nil,
            rates.count <= 200, rates["EUR"] == 1,
            rates.allSatisfy({ key, value in
                key.utf8.count == 3 && key.utf8.allSatisfy { (65...90).contains($0) }
                    && value.isFinite && value > 0 && value <= 1e9
            })
        else { throw DeskError.invalid(L10n.text("匯率資料格式不正確。")) }
    }
}

private final class ECBParser: NSObject, XMLParserDelegate {
    var date: String?
    var rates: [String: Double] = [:]
    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        guard elementName == "Cube" else { return }
        if let time = attributeDict["time"] { date = time }
        if let currency = attributeDict["currency"], let rate = attributeDict["rate"], let value = Double(rate) {
            rates[currency] = value
        }
    }
}
