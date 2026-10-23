import DeskCore
import Foundation

public struct NoteCalculationLine: Equatable, Sendable {
    public let line: Int
    public let output: String
    public let failed: Bool
    public let copyOutput: String
    public let isInline: Bool

    public init(line: Int, output: String, failed: Bool, copyOutput: String? = nil, isInline: Bool = false) {
        self.line = line
        self.output = output
        self.failed = failed
        self.copyOutput = copyOutput ?? output
        self.isInline = isInline
    }
}

/// A bounded arithmetic parser: never evaluates JavaScript, shell commands or note contents as code.
public enum NoteCalculations {
    public static func evaluate(_ text: String, rates: [String: Double] = [:]) -> [NoteCalculationLine] {
        guard text.utf8.count <= 1_000_000 else { return [] }
        var context = CalculationContext(rates: rates)
        var results: [NoteCalculationLine] = []
        let sourceText = text as NSString
        for (index, range) in NoteTextLines.ranges(in: text).enumerated() {
            if Task<Never, Never>.isCancelled { break }
            let source = sourceText.substring(with: range).trimmingCharacters(in: .whitespaces)
            if source.isEmpty {
                context.section = []
                continue
            }
            guard !source.hasPrefix("#"), !source.contains("edgenotes-image:") else {
                continue
            }
            let assignment = CalculationParser.declaredVariable(in: source)
            if source.utf16.count > 2048 {
                if let assignment {
                    context.invalidate(assignment)
                    let output = CalculationError.tooLong.localizedDescription
                    results.append(.init(line: index, output: output, failed: true, copyOutput: output))
                }
                continue
            }
            var isInline = false
            do {
                let (value, updatedContext) = try parseLine(source, context: context, isInline: &isInline)
                context = updatedContext
                context.previous = value
                context.section.append(value)
                results.append(
                    .init(
                        line: index, output: value.formatted, failed: false, copyOutput: value.copyFormatted,
                        isInline: isInline))
            } catch {
                if let assignment {
                    context.invalidate(assignment)
                }
                if case CalculationError.prose = error, assignment == nil { continue }
                let output =
                    (error as? CalculationError) == .prose
                    ? CalculationError.invalid.localizedDescription : error.localizedDescription
                results.append(.init(line: index, output: output, failed: true, copyOutput: output, isInline: isInline))
            }
        }
        return results
    }

    private static func parseLine(_ source: String, context: CalculationContext, isInline: inout Bool) throws
        -> (CalculationValue, CalculationContext)
    {
        do {
            var parser = try CalculationParser(source, context: context)
            let value = try parser.parse()
            return (value, parser.context)
        } catch {
            guard CalculationParser.declaredVariable(in: source) == nil,
                CalculationParser.startsWithProse(source, context: context)
            else { throw error }
            switch error {
            case CalculationError.prose, CalculationError.tooLong: break
            default: throw error
            }
            for suffix in CalculationParser.embeddedSuffixes(in: source, context: context) {
                var parser: CalculationParser
                do {
                    parser = try CalculationParser(suffix, context: context)
                } catch CalculationError.prose {
                    continue
                } catch {
                    isInline = true
                    throw error
                }
                guard parser.assignment == nil, parser.hasMeaningfulOperation
                else { continue }
                isInline = true
                do {
                    let value = try parser.parse()
                    return (value, parser.context)
                } catch CalculationError.prose {
                    // A consumed operation or unit belongs to this expression. Retrying
                    // a later operand could otherwise turn an invalid expression green.
                    if parser.position > 1 { throw CalculationError.invalid }
                    isInline = false
                }
            }
            throw CalculationError.prose
        }
    }
}

