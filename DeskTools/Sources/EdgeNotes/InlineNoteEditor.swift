import AppKit
import DeskCore
import NotesCore
import SwiftUI

@MainActor final class NoteEditorController: ObservableObject {
    weak var editor: NSTextView?
    func apply(_ style: NoteTextStyle) {
        guard let editor, !editor.hasMarkedText(),
            let edit = NoteTextFormatting.edit(editor.string, selection: editor.selectedRange(), style: style)
        else { return }
        editor.window?.makeFirstResponder(editor)
        editor.insertText(edit.replacement, replacementRange: edit.range)
        editor.setSelectedRange(edit.selection)
    }
    func pasted(before: String, after: String, attachments: [NoteAttachment], ids: [UUID]) {
        guard let editor, !editor.hasMarkedText(), NoteAttributedContent.source(editor.attributedString()) == before
        else { return }
        let annotations = NoteCalculationText.rebased(
            NoteAttributedContent.calculationAnnotations(in: editor.attributedString()), from: before, to: after)
        editor.insertText(
            NoteAttributedContent.render(after, attachments: attachments, calculationAnnotations: annotations),
            replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        if let last = NoteImagePlacement.references(in: after).last(where: { ids.contains($0.id) }) {
            editor.setSelectedRange(
                NSRange(
                    location: min(
                        editor.string.utf16.count,
                        NoteAttributedContent.displayOffset(NSMaxRange(last.range) + 1, source: after)), length: 0))
        }
    }
}
struct InlineNoteEditor: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var controller: NoteEditorController
    var attachments: [NoteAttachment] = []
    var calculationsEnabled = true
    var rates: [String: Double] = [:]
    var calculationAnnotations: [NoteCalculationAnnotation] = []
    var contentChanged: ((String, [NoteCalculationAnnotation]) -> Void)? = nil
    var pasteImages: (([NoteClipboardImageSource], String, NSRange) -> Bool)? = nil
    var pasteFailure: ((String) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let editor = FormattingTextView(frame: .zero, textContainer: container)
        editor.retainedTextStorage = storage
        let arguments = CommandLine.arguments
        if arguments.contains("--data-directory"), let index = arguments.firstIndex(of: "--test-pasteboard"),
            arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("EdgeNotes-test-")
        {
            editor.pasteboard = NSPasteboard(name: .init(arguments[index + 1]))
        }
        editor.controller = controller
        editor.imagePaste = { [weak coordinator = context.coordinator] images, text, selection in
            coordinator?.parent.pasteImages?(images, text, selection) ?? false
        }
        editor.pasteFailure = { [weak coordinator = context.coordinator] message in
            coordinator?.parent.pasteFailure?(message)
        }
        editor.delegate = context.coordinator
        editor.textStorage?.setAttributedString(
            NoteAttributedContent.render(text, attachments: attachments, calculationAnnotations: calculationAnnotations)
        )
        editor.font = .systemFont(ofSize: 15)
        editor.backgroundColor = .clear
        editor.drawsBackground = false
        editor.isRichText = true
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = false
        editor.textContainerInset = NSSize(width: 1, height: 4)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.setAccessibilityIdentifier("notes.editor")
        editor.setAccessibilityLabel(L10n.text("筆記文字"))
        context.coordinator.refresh(editor)
        context.coordinator.calculate(editor)
        scroll.documentView = editor
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak editor] _ in
            Task { @MainActor in editor?.updateCalculationLabels() }
        }
        controller.editor = editor
        DispatchQueue.main.async { if editor.window?.isKeyWindow == true { editor.window?.makeFirstResponder(editor) } }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        controller.editor = editor
        if !editor.hasMarkedText(),
            NoteAttributedContent.source(editor.attributedString()) != text
                || NoteAttributedContent.calculationAnnotations(in: editor.attributedString()) != calculationAnnotations
        {
            let sourceSelection = NoteAttributedContent.sourceRange(
                editor.selectedRange(), in: editor.attributedString())
            editor.textStorage?.setAttributedString(
                NoteAttributedContent.render(
                    text, attachments: attachments, calculationAnnotations: calculationAnnotations))
            editor.setSelectedRange(
                NSRange(
                    location: min(
                        editor.string.utf16.count,
                        NoteAttributedContent.displayOffset(sourceSelection.location, source: text)), length: 0))
            context.coordinator.refresh(editor)
        }
        context.coordinator.calculate(editor)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineNoteEditor
        var scrollObserver: NSObjectProtocol?
        private var calculationTask: Task<Void, Never>?
        deinit {
            calculationTask?.cancel()
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }
        private var calculationSource: String?
        private var ownedAnswers: [NoteCalculationAnnotation] = []
        private var calculationRates: [String: Double] = [:]
        private var enabled = false
        init(_ parent: InlineNoteEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            guard (editor as? FormattingTextView)?.isMaterializingCalculation != true else { return }
            publish(editor)
            refresh(editor)
            calculate(editor, canWrite: editor.undoManager?.isUndoing != true && editor.undoManager?.isRedoing != true)
        }
        private func publish(_ editor: NSTextView) {
            let source = NoteAttributedContent.source(editor.attributedString())
            let annotations = NoteAttributedContent.calculationAnnotations(in: editor.attributedString())
            if let changed = parent.contentChanged { changed(source, annotations) } else { parent.text = source }
        }
        func calculate(_ editor: NSTextView, canWrite: Bool = true) {
            guard !editor.hasMarkedText(), let view = editor as? FormattingTextView else { return }
            let source = NoteAttributedContent.source(editor.attributedString())
            let annotations = NoteAttributedContent.calculationAnnotations(in: editor.attributedString())
            guard
                source != calculationSource || annotations != ownedAnswers
                    || parent.rates != calculationRates || parent.calculationsEnabled != enabled
            else { return }
            calculationSource = source
            ownedAnswers = annotations
            calculationRates = parent.rates
            enabled = parent.calculationsEnabled
            calculationTask?.cancel()
            if !enabled {
                view.invalidateCalculations()
                return
            }
            view.invalidateCalculations(preservingGutter: true)
            let rates = parent.rates
            let input = NoteCalculationText.input(source, annotations: annotations)
            calculationTask = Task { [weak self, weak view] in
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                let results = await NoteCalculationWorker.shared.evaluate(input, rates: rates)
                guard !Task.isCancelled, let self, let view, !view.hasMarkedText(),
                    NoteAttributedContent.source(view.attributedString()) == source
                else { return }
                if canWrite, view.materializeCalculations(results, source: source) {
                    calculationSource = NoteAttributedContent.source(view.attributedString())
                    ownedAnswers = NoteAttributedContent.calculationAnnotations(in: view.attributedString())
                    publish(view)
                    refresh(view)
                }
                view.applyCalculations(results, source: NoteAttributedContent.source(view.attributedString()))
            }
        }
        /// Keep Markdown source intact while rendering its inline formatting.
        /// Hidden delimiters retain their source offsets for undo and selection.
        func refresh(_ editor: NSTextView) {
            guard !editor.hasMarkedText(), let storage = editor.textStorage else { return }
            let base: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.textColor,
            ]
            editor.typingAttributes = base
            let range = NSRange(location: 0, length: storage.length)
            guard storage.length <= 200_000 else { return }
            storage.beginEditing()
            storage.addAttributes(base, range: range)
            func hide(_ range: NSRange) {
                storage.addAttributes(
                    [.font: NSFont.systemFont(ofSize: 0.1), .foregroundColor: NSColor.clear], range: range)
            }
            for (pattern, font, group, delimiters) in [
                (#"(?m)^(#{1,6} )(.+)$"#, NSFont.systemFont(ofSize: 18, weight: .semibold), 2, 0),
                (#"(\*\*|__)([^\n]+?)\1"#, NSFont.boldSystemFont(ofSize: 15), 2, 2),
                (
                    #"(?<!\*)\*([^*\n]+)\*(?!\*)"#,
                    NSFontManager.shared.convert(.systemFont(ofSize: 15), toHaveTrait: .italicFontMask), 1, 1
                ),
                (#"`([^`\n]+)`"#, NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), 1, 1),
            ] {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                regex.enumerateMatches(in: editor.string, range: range) { match, _, _ in
                    guard let match else { return }
                    storage.addAttribute(.font, value: font, range: match.range(at: group))
                    if delimiters == 0 {
                        hide(match.range(at: 1))
                    } else {
                        hide(NSRange(location: match.range.location, length: delimiters))
                        hide(NSRange(location: NSMaxRange(match.range) - delimiters, length: delimiters))
                    }
                }
            }
            storage.enumerateAttribute(
                NoteAttributedContent.calculationAttribute, in: range
            ) { value, range, _ in
                guard let expected = value as? String,
                    (storage.string as NSString).substring(with: range) == expected
                else { return }
                storage.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
                        .foregroundColor: NSColor.systemGreen,
                    ],
                    range: range)
            }
            storage.endEditing()
        }
    }
}
final class FormattingTextView: NSTextView {
    // A caller-supplied TextKit network is not retained by NSTextView.
    // Keep the root alive; it owns the layout manager and text container.
    var retainedTextStorage: NSTextStorage?
    weak var controller: NoteEditorController?
    var imagePaste: (([NoteClipboardImageSource], String, NSRange) -> Bool)?
    private(set) var calculations: [NoteCalculationLine] = [] {
        didSet {
            let lines = NoteTextLines.ranges(in: string)
            calculationPositions = calculations.compactMap {
                guard lines.indices.contains($0.line), lines[$0.line].length > 0 else { return nil }
                return (lines[$0.line], $0)
            }
            setAccessibilityHelp(calculations.map(\.output).joined(separator: "；"))
            needsLayout = true
            needsDisplay = true
            updateCalculationLabels()
        }
    }
    private var calculatedSource: String?
    private var reservedCalculationGutter: CGFloat = 0
    var calculationGutterWidth: CGFloat { reservedCalculationGutter }
    private var calculationLabels: [NoteCalculationResultField] = []
    private var calculationPositions: [(NSRange, NoteCalculationLine)] = []
    var pasteFailure: ((String) -> Void)?
    var pasteboard = NSPasteboard.general
    private(set) var isMaterializingCalculation = false
    func invalidateCalculations(preservingGutter: Bool = false) {
        calculatedSource = nil
        if !preservingGutter { reservedCalculationGutter = 0 }
        calculations = []
    }
    func applyCalculations(_ results: [NoteCalculationLine], source: String) {
        guard NoteAttributedContent.source(attributedString()) == source else { return }
        calculatedSource = source
        let errors = results.filter(\.failed)
        reservedCalculationGutter = errors.isEmpty ? 0 : errors.contains(where: \.isInline) ? 128 : 96
        calculations = results
    }
    @discardableResult func materializeCalculations(_ results: [NoteCalculationLine], source: String) -> Bool {
        guard !hasMarkedText(), NoteAttributedContent.source(attributedString()) == source else { return false }
        let annotations = NoteAttributedContent.calculationAnnotations(in: attributedString())
        let edits = NoteCalculationText.edits(in: source, annotations: annotations, results: results)
        guard !edits.isEmpty else { return false }
        let ranges = NoteAttributedContent.displayRanges(edits.map(\.range), source: source)
        let replacementRange = NSUnionRange(ranges[0], ranges[ranges.count - 1])
        let replacement = NSMutableAttributedString(
            attributedString: attributedString().attributedSubstring(from: replacementRange))
        let selected = selectedRanges.map(\.rangeValue)
        for index in edits.indices.reversed() {
            let edit = edits[index]
            let value = NSMutableAttributedString(string: edit.text, attributes: typingAttributes)
            if !edit.text.isEmpty {
                value.addAttribute(
                    NoteAttributedContent.calculationAttribute, value: edit.text,
                    range: NSRange(location: 0, length: value.length))
            }
            replacement.replaceCharacters(
                in: NSRange(location: ranges[index].location - replacementRange.location, length: ranges[index].length),
                with: value)
        }
        let proposed = NSMutableAttributedString(attributedString: attributedString())
        proposed.replaceCharacters(in: replacementRange, with: replacement)
        guard NoteAttributedContent.source(proposed).utf8.count <= 1_000_000 else { return false }
        func position(_ offset: Int) -> Int {
            var delta = 0
            for index in edits.indices {
                let range = ranges[index]
                if offset <= range.location { break }
                if offset < NSMaxRange(range) {
                    return range.location + delta + min(offset - range.location, edits[index].text.utf16.count)
                }
                delta += edits[index].text.utf16.count - range.length
            }
            return offset + delta
        }
        isMaterializingCalculation = true
        defer { isMaterializingCalculation = false }
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        insertText(replacement, replacementRange: replacementRange)
        undoManager?.setActionName(L10n.text("自動計算"))
        undoManager?.endUndoGrouping()
        setSelectedRanges(
            selected.map {
                NSValue(
                    range: NSRange(
                        location: position($0.location),
                        length: max(0, position(NSMaxRange($0)) - position($0.location))))
            }, affinity: .downstream, stillSelecting: false)
        typingAttributes.removeValue(forKey: NoteAttributedContent.calculationAttribute)
        return true
    }
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        if !isMaterializingCalculation, undoManager?.isUndoing != true, undoManager?.isRedoing != true,
            let storage = textStorage
        {
            var touched: [NSRange] = []
            storage.enumerateAttribute(
                NoteAttributedContent.calculationAttribute, in: NSRange(location: 0, length: storage.length)
            ) { value, range, _ in
                guard value != nil else { return }
                if NSIntersectionRange(range, affectedCharRange).length > 0
                    || (affectedCharRange.length == 0 && affectedCharRange.location > range.location
                        && affectedCharRange.location < NSMaxRange(range))
                {
                    touched.append(range)
                }
            }
            for range in touched { storage.removeAttribute(NoteAttributedContent.calculationAttribute, range: range) }
        }
        return true
    }
    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0 {
            let content = attributedString()
            let source = NoteAttributedContent.source(content)
            let ranges = NoteAttributedContent.displayRanges(
                NoteAttributedContent.calculationAnnotations(in: content).map(\.range), source: source)
            if let range = ranges.first(where: {
                selection.location >= $0.location && selection.location < NSMaxRange($0)
            }) {
                setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
            }
        }
        super.insertNewline(sender)
    }
    func canCopyCalculation(line: Int) -> Bool {
        !hasMarkedText() && calculatedSource == NoteAttributedContent.source(attributedString())
            && calculations.contains { $0.line == line && !$0.failed }
    }
    @discardableResult func copyCalculation(line: Int) -> Bool {
        guard canCopyCalculation(line: line), let result = calculations.first(where: { $0.line == line }) else {
            return false
        }
        pasteboard.clearContents()
        return pasteboard.setString(result.copyOutput, forType: .string)
    }
    @objc func copyCurrentCalculation(_ sender: Any?) {
        guard let line = NoteTextLines.index(atUTF16Offset: selectedRange().location, in: string),
            copyCalculation(line: line)
        else {
            NSSound.beep()
            return
        }
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copyCurrentCalculation(_:)) {
            guard let line = NoteTextLines.index(atUTF16Offset: selectedRange().location, in: string) else {
                return false
            }
            return canCopyCalculation(line: line)
        }
        if item.action == #selector(NSText.paste(_:)) {
            return isEditable && !hasMarkedText()
                && pasteboard.availableType(from: [.png, .tiff, .fileURL, .string]) != nil
        }
        return super.validateUserInterfaceItem(item)
    }
    override func copy(_ sender: Any?) {
        if pasteboard.name == NSPasteboard.general.name {
            super.copy(sender)
        } else {
            pasteboard.declareTypes([.string, .rtf], owner: nil)
            _ = writeSelection(to: pasteboard, types: [.string, .rtf])
            let range = selectedRange()
            if range.length > 0 {
                pasteboard.setString((string as NSString).substring(with: range), forType: .string)
            }
        }
    }
    override func paste(_ sender: Any?) {
        do {
            guard let images = try NotesClipboardImages.read(pasteboard) else {
                pasteAsPlainText(sender)
                return
            }
            guard !hasMarkedText() else {
                pasteFailure?(L10n.text("請先完成目前輸入，再貼圖片。"))
                return
            }
            let content = attributedString()
            if imagePaste?(
                images, NoteAttributedContent.source(content),
                NoteAttributedContent.sourceRange(selectedRange(), in: content)) != true
            {
                NSSound.beep()
            }
        } catch { pasteFailure?(error.localizedDescription) }
    }
    override func layout() {
        super.layout()
        let width = max(80, bounds.width - 4 - calculationGutterWidth)
        if textContainer?.containerSize.width != width {
            textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateCalculationLabels()
    }
    func updateCalculationLabels() {
        guard let manager = layoutManager, let container = textContainer else { return }
        let width = max(80, bounds.width - 4 - calculationGutterWidth)
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        let visible = visibleRect
        let glyphs = manager.glyphRange(
            forBoundingRect: visible.offsetBy(
                dx: -textContainerOrigin.x,
                dy: -textContainerOrigin.y), in: container)
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var used = 0
        for (range, result) in calculationPositions {
            guard result.failed else { continue }
            let offset = result.isInline ? NSMaxRange(range) - 1 : range.location
            if offset < characters.location { continue }
            if offset > NSMaxRange(characters) || used >= 64 { break }
            guard offset < (textStorage?.length ?? 0) else { continue }
            let glyph = manager.glyphRange(
                forCharacterRange: NSRange(location: offset, length: 1), actualCharacterRange: nil)
            let frame = manager.boundingRect(forGlyphRange: glyph, in: container)
            let rect = NSRect(
                x: result.isInline ? frame.maxX + textContainerOrigin.x + 3 : bounds.width - 92,
                y: frame.minY + textContainerOrigin.y, width: result.isInline ? 124 : 88, height: 22)
            guard rect.intersects(visible) else { continue }
            if used == calculationLabels.count {
                let label = NoteCalculationResultField(labelWithString: "")
                label.editor = self
                label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
                label.alignment = .right
                label.lineBreakMode = .byTruncatingTail
                label.isSelectable = true
                addSubview(label)
                calculationLabels.append(label)
            }
            let label = calculationLabels[used]
            label.frame = rect
            label.stringValue = result.isInline ? "（" + result.output + "）" : result.output
            label.alignment = result.isInline ? .left : .right
            label.line = result.line
            label.toolTip = result.failed ? result.output : result.copyOutput + L10n.text("\n⌘⇧C 複製目前行答案")
            label.textColor = result.failed ? .systemOrange : .systemGreen
            label.setAccessibilityIdentifier("notes.editor.calculation." + String(result.line))
            label.isHidden = false
            used += 1
        }
        for label in calculationLabels.dropFirst(used) { label.isHidden = true }
        setAccessibilityChildren(used == 0 ? nil : Array(calculationLabels.prefix(used)))
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), !hasMarkedText() else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c" where event.modifierFlags.contains(.shift): copyCurrentCalculation(nil)
        case "z":
            if event.modifierFlags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
        case "b": controller?.apply(.bold)
        case "i": controller?.apply(.italic)
        case "t": controller?.apply(.task)
        case "l": controller?.apply(.bullet)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

private final class NoteCalculationResultField: NSTextField {
    weak var editor: FormattingTextView?
    var line = 0
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let copy = NSMenuItem(title: L10n.text("複製計算結果"), action: #selector(copyResult(_:)), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = editor?.canCopyCalculation(line: line) == true
        menu.addItem(copy)
        return menu
    }
    @objc private func copyResult(_ sender: Any?) { editor?.copyCalculation(line: line) }
}

actor NoteCalculationWorker {
    static let shared = NoteCalculationWorker()
    func evaluate(_ text: String, rates: [String: Double]) -> [NoteCalculationLine] {
        NoteCalculations.evaluate(text, rates: rates)
    }
}
