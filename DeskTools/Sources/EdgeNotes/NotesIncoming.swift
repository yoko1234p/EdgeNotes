import DeskCore
import Foundation
import LocalWorkflowKit
import NotesCore

struct IncomingNoteText: Identifiable, Codable {
    let id: UUID
    let text: String
    var source: DraftSource?
    var capturedAt: Date
    var targetNoteID: UUID?
    init(
        text: String, id: UUID = UUID(), source: DraftSource? = nil, capturedAt: Date = Date(),
        targetNoteID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.source = source
        self.capturedAt = capturedAt
        self.targetNoteID = targetNoteID
    }
    func validate() throws {
        try WorkflowDraft(
            kind: .note, text: text, source: source, targetNoteID: targetNoteID, id: id, createdAt: capturedAt
        ).validate()
    }
}

extension NotesModel {
    func receive(_ url: URL) {
        do {
            if let incomingStorageError { throw DeskError.invalid(L10n.text("待收藏檔案無法載入，原檔保留：") + incomingStorageError) }
            let value: IncomingNoteText
            if url.pathExtension.lowercased() == "edgedraft" {
                let draft = try WorkflowFiles.readDraft(url, in: workflowDirectory)
                guard draft.kind == .note else { throw DeskError.invalid(L10n.text("這不是筆記收藏。")) }
                value = IncomingNoteText(
                    text: draft.text, id: draft.id, source: draft.source, capturedAt: draft.createdAt,
                    targetNoteID: draft.targetNoteID)
            } else {
                guard ["edgetext", "txt", "md"].contains(url.pathExtension.lowercased()),
                    let text = String(data: try BoundedFile.read(url, limit: 1_000_000), encoding: .utf8)
                else { throw DeskError.invalid(L10n.text("只接受 UTF-8 文字或本機收藏檔（最多 1 MB）。")) }
                value = IncomingNoteText(text: text)
            }
            try value.validate()
            guard !hasCollected(value.id), !incomingTexts.contains(where: { $0.id == value.id }) else { return }
            let text = value.text
            guard !text.isEmpty else { throw DeskError.invalid(L10n.text("收到的文字是空白的。")) }
            guard incomingTexts.count < 20,
                incomingTexts.reduce(text.utf8.count, { $0 + $1.text.utf8.count }) <= 8_000_000
            else { throw DeskError.invalid(L10n.text("等候匯入的文字已滿，請先處理現有內容，再重新傳送。")) }
            if incomingTexts.isEmpty { incomingError = "" }
            let next = incomingTexts + [value]
            try persistIncoming(next)
            incomingTexts = next
            deliverFavoriteIfPossible()
        } catch { failIncoming(error.localizedDescription) }
    }

    func notesForImport(in folderID: UUID?) -> [DeskNote] {
        guard activeFolders.contains(where: { $0.id == folderID }) else { return [] }
        return document.notes.filter { $0.folderID == folderID && !$0.trashed }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            let a = $0.order ?? -$0.createdAt.timeIntervalSince1970
            let b = $1.order ?? -$1.createdAt.timeIntervalSince1970
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }
    }

    func cancelIncoming() {
        do {
            let next = Array(incomingTexts.dropFirst())
            try persistIncoming(next)
            incomingTexts = next
            incomingError = ""
            Task { @MainActor [weak self] in self?.deliverFavoriteIfPossible() }
        } catch { failIncoming(error.localizedDescription) }
    }

    @discardableResult
    func saveIncoming(_ requestID: UUID, folderID: UUID?, noteID: UUID?, navigate: Bool = true) -> Bool {
        guard let incoming, incoming.id == requestID else {
            failIncoming(L10n.text("待匯入內容已變更，請重新確認。"))
            return false
        }
        if hasCollected(incoming.id) {
            cancelIncoming()
            return true
        }
        guard flush() else {
            incomingError = L10n.text("目前筆記未能儲存：") + message
            return false
        }
        var next = document
        let destination: UUID
        if let folderID, activeFolders.contains(where: { $0.id == folderID }) {
            destination = folderID
        } else if folderID == nil, activeFolders.isEmpty, noteID == nil {
            let inbox = NoteFolder(name: L10n.text("收件匣"))
            next.folders.append(inbox)
            destination = inbox.id
        } else {
            failIncoming(L10n.text("所選資料夾已不存在或已刪除，請重新選擇。"))
            return false
        }

        let saved: DeskNote
        if let noteID {
            guard
                let index = next.notes.firstIndex(where: {
                    $0.id == noteID && $0.folderID == destination && !$0.trashed
                })
            else {
                failIncoming(L10n.text("所選筆記已移動或已刪除，請重新選擇。"))
                return false
            }
            let before = next.notes[index].text
            let separator = before.isEmpty || before.hasSuffix("\n\n") ? "" : before.hasSuffix("\n") ? "\n" : "\n\n"
            guard before.utf8.count + separator.utf8.count + incoming.text.utf8.count <= 1_000_000 else {
                failIncoming(L10n.text("加入後會超過每張筆記 1 MB 的上限；請改為新增筆記。"))
                return false
            }
            next.notes[index].text = before + separator + incoming.text
            next.notes[index].updatedAt = Date()
            next.notes[index].folded = false
            var sources = next.notes[index].collectionSources ?? []
            sources.append(
                NoteCollectionSource(requestID: incoming.id, capturedAt: incoming.capturedAt, source: incoming.source))
            next.notes[index].collectionSources = Array(sources.suffix(100))
            saved = next.notes[index]
        } else {
            var note = DeskNote(folderID: destination, text: incoming.text)
            note.order = (document.notes.compactMap(\.order).min() ?? -Date().timeIntervalSince1970) - 1
            note.collectionSources = [
                NoteCollectionSource(requestID: incoming.id, capturedAt: incoming.capturedAt, source: incoming.source)
            ]
            next.notes.append(note)
            saved = note
        }
        guard commit(next) else {
            incomingError = L10n.text("未能儲存，收到的文字仍然保留：") + message
            return false
        }
        // Update the draft before navigation can flush it over an appended note.
        if navigate || selected == saved.id {
            draft = saved.text
            draftCalculationAnnotations = NoteCalculationText.validAnnotations(
                saved.calculationAnnotations ?? [], in: draft)
        }
        if navigate {
            folder = destination
            selected = saved.id
            browsingFolders = false
            trash = false
            search = ""
            searchVisible = false
            preview = false
        }
        cancelIncoming()
        return true
    }

    private func failIncoming(_ text: String) {
        incomingError = text
        failure = true
        message = text
    }
}