private enum CalculationError: LocalizedError {
    case prose, invalid, mismatch, rates, domain, tooLong, dependency
    var errorDescription: String? {
        switch self {
        case .prose: return nil
        case .invalid: return L10n.text("算式未完成")
        case .mismatch: return L10n.text("單位不相容")
        case .rates: return L10n.text("先更新匯率")
        case .domain: return L10n.text("無有效結果")
        case .tooLong: return L10n.text("算式太長")
        case .dependency: return L10n.text("變數未有有效結果")
        }
    }
}
private struct CalculationUnit {
    let symbol: String
    let dimension: String
    let factor: Double
    var offset: Double = 0
}
private struct CalculationValue {
    var amount: Double
    var unit: CalculationUnit?
    var percentage = false
    func converted(to target: CalculationUnit, context: CalculationContext) throws -> Self {
        guard let unit, unit.dimension == target.dimension else { throw CalculationError.mismatch }
        if unit.symbol == target.symbol { return self }
        if unit.dimension == "currency" {
            guard let from = context.rates[unit.symbol], let to = context.rates[target.symbol],
                from.isFinite, to.isFinite, from > 0, to > 0
            else { throw CalculationError.rates }
            return .init(amount: amount / from * to, unit: target)
        }
        return .init(amount: (amount * unit.factor + unit.offset - target.offset) / target.factor, unit: target)
    }
    func adding(_ other: Self, subtract: Bool = false, context: CalculationContext) throws -> Self {
        let rhs: Double
        if other.percentage {
            rhs = amount * other.amount
        } else if let unit {
            rhs = try other.converted(to: unit, context: context).amount
        } else {
            guard other.unit == nil else { throw CalculationError.mismatch }
            rhs = other.amount
        }
        return .init(amount: amount + (subtract ? -rhs : rhs), unit: unit, percentage: percentage)
    }
    var formatted: String {
        format(copy: false)
    }
    var copyFormatted: String { format(copy: true) }
    private func format(copy: Bool) -> String {
        let value = percentage ? amount * 100 : amount
        let magnitude = abs(value)
        var style = FloatingPointFormatStyle<Double>.number.locale(Locale(identifier: "en_US"))
        if magnitude > 0, magnitude < 1e-6 || magnitude >= 1e15 {
            style = style.notation(.scientific).precision(.significantDigits(1...(copy ? 15 : 6)))
        } else if copy {
            style = style.precision(.significantDigits(1...15))
        } else {
            var precision = unit != nil ? 2 : 6
            if magnitude > 0, magnitude < pow(10, -Double(precision)) {
                precision = min(12, max(precision, Int(ceil(-log10(magnitude))) + 2))
            }
            let minimum = ["USD", "EUR", "GBP"].contains(unit?.symbol ?? "") ? 2 : 0
            style = style.precision(.fractionLength(minimum...precision))
        }
        let number = value.formatted(style)
        if percentage { return number + " %" }
        guard let unit else { return number }
        switch unit.symbol {
        case "USD":
            return "$" + number
        case "EUR":
            return "€" + number
        case "GBP":
            return "£" + number
        default: return number + " " + unit.symbol
        }
    }
}
private struct CalculationContext {
    var variables: [String: CalculationValue] = [:]
    var invalidVariables: Set<String> = []
    var previous: CalculationValue?
    var section: [CalculationValue] = []
    var pixelsPerEm = 16.0
    var pixelsPerInch = 96.0
    let rates: [String: Double]
    mutating func invalidate(_ name: String) {
        variables.removeValue(forKey: name)
        invalidVariables.insert(["em", "ppi"].contains(name.lowercased()) ? name.lowercased() : name)
    }
    func checkedUnit(_ raw: String, definingPPI: Bool = false) throws -> CalculationUnit? {
        let name = raw.lowercased()
        let pixels = ["px", "pixel", "pixels", "em"].contains(name)
        if name == "em" && invalidVariables.contains("em")
            || pixels && invalidVariables.contains("ppi") && !definingPPI
        {
            throw CalculationError.dependency
        }
        return unit(raw)
    }
    func unit(_ raw: String) -> CalculationUnit? {
        let word = raw.lowercased()
        if ["USD", "EUR", "GBP", "HKD", "JPY", "CNY", "CAD", "AUD", "KRW", "CHF", "SGD", "NZD"].contains(
            raw.uppercased())
        {
            return .init(symbol: raw.uppercased(), dimension: "currency", factor: 1)
        }
        if let currency = ["dollar": "USD", "dollars": "USD", "euro": "EUR", "euros": "EUR", "yen": "JPY"][word] {
            return .init(symbol: currency, dimension: "currency", factor: 1)
        }
        let units: [(String, String, Double, [String])] = [
            ("m", "length", 1, ["m", "meter", "meters", "metre", "metres", "米"]),
            ("cm", "length", 0.01, ["cm", "centimeter", "centimeters", "厘米"]),
            ("mm", "length", 0.001, ["mm", "millimeter", "millimeters", "毫米"]),
            ("km", "length", 1000, ["km", "kilometer", "kilometers", "公里"]),
            ("inch", "length", 0.0254, ["inch", "inches"]), ("ft", "length", 0.3048, ["ft", "feet", "foot"]),
            ("yd", "length", 0.9144, ["yd", "yard", "yards"]), ("mi", "length", 1609.344, ["mi", "mile", "miles"]),
            ("s", "time", 1, ["s", "sec", "second", "seconds", "秒"]),
            ("min", "time", 60, ["min", "minute", "minutes", "分鐘"]),
            ("hr", "time", 3600, ["hr", "hour", "hours", "小時"]), ("day", "time", 86400, ["day", "days", "日"]),
            ("week", "time", 604800, ["week", "weeks", "星期"]),
            ("L", "volume", 1, ["l", "litre", "litres", "liter", "liters", "升"]),
            ("ml", "volume", 0.001, ["ml", "milliliter", "milliliters", "毫升"]),
            ("m³", "volume", 1000, ["cbm", "m3", "m³"]),
            ("tsp", "volume", 0.00492892159375, ["tsp", "teaspoon", "teaspoons"]),
            ("tbsp", "volume", 0.01478676478125, ["tbsp", "tablespoon", "tablespoons"]),
            ("cup", "volume", 0.2365882365, ["cup", "cups"]),
            ("gal", "volume", 3.785411784, ["gal", "gallon", "gallons"]),
            ("kg", "mass", 1, ["kg", "kilogram", "kilograms", "公斤"]),
            ("g", "mass", 0.001, ["g", "gram", "grams", "克"]),
            ("lb", "mass", 0.45359237, ["lb", "lbs", "pound", "pounds", "磅"]),
            ("oz", "mass", 0.028349523125, ["oz", "ounce", "ounces"]),
            ("t", "mass", 1000, ["tonne", "tonnes"]),
            ("m²", "area", 1, ["sqm", "m2", "m²"]), ("cm²", "area", 0.0001, ["cm2", "cm²"]),
            ("ha", "area", 10000, ["ha", "hectare", "hectares"]),
            ("rad", "angle", 1, ["rad", "radian", "radians"]),
            ("°", "angle", Double.pi / 180, ["°", "deg", "degree", "degrees"]),
        ]
        if let item = units.first(where: { $0.3.contains(word) }) {
            return .init(symbol: item.0, dimension: item.1, factor: item.2)
        }
        let dataUnits: [String: Double] = [
            "b": 1, "B": 8, "Kb": 1e3, "KB": 8e3, "Mb": 1e6, "MB": 8e6,
            "Gb": 1e9, "GB": 8e9, "TB": 8e12, "KiB": 8192, "MiB": 8_388_608, "GiB": 8_589_934_592,
        ]
        if let factor = dataUnits[raw] { return .init(symbol: raw, dimension: "data", factor: factor) }
        if ["bit", "bits"].contains(word) { return .init(symbol: "b", dimension: "data", factor: 1) }
        if ["byte", "bytes"].contains(word) { return .init(symbol: "B", dimension: "data", factor: 8) }
        let px = 0.0254 / pixelsPerInch
        if raw == "K" { return .init(symbol: "K", dimension: "temperature", factor: 1) }
        switch word {
        case "px", "pixel", "pixels": return .init(symbol: "px", dimension: "length", factor: px)
        case "em": return .init(symbol: "em", dimension: "length", factor: px * pixelsPerEm)
        case "pt": return .init(symbol: "pt", dimension: "length", factor: 0.0254 / 72)
        case "c", "celsius", "°c": return .init(symbol: "°C", dimension: "temperature", factor: 1, offset: 273.15)
        case "f", "fahrenheit", "°f":
            return .init(symbol: "°F", dimension: "temperature", factor: 5 / 9, offset: 273.15 - 32 * (5.0 / 9))
        case "kelvin": return .init(symbol: "K", dimension: "temperature", factor: 1)
        default: return nil
        }
    }
}

