import AppKit
import Combine
import DeskCore
import DeskUI
import LocalWorkflowKit
import NotesCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class NotesModel: ObservableObject {
    @Published var document = NotesDocument()
    @Published var selected: UUID?
    @Published var folder: UUID?
    @Published var draft = ""
    @Published var draftCalculationAnnotations: [NoteCalculationAnnotation] = []
    @Published var search = ""
    @Published var searchVisible = false
    @Published var browsingFolders = true
    @Published var settingsVisible = false
    @Published var trash = false
    @Published var preview = false
    @Published var message = L10n.text("本機儲存 · 不會上傳筆記")
    @Published var failure = false
    @Published var incomingTexts: [IncomingNoteText] = []
    @Published var incomingError = ""
    @Published var customTemplates: [NoteTemplate] = []
    @Published var templatesVisible = false
    @Published var templateError = ""
    var incomingStorageError: String?
    let workflowDirectory: URL
    var tagIndex: [UUID: (Date, [String])] = [:]
    var exportedDestinations: NoteDestinations?
    var incoming: IncomingNoteText? { incomingTexts.first }
    @Published private(set) var pastedImageID: UUID?
    @Published private(set) var pastingNoteIDs: Set<UUID> = []
    var imagePastesFinished: ((Bool) -> Void)?
    private var imageTasks: [UUID: Task<Void, Never>] = [:]
    private var imagePasteBatchFailed = false
    let exchangeRates: NotesExchangeRateStore
    private var rateUpdates: AnyCancellable?
    var repository: NotesRepository?
    private var saveWork: DispatchWorkItem?
    var selectedNote: DeskNote? { document.notes.first { $0.id == selected } }
    var activeFolders: [NoteFolder] { document.folders.filter { $0.trashed != true } }
    var deletedFolders: [NoteFolder] { document.folders.filter { $0.trashed == true } }
    var showingFolders: Bool { browsingFolders && !trash && search.isEmpty }
    var activeNoteCount: Int { document.notes.filter { !$0.trashed }.count }
    var trashCount: Int { document.notes.filter(\.trashed).count }
    func noteCount(in folder: UUID) -> Int {
        document.notes.filter { $0.folderID == folder && !$0.trashed }.count
    }
    @discardableResult func openFolder(_ id: UUID?) -> Bool {
        guard id == nil || activeFolders.contains(where: { $0.id == id }), flush() else { return false }
        folder = id
        selected = nil
        draft = ""
        draftCalculationAnnotations = []
        preview = false
        trash = false
        search = ""
        searchVisible = false
        browsingFolders = false
        return true
    }
    @discardableResult func showFolders() -> Bool {
        guard flush() else { return false }
        folder = nil
        selected = nil
        draft = ""
        draftCalculationAnnotations = []
        preview = false
        trash = false
        search = ""
        searchVisible = false
        browsingFolders = true
        return true
    }
    @discardableResult func toggleTrash() -> Bool {
        guard flush() else { return false }
        let opening = !trash
        folder = nil
        selected = nil
        draft = ""
        draftCalculationAnnotations = []
        preview = false
        search = ""
        searchVisible = false
        trash = opening
        browsingFolders = !opening
        return true
    }
    @discardableResult func toggleSearch() -> Bool {
        guard flush() else { return false }
        searchVisible.toggle()
        if !searchVisible { search = "" }
        return true
    }
    var visible: [DeskNote] {
        document.notes.filter {
            $0.trashed == trash && (folder == nil || $0.folderID == folder)
                && (search.isEmpty
                    || (search.hasPrefix("#") && !search.contains(" ")
                        ? tags(for: $0).contains(String(search.dropFirst()).lowercased())
                        : $0.text.localizedCaseInsensitiveContains(search)))
        }
        .sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            let a = $0.order ?? -$0.createdAt.timeIntervalSince1970
            let b = $1.order ?? -$1.createdAt.timeIntervalSince1970
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }
    }
    init(directory: URL? = nil) {
        workflowDirectory = directory?.appendingPathComponent("Workflows", isDirectory: true) ?? WorkflowFiles.directory
        exchangeRates = NotesExchangeRateStore(directory: directory ?? (try? BoundedFile.privateDirectory("EdgeNotes")))
        do {
            let repository = try NotesRepository(directory: directory ?? BoundedFile.privateDirectory("EdgeNotes"))
            self.repository = repository
            document = repository.document
            loadNoteWorkflows()
        } catch {
            // Do not replace a damaged store with an empty document.
            failure = true
            message = L10n.text("無法讀取筆記；原檔保留：") + error.localizedDescription
        }
        rateUpdates = exchangeRates.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    @discardableResult func flush() -> Bool {
        saveWork?.cancel()
        saveWork = nil
        guard let id = selected, let index = document.notes.firstIndex(where: { $0.id == id }),
            document.notes[index].text != draft
                || (document.notes[index].calculationAnnotations ?? []) != draftCalculationAnnotations
        else { return true }
        var next = document
        next.notes[index].text = draft
        let annotations = NoteCalculationText.validAnnotations(draftCalculationAnnotations, in: draft)
        next.notes[index].calculationAnnotations = annotations.isEmpty ? nil : annotations
        next.notes[index].updatedAt = Date()
        guard commit(next) else { return false }
        draftCalculationAnnotations = annotations
        return true
    }
    func edited() {
        saveWork?.cancel()
        guard selectedNote?.text != draft || (selectedNote?.calculationAnnotations ?? []) != draftCalculationAnnotations
        else { return }
        message = L10n.text("正在儲存…")
        failure = false
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    @discardableResult func commit(_ next: NotesDocument) -> Bool {
        do {
            guard let repository else { throw DeskError.invalid(L10n.text("儲存空間未載入，請先修復原檔。")) }
            try repository.commit(next)
            document = repository.document
            failure = false
            message = L10n.text("已儲存於此 Mac · ") + Date().formatted(date: .omitted, time: .shortened)
            refreshNoteWorkflows()
            return true
        } catch {
            failure = true
            message = error.localizedDescription
            return false
        }
    }
    func select(_ id: UUID?) {
        guard flush() else { return }
        selected = id
        reloadDraft()
        preview = false
    }
    private func reloadDraft() {
        draft = selectedNote?.text ?? ""
        draftCalculationAnnotations = NoteCalculationText.validAnnotations(
            selectedNote?.calculationAnnotations ?? [], in: draft)
    }
    func newNote(_ text: String = "") {
        guard flush() else { return }
        var next = document
        let destination: UUID
        if let target = activeFolders.first(where: { $0.id == folder }) ?? activeFolders.first {
            destination = target.id
        } else {
            let inbox = NoteFolder(name: L10n.text("收件匣"))
            next.folders.append(inbox)
            destination = inbox.id
        }
        let note = DeskNote(folderID: destination, text: text)
        var inserted = note
        inserted.order = (document.notes.compactMap(\.order).min() ?? -Date().timeIntervalSince1970) - 1
        next.notes.append(inserted)
        if commit(next) {
            if browsingFolders || !activeFolders.contains(where: { $0.id == folder }) { folder = destination }
            browsingFolders = false
            trash = false
            search = ""
            searchVisible = false
            selected = note.id
            draft = text
            draftCalculationAnnotations = []
            preview = false
        }
    }
    func change(_ transform: (inout DeskNote) -> Void) {
        guard flush(), let index = document.notes.firstIndex(where: { $0.id == selected }) else { return }
        var next = document
        transform(&next.notes[index])
        next.notes[index].calculationAnnotations = NoteCalculationText.rebased(
            document.notes[index].calculationAnnotations ?? [], from: document.notes[index].text,
            to: next.notes[index].text)
        next.notes[index].updatedAt = Date()
        if commit(next) { reloadDraft() }
    }
    func change(_ id: UUID, _ transform: (inout DeskNote) -> Void) {
        guard flush(), let index = document.notes.firstIndex(where: { $0.id == id }) else { return }
        var next = document
        transform(&next.notes[index])
        next.notes[index].calculationAnnotations = NoteCalculationText.rebased(
            document.notes[index].calculationAnnotations ?? [], from: document.notes[index].text,
            to: next.notes[index].text)
        next.notes[index].updatedAt = Date()
        if commit(next), selected == id { reloadDraft() }
    }
    func updateDraft(_ id: UUID, _ text: String, calculationAnnotations: [NoteCalculationAnnotation]? = nil) {
        if selected != id { select(id) }
        guard selected == id else { return }
        draftCalculationAnnotations =
            calculationAnnotations.map { NoteCalculationText.validAnnotations($0, in: text) }
            ?? NoteCalculationText.rebased(draftCalculationAnnotations, from: draft, to: text)
        draft = text
        edited()
    }
    func move(_ source: UUID, before target: UUID) {
        guard source != target, flush() else { return }
        var ids = visible.map(\.id)
        guard let sourceIndex = ids.firstIndex(of: source), ids.contains(target) else { return }
        ids.remove(at: sourceIndex)
        ids.insert(source, at: ids.firstIndex(of: target)!)
        var next = document
        for (order, id) in ids.enumerated() {
            guard let index = next.notes.firstIndex(where: { $0.id == id }) else { continue }
            next.notes[index].order = Double(order)
        }
        _ = commit(next)
    }
    func addFolder(_ name: String) {
        guard flush(), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var next = document
        let folder = NoteFolder(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        next.folders.append(folder)
        if commit(next) {
            _ = openFolder(folder.id)
        }
    }
    func renameFolder(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, flush(), let index = document.folders.firstIndex(where: { $0.id == id }) else { return }
        var next = document
        next.folders[index].name = name
        _ = commit(next)
    }
    @discardableResult func deleteFolder(_ id: UUID) -> Bool {
        guard flush(), let index = document.folders.firstIndex(where: { $0.id == id && $0.trashed != true }) else {
            return false
        }
        var next = document
        next.folders[index].trashed = true
        for index in next.notes.indices where next.notes[index].folderID == id && !next.notes[index].trashed {
            next.notes[index].trashed = true
            next.notes[index].trashedWithFolder = true
        }
        guard commit(next) else { return false }
        if folder == id { _ = showFolders() }
        return true
    }
    func restoreFolder(_ id: UUID) {
        guard flush(), let index = document.folders.firstIndex(where: { $0.id == id && $0.trashed == true }) else {
            return
        }
        var next = document
        next.folders[index].trashed = nil
        for index in next.notes.indices
        where next.notes[index].folderID == id && next.notes[index].trashedWithFolder == true {
            next.notes[index].trashed = false
            next.notes[index].trashedWithFolder = nil
        }
        _ = commit(next)
    }
    func toggleNoteTrash(_ id: UUID) {
        guard flush(), let index = document.notes.firstIndex(where: { $0.id == id }) else { return }
        var next = document
        if next.notes[index].trashed,
            deletedFolders.contains(where: { $0.id == next.notes[index].folderID })
        {
            if let target = activeFolders.first {
                next.notes[index].folderID = target.id
            } else {
                let inbox = NoteFolder(name: L10n.text("收件匣"))
                next.folders.append(inbox)
                next.notes[index].folderID = inbox.id
            }
        }
        next.notes[index].trashed.toggle()
        next.notes[index].trashedWithFolder = nil
        if commit(next) { select(nil) }
    }
    func emptyTrash() {
        guard pastingNoteIDs.isEmpty, flush(), let repository else { return }
        do {
            try repository.emptyTrash()
            document = repository.document
            selected = nil
            draft = ""
            draftCalculationAnnotations = []
            failure = false
            message = L10n.text("回收筒已清空；已匯出的備份不受影響。")
        } catch {
            document = repository.document
            failure = true
            message = L10n.text("清空未能全部完成：") + error.localizedDescription
        }
    }
    func exportBackup() {
        guard flush(), let repository else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "EdgeNotes-" + Date().formatted(.iso8601.year().month().day()) + ".edgenotes"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try BoundedFile.write(repository.exportData(), to: url)
                message = L10n.text("已匯出完整備份（含附件）。")
            } catch {
                failure = true
                message = error.localizedDescription
            }
        }
    }
    func importBackup() {
        guard flush(), let repository else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                if url.standardizedFileURL.deletingLastPathComponent()
                    == repository.directory.appendingPathComponent("Snapshots").standardizedFileURL
                {
                    try repository.importSnapshot(at: url)
                } else {
                    try repository.importData(BoundedFile.read(url, limit: 50_000_000))
                }
                document = repository.document
                message = L10n.text("已合併備份，保留現有筆記。")
                failure = false
                if selected != nil { reloadDraft() }
            } catch {
                failure = true
                message = error.localizedDescription
            }
        }
    }
    func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try BoundedFile.read(url, limit: 5_000_000)
                change { $0.attachments.append(NoteAttachment(name: url.lastPathComponent, data: data)) }
            } catch {
                failure = true
                message = error.localizedDescription
            }
        }
    }
    @discardableResult func pasteImageSources(
        _ sources: [NoteClipboardImageSource], into id: UUID, text: String,
        selection: NSRange? = nil, committed: ((String, String, [NoteAttachment], [UUID]) -> Void)? = nil
    )
        -> Bool
    {
        guard selected == id, !sources.isEmpty, !pastingNoteIDs.contains(id), pastingNoteIDs.count < 2 else {
            pasteFailed(L10n.text("圖片正在處理，完成後可再貼上。"))
            return false
        }
        updateDraft(id, text)
        if pastingNoteIDs.isEmpty { imagePasteBatchFailed = false }
        pastingNoteIDs.insert(id)
        message = L10n.text("正在處理圖片…")
        imageTasks[id] = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try NotesClipboardImages.prepare(sources) }
            }.value
            guard let self else { return }
            var success = false
            switch result {
            case .success(let attachments):
                let before = selected == id ? draft : document.notes.first { $0.id == id }?.text ?? text
                success = addPastedImages(
                    attachments, into: id,
                    selection: selection.map {
                        NoteImagePlacement.rebased($0, from: text, to: before)
                    })
                if success, selected == id, let note = selectedNote {
                    committed?(before, note.text, note.attachments, attachments.map(\.id))
                }
            case .failure(let error): pasteFailed(error.localizedDescription)
            }
            imageTasks[id] = nil
            pastingNoteIDs.remove(id)
            imagePasteBatchFailed = imagePasteBatchFailed || !success
            if pastingNoteIDs.isEmpty { imagePastesFinished?(!imagePasteBatchFailed && !failure) }
        }
        return true
    }
    @discardableResult func addPastedImages(_ attachments: [NoteAttachment], into id: UUID, selection: NSRange? = nil)
        -> Bool
    {
        guard !attachments.isEmpty,
            let index = document.notes.firstIndex(where: { $0.id == id && !$0.trashed })
        else { return false }
        if selected == id {
            saveWork?.cancel()
            saveWork = nil
        }
        var next = document
        if selected == id {
            next.notes[index].text = draft
            next.notes[index].calculationAnnotations = draftCalculationAnnotations
        }
        let beforeText = next.notes[index].text
        let beforeAnnotations = next.notes[index].calculationAnnotations ?? []
        if let selection {
            if next.notes[index].usesInlineImages != true {
                let existing = next.notes[index].attachments.filter {
                    UTType(filenameExtension: ($0.name as NSString).pathExtension)?.conforms(to: .image) == true
                }
                if !existing.isEmpty {
                    next.notes[index].text +=
                        "\n" + existing.map { NoteImagePlacement.marker($0.id) }.joined(separator: "\n")
                }
            }
            next.notes[index].text = NoteImagePlacement.inserted(
                attachments.map(\.id), into: next.notes[index].text, at: selection)
            next.notes[index].usesInlineImages = true
        }
        next.notes[index].updatedAt = Date()
        next.notes[index].calculationAnnotations = NoteCalculationText.rebased(
            beforeAnnotations, from: beforeText, to: next.notes[index].text)
        next.notes[index].attachments.append(contentsOf: attachments)
        guard commit(next) else { return false }
        if selected == id {
            reloadDraft()
            pastedImageID = attachments.last?.id
        }
        return true
    }
    func pasteFailed(_ text: String) {
        failure = true
        message = text
    }
    func exportAttachment(_ attachment: NoteAttachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (attachment.name as NSString).lastPathComponent
        if panel.runModal() == .OK, let url = panel.url {
            do { try BoundedFile.write(attachment.data, to: url) } catch {
                failure = true
                message = error.localizedDescription
            }
        }
    }
    func createFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        guard text.utf8.count <= 1_000_000 else {
            failure = true
            message = L10n.text("剪貼簿文字最多 1 MB。")
            return
        }
        newNote(text)
    }
    func importTextFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url { receive(url) }
    }
}
