import DeskCore
import NotesCore
import SwiftUI

private struct NotePreviewRow: Identifiable {
    enum Content {
        case text(Int, String)
        case image(UUID)
    }
    let id: Int
    let content: Content
    static func rows(_ text: String) -> [Self] {
        var result: [Self] = []
        let preview = String(text.prefix(12_000))
        let source = preview as NSString
        for (lineIndex, range) in NoteTextLines.ranges(in: preview).enumerated() {
            for block in NoteImagePlacement.blocks(source.substring(with: range)) {
                switch block {
                case .image(let id): result.append(.init(id: result.count, content: .image(id)))
                case .text(let value) where !value.isEmpty:
                    result.append(.init(id: result.count, content: .text(lineIndex, value)))
                case .text: break
                }
                if result.count >= 80 { break }
            }
            if result.count >= 80 { break }
        }
        return Array(result.prefix(80))
    }
}

private struct NotePreviewCalculationKey: Equatable {
    let text: String
    let rates: [String: Double]
    let enabled: Bool
    let calculationAnnotations: [NoteCalculationAnnotation]
}

struct NoteContentPreview: View {
    @ObservedObject var model: NotesModel
    let note: DeskNote
    let text: String
    let enabled: Bool
    var calculationAnnotations: [NoteCalculationAnnotation] = []
    @State private var calculations: [Int: NoteCalculationLine] = [:]
    @Environment(\.colorScheme) private var scheme
    private var key: NotePreviewCalculationKey {
        .init(
            text: text, rates: model.exchangeRates.snapshot?.rates ?? [:], enabled: enabled,
            calculationAnnotations: calculationAnnotations)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(NotePreviewRow.rows(text)) { row in
                switch row.content {
                case .image(let id):
                    if let attachment = note.attachments.first(where: { $0.id == id }) {
                        NoteImageView(attachment: attachment) { model.exportAttachment(attachment) }
                            .contextMenu {
                                Button(L10n.text("另存圖片…")) { model.exportAttachment(attachment) }
                                Button(L10n.text("移除圖片"), role: .destructive) {
                                    model.change(note.id) {
                                        $0.text = NoteImagePlacement.removing(id, from: $0.text)
                                        $0.attachments.removeAll { $0.id == id }
                                    }
                                }
                            }
                    } else {
                        Label(L10n.text("圖片未能載入"), systemImage: "photo.badge.exclamationmark").font(.caption)
                    }
                case .text(let index, let line):
                    HStack(alignment: .top, spacing: 8) {
                        if let checked = NoteChecklist.state(line) {
                            Button {
                                model.change(note.id) { $0.text = NoteChecklist.toggle($0.text, line: index) }
                                model.select(nil)
                            } label: {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                            }
                            .buttonStyle(.plain).foregroundStyle(checked ? NotesPalette.accent(scheme) : .secondary)
                            .accessibilityLabel(checked ? L10n.text("標示為未完成") : L10n.text("標示為完成"))
                            .accessibilityValue(checked ? L10n.text("已完成") : L10n.text("未完成"))
                            .accessibilityIdentifier("notes.checklist.\(note.id.uuidString).\(index)")
                            Text(String(line.trimmingCharacters(in: .whitespaces).dropFirst(6))).strikethrough(checked)
                        } else {
                            Text(previewText(line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let result = calculations[index] {
                            Text(result.output).font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(result.failed ? .orange : .green)
                                .textSelection(.enabled).frame(maxWidth: 112, alignment: .trailing)
                                .help(result.copyOutput)
                                .accessibilityIdentifier("notes.calculation.\(index)")
                        }
                    }
                }
            }
            if text.count > 12_000 || NotePreviewRow.rows(text).count >= 80 {
                Button(L10n.text("編輯全文…")) { model.select(note.id) }.font(.caption)
            }
        }
        .font(.system(size: 15)).frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
        .contentShape(Rectangle()).onTapGesture {
            model.select(note.id)
            model.preview = false
        }
        .task(id: key) {
            guard enabled else {
                calculations = [:]
                return
            }
            let result = await NoteCalculationWorker.shared.evaluate(
                NoteCalculationText.input(text, annotations: calculationAnnotations),
                rates: model.exchangeRates.snapshot?.rates ?? [:])
            guard !Task.isCancelled else { return }
            calculations = Dictionary(uniqueKeysWithValues: result.filter(\.failed).map { ($0.line, $0) })
        }
    }
    private func previewText(_ line: String) -> AttributedString {
        let content =
            (try? AttributedString(
                markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(line)
        return content
    }
}