private struct CalculationParser {
    private static let functionNames: Set<String> = [
        "sqrt", "cbrt", "abs", "ln", "log", "root", "sin", "cos", "tan", "asin", "acos", "atan",
        "round", "ceil", "floor", "fact", "sinh", "cosh", "tanh",
    ]
    private static let resultNames: Set<String> = ["pi", "e", "prev", "sum", "total", "avg", "average"]
    private static let suffixStarts = try! NSRegularExpression(
        pattern: #"\d+(?:,\d{3})*(?:\.\d+)?(?:[eE][+-]?\d+)?|\.\d+|[A-Za-z_][A-Za-z0-9_]*|[$€£(+\-]"#)
    private static let assignmentExpression = try! NSRegularExpression(
        pattern: #"\A([\p{L}_][\p{L}\p{N}_²³]*)\s*="#)
    private static let lexer = try! NSRegularExpression(
        pattern: #"\d+(?:,\d{3})*(?:\.\d+)?(?:[eE][+-]?\d+)?|\.\d+|°[cCfF]|[\p{L}_][\p{L}\p{N}_²³]*|[+\-*/^()%=$€£°]"#)
    enum Token: Equatable {
        case number(Double)
        case word(String)
        case symbol(String)
    }
    let tokens: [Token]
    var position = 0
    var depth = 0
    var context: CalculationContext
    static func startsWithProse(_ source: String, context: CalculationContext) -> Bool {
        let text = source as NSString
        guard let first = lexer.firstMatch(in: source, range: NSRange(location: 0, length: text.length)) else {
            return false
        }
        let name = text.substring(with: first.range)
        return name.first?.isLetter == true && !functionNames.contains(name.lowercased())
            && !resultNames.contains(name.lowercased()) && context.variables[name] == nil
            && !context.invalidVariables.contains(name) && context.unit(name) == nil
    }
    static func embeddedSuffixes(in source: String, context: CalculationContext) -> [String] {
        let text = source as NSString
        var suffixes: [String] = []
        for match in suffixStarts.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            guard match.range.location > 0 else { continue }
            let token = text.substring(with: match.range)
            if token.first?.isLetter == true || token.first == "_" {
                guard
                    functionNames.contains(token.lowercased()) || resultNames.contains(token.lowercased())
                        || context.variables[token] != nil || context.invalidVariables.contains(token)
                else { continue }
            }
            let prefix = text.substring(to: match.range.location)
            let wordPrefix = prefix.reversed().prefix { !$0.isWhitespace }
            guard !wordPrefix.contains("/"), !wordPrefix.contains("@"),
                !wordPrefix.contains(where: \.isNumber)
            else { continue }
            var suffix = text.substring(from: match.range.location).trimmingCharacters(in: .whitespaces)
            while let last = suffix.last, ".。!?！？;；".contains(last) { suffix.removeLast() }
            guard suffix.range(of: #"^\d{1,4}([-/])\d{1,2}\1\d{1,4}$"#, options: .regularExpression) == nil else {
                continue
            }
            suffixes.append(suffix)
            if suffixes.count == 32 { break }
        }
        return suffixes
    }
    var hasMeaningfulOperation: Bool {
        for (index, token) in tokens.enumerated() {
            switch token {
            case .symbol(let value) where index > 0 && ["+", "-", "*", "/", "^", "%"].contains(value): return true
            case .word(let value):
                if Self.functionNames.contains(value.lowercased())
                    || ["in", "into", "to", "as", "of", "off", "on", "times", "mul", "divide", "mod"].contains(
                        value.lowercased())
                    || context.variables[value] != nil || context.invalidVariables.contains(value)
                {
                    return true
                }
            default: break
            }
        }
        return false
    }
    static func declaredVariable(in source: String) -> String? {
        let prefix = (source as NSString).substring(to: min(2048, source.utf16.count))
        let text = prefix as NSString
        guard let match = assignmentExpression.firstMatch(in: prefix, range: NSRange(location: 0, length: text.length))
        else { return nil }
        return text.substring(with: match.range(at: 1))
    }
    init(_ source: String, context: CalculationContext) throws {
        self.context = context
        var source = source
        for (pattern, replacement) in [
            ("(?i)square root of", "sqrt"), ("(?i)cube root of", "cbrt"),
            ("(?i)tea spoons?", "tsp"), ("(?i)table spoons?", "tbsp"),
            ("(?i)cubic meters?", "cbm"),
        ] { source = source.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
        source = source.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
        let regex = Self.lexer
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: source.utf16.count))
        guard matches.count <= 256 else { throw CalculationError.tooLong }
        var cursor = 0
        var parsed: [Token] = []
        let text = source as NSString
        for match in matches {
            guard
                text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                    .trimmingCharacters(in: .whitespaces).isEmpty
            else { throw CalculationError.prose }
            let token = text.substring(with: match.range)
            if let number = Double(token.replacingOccurrences(of: ",", with: "")) {
                parsed.append(.number(number))
            } else if token.first?.isLetter == true || token.first == "_" || token.count == 2 && token.first == "°" {
                parsed.append(.word(token))
            } else {
                parsed.append(.symbol(token))
            }
            cursor = NSMaxRange(match.range)
        }
        guard text.substring(from: cursor).trimmingCharacters(in: .whitespaces).isEmpty, !parsed.isEmpty
        else { throw CalculationError.prose }
        tokens = parsed
    }
    var peek: Token? { position < tokens.count ? tokens[position] : nil }
    mutating func take(_ token: Token) -> Bool {
        if peek == token {
            position += 1
            return true
        }
        return false
    }
    mutating func word(_ choices: [String]) -> Bool {
        guard case .word(let value) = peek, choices.contains(value.lowercased()) else { return false }
        position += 1
        return true
    }
    var assignment: String? {
        guard tokens.count >= 2, case .word(let name) = tokens[0], tokens[1] == .symbol("=") else { return nil }
        return name
    }
    mutating func parse() throws -> CalculationValue {
        let assignment = assignment
        if assignment != nil { position = 2 }
        var value = try expression()
        if word(["in", "into", "to", "as"]) {
            let article = word(["a"])
            if take(.symbol("%")) {
                guard word(["of"]) else { throw CalculationError.invalid }
                let rhs = try expression()
                let other = try compatible(rhs, with: value)
                guard other != 0 else { throw CalculationError.domain }
                value = .init(amount: value.amount / other, percentage: true)
            } else {
                guard !article else { throw CalculationError.invalid }
                guard case .word(let name) = peek, let unit = try context.checkedUnit(name) else {
                    throw CalculationError.invalid
                }
                position += 1
                value = try value.converted(to: unit, context: context)
            }
        }
        guard position == tokens.count else { throw CalculationError.prose }
        guard value.amount.isFinite, abs(value.amount) < 1e100 else { throw CalculationError.domain }
        if let assignment {
            if assignment.lowercased() == "em" {
                guard let px = try context.checkedUnit("px") else { throw CalculationError.invalid }
                let size = try value.converted(to: px, context: context).amount
                guard size > 0, size <= 10000 else { throw CalculationError.domain }
                context.pixelsPerEm = size
            } else if assignment.lowercased() == "ppi" {
                guard value.amount > 0, value.amount <= 100000,
                    value.unit == nil || value.unit?.symbol == "px"
                else { throw CalculationError.domain }
                context.pixelsPerInch = value.amount
            } else {
                guard context.variables.count < 100 || context.variables[assignment] != nil else {
                    throw CalculationError.tooLong
                }
                context.variables[assignment] = value
            }
            context.invalidVariables.remove(
                ["em", "ppi"].contains(assignment.lowercased()) ? assignment.lowercased() : assignment)
        }
        return value
    }
    func compatible(_ rhs: CalculationValue, with lhs: CalculationValue) throws -> Double {
        if let unit = lhs.unit { return try rhs.converted(to: unit, context: context).amount }
        guard rhs.unit == nil else { throw CalculationError.mismatch }
        return rhs.amount
    }
    mutating func expression() throws -> CalculationValue {
        var result = try product()
        while true {
            if take(.symbol("+")) || word(["plus", "and"]) {
                result = try result.adding(product(), context: context)
            } else if take(.symbol("-")) || word(["minus"]) {
                result = try result.adding(product(), subtract: true, context: context)
            } else {
                break
            }
        }
        return result
    }
    mutating func product() throws -> CalculationValue {
        var result = try power()
        while true {
            if take(.symbol("*")) || word(["times", "mul"]) {
                let rhs = try power()
                guard result.unit == nil || rhs.unit == nil else { throw CalculationError.mismatch }
                result = .init(amount: result.amount * rhs.amount, unit: result.unit ?? rhs.unit)
            } else if take(.symbol("/")) || word(["divide"]) {
                let rhs = try power()
                guard rhs.amount != 0 else { throw CalculationError.domain }
                if rhs.unit != nil {
                    result = .init(amount: result.amount / (try compatible(rhs, with: result)))
                } else {
                    result.amount /= rhs.amount
                    result.percentage = false
                }
            } else if word(["mod"]) {
                let rhs = try power()
                guard result.unit == nil, rhs.unit == nil, rhs.amount != 0 else { throw CalculationError.domain }
                result.amount = result.amount.truncatingRemainder(dividingBy: rhs.amount)
            } else if result.percentage && word(["of", "off", "on"]) {
                guard case .word(let operation) = tokens[position - 1] else { throw CalculationError.invalid }
                let inverse = word(["what"])
                if inverse && !word(["is"]) { throw CalculationError.invalid }
                let rhs = try expression()
                let fraction = result.amount
                let factor =
                    operation.lowercased() == "off"
                    ? 1 - fraction : operation.lowercased() == "on" ? 1 + fraction : fraction
                guard !inverse || factor != 0 else { throw CalculationError.domain }
                result = .init(amount: inverse ? rhs.amount / factor : rhs.amount * factor, unit: rhs.unit)
            } else {
                break
            }
        }
        return result
    }
    mutating func power() throws -> CalculationValue {
        var value = try unary()
        if take(.symbol("^")) {
            let exponent = try power()
            guard value.unit == nil, exponent.unit == nil else { throw CalculationError.mismatch }
            value.amount = pow(value.amount, exponent.amount)
        }
        return value
    }
    mutating func unary() throws -> CalculationValue {
        if take(.symbol("-")) {
            var value = try unary()
            value.amount = -value.amount
            return value
        }
        if take(.symbol("+")) { return try unary() }
        var value = try primary()
        if case .word(let name) = peek, value.unit == nil,
            let unit = try context.checkedUnit(name, definingPPI: assignment?.lowercased() == "ppi")
        {
            position += 1
            value.unit = unit
        } else if take(.symbol("°")) {
            value.unit = context.unit("degrees")
        }
        if take(.symbol("%")) {
            guard value.unit == nil else { throw CalculationError.mismatch }
            value.amount /= 100
            value.percentage = true
        }
        return value
    }
    mutating func primary() throws -> CalculationValue {
        depth += 1
        defer { depth -= 1 }
        guard depth <= 32, let token = peek else { throw CalculationError.invalid }
        position += 1
        switch token {
        case .number(let number): return .init(amount: number)
        case .symbol("("):
            let value = try expression()
            guard take(.symbol(")")) else { throw CalculationError.invalid }
            return value
        case .symbol(let symbol) where ["$", "€", "£"].contains(symbol):
            let number = try unary()
            guard number.unit == nil else { throw CalculationError.mismatch }
            return .init(
                amount: number.amount, unit: context.unit(symbol == "$" ? "USD" : symbol == "€" ? "EUR" : "GBP"))
        case .word(let name):
            let lower = name.lowercased()
            if context.invalidVariables.contains(name) { throw CalculationError.dependency }
            if let value = context.variables[name] { return value }
            if lower == "pi" { return .init(amount: .pi) }
            if lower == "e" { return .init(amount: exp(1)) }
            if lower == "prev", let previous = context.previous { return previous }
            if ["sum", "total", "avg", "average"].contains(lower) {
                guard let first = context.section.first else { throw CalculationError.invalid }
                var total = first
                for next in context.section.dropFirst() { total = try total.adding(next, context: context) }
                if ["avg", "average"].contains(lower) { total.amount /= Double(context.section.count) }
                return total
            }
            guard Self.functionNames.contains(lower) else { throw CalculationError.prose }
            let base = ["log", "root"].contains(lower) ? try unary() : nil
            let argument = try unary()
            var number = argument.amount
            if let unit = argument.unit {
                guard ["sin", "cos", "tan"].contains(lower), unit.dimension == "angle" else {
                    throw CalculationError.mismatch
                }
                number *= unit.factor
            }
            switch lower {
            case "sqrt": number = sqrt(number)
            case "cbrt": number = cbrt(number)
            case "abs": number = abs(number)
            case "ln": number = log(number)
            case "log":
                guard let base, base.unit == nil, base.amount > 0, base.amount != 1 else {
                    throw CalculationError.domain
                }
                number = log(number) / log(base.amount)
            case "root":
                guard let base, base.unit == nil, base.amount != 0 else { throw CalculationError.domain }
                number = pow(number, 1 / base.amount)
            case "sin": number = sin(number)
            case "cos": number = cos(number)
            case "tan": number = tan(number)
            case "asin": number = asin(number)
            case "acos": number = acos(number)
            case "atan": number = atan(number)
            case "sinh": number = sinh(number)
            case "cosh": number = cosh(number)
            case "tanh": number = tanh(number)
            case "round": number = number.rounded()
            case "ceil": number = ceil(number)
            case "floor": number = floor(number)
            case "fact":
                guard number >= 0, number <= 170, number.rounded() == number else { throw CalculationError.domain }
                number = number <= 1 ? 1 : (1...Int(number)).reduce(1.0) { $0 * Double($1) }
            default: break
            }
            guard number.isFinite else { throw CalculationError.domain }
            return .init(amount: number)
        default: throw CalculationError.invalid
        }
    }
}
