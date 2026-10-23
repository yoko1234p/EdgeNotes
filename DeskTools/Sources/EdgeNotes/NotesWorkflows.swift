import DeskCore
import Foundation
import LocalWorkflowKit
import NotesCore

extension NotesModel {
    var templates: [NoteTemplate] { NoteTemplate.builtIns + customTemplates }
    var favoriteNotes: [DeskNote] {
        document.notes.filter { !$0.trashed && $0.favorite == true }.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    func tags(for note: DeskNote) -> [String] {
        if let cached = tagIndex[note.id], cached.0 == note.updatedAt { return cached.1 }
        let tags = NoteTags.parse(note.text)
        tagIndex[note.id] = (note.updatedAt, tags)
        return tags
    }
    func filterTag(_ tag: String) {
        if flush() {
            search = "#" + tag
            searchVisible = true
        }
    }
    func loadNoteWorkflows() {
        guard let root = repository?.directory else { return }
        do {
            let file = root.appendingPathComponent("templates.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let decoded = try JSONDecoder().decode(
                    [NoteTemplate].self, from: BoundedFile.read(file, limit: 4_200_000))
                guard decoded.count <= 32, Set(decoded.map(\.id)).count == decoded.count else {
                    throw DeskError.invalid(L10n.text("範本清單無效，原檔保留。"))
                }
                for item in decoded { try item.validate() }
                customTemplates = decoded
            }
        } catch {
            templateError = error.localizedDescription
            message = templateError
            failure = true
        }
        do {
            let pending = root.appendingPathComponent("pending-collections.json")
            if FileManager.default.fileExists(atPath: pending.path) {
                let values = try JSONDecoder().decode(
                    [IncomingNoteText].self, from: BoundedFile.read(pending, limit: 9_000_000))
                guard values.count <= 20, values.reduce(0, { $0 + $1.text.utf8.count }) <= 8_000_000 else {
                    throw DeskError.invalid(L10n.text("待收藏內容超過上限。"))
                }
                for value in values { try value.validate() }
                incomingTexts = values.filter { !hasCollected($0.id) }
            }
        } catch {
            incomingStorageError = error.localizedDescription
            incomingError = L10n.text("待收藏檔案無法載入，原檔保留：") + error.localizedDescription
            message = incomingError
            failure = true
        }
        refreshNoteWorkflows()
    }
    func refreshNoteWorkflows() {
        let current = Set(document.notes.map(\.id))
        tagIndex = tagIndex.filter { current.contains($0.key) }
        do {
            let folders = Dictionary(uniqueKeysWithValues: activeFolders.map { ($0.id, $0.name) })
            let notes = favoriteNotes.compactMap { note -> NoteDestination? in
                guard let folderName = folders[note.folderID] else { return nil }
                return NoteDestination(id: note.id, folderID: note.folderID, title: note.title, folderName: folderName)
            }
            let catalogue = NoteDestinations(notes: notes)
            if exportedDestinations != catalogue {
                try WorkflowFiles.publish(catalogue, in: workflowDirectory)
                exportedDestinations = catalogue
            }
        } catch {
            message = L10n.text("筆記已儲存；常用目的地未能更新：") + error.localizedDescription
            failure = true
        }
    }
    func toggleFavorite(_ note: DeskNote) {
        guard note.favorite == true || favoriteNotes.count < 100 else {
            message = L10n.text("最多收藏 100 張目的筆記。")
            failure = true
            return
        }
        change(note.id) { $0.favorite = $0.favorite != true }
    }
    func saveTemplate(name: String, text: String, replacing id: UUID? = nil) {
        guard templateError.isEmpty, let root = repository?.directory else {
            message = L10n.text("範本設定未能載入；原檔保留。")
            failure = true
            return
        }
        do {
            let value = NoteTemplate(
                id: id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), text: text)
            try value.validate()
            var next = customTemplates
            if let index = next.firstIndex(where: { $0.id == id }) { next[index] = value } else { next.append(value) }
            guard next.count <= 32 else { throw DeskError.invalid(L10n.text("最多儲存 32 個自訂範本。")) }
            try WorkflowFiles.write(
                JSONEncoder().encode(next), to: root.appendingPathComponent("templates.json"), limit: 4_200_000)
            customTemplates = next
        } catch {
            message = error.localizedDescription
            failure = true
        }
    }
    func deleteTemplate(_ id: UUID) {
        guard templateError.isEmpty, let root = repository?.directory else { return }
        do {
            let next = customTemplates.filter { $0.id != id }
            try WorkflowFiles.write(
                JSONEncoder().encode(next), to: root.appendingPathComponent("templates.json"), limit: 4_200_000)
            customTemplates = next
        } catch {
            message = error.localizedDescription
            failure = true
        }
    }
    func hasCollected(_ id: UUID) -> Bool {
        document.notes.contains { ($0.collectionSources ?? []).contains { $0.requestID == id } }
    }
    func persistIncoming(_ values: [IncomingNoteText]) throws {
        if let incomingStorageError { throw DeskError.invalid(L10n.text("待收藏檔案無法載入，原檔保留：") + incomingStorageError) }
        guard let root = repository?.directory else { throw DeskError.invalid(L10n.text("筆記庫未載入，收到的內容未有刪除。")) }
        try WorkflowFiles.write(
            JSONEncoder().encode(values), to: root.appendingPathComponent("pending-collections.json"), limit: 9_000_000)
    }
    func deliverFavoriteIfPossible() {
        guard let incoming, let id = incoming.targetNoteID else { return }
        guard let note = favoriteNotes.first(where: { $0.id == id }) else {
            incomingError = L10n.text("常用目的筆記已取消收藏或刪除，請重新選擇。")
            return
        }
        _ = saveIncoming(incoming.id, folderID: note.folderID, noteID: note.id, navigate: false)
    }
}
