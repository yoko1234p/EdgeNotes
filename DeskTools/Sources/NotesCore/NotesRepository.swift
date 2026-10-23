import DeskCore
import Foundation
import LocalWorkflowKit

public struct NoteCollectionSource: Codable, Equatable {
    public var requestID: UUID
    public var capturedAt: Date
    public var source: DraftSource?
    public init(requestID: UUID, capturedAt: Date, source: DraftSource?) {
        self.requestID = requestID
        self.capturedAt = capturedAt
        self.source = source
    }
}

public struct NoteFolder: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var trashed: Bool?
    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

public struct NoteAttachment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var data: Data
    public init(name: String, data: Data) {
        id = UUID()
        self.name = name
        self.data = data
    }
}

public struct DeskNote: Identifiable, Codable, Equatable {
    public var id: UUID
    public var folderID: UUID
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date
    public var pinned: Bool
    public var trashed: Bool
    public var attachments: [NoteAttachment]
    // Optional fields preserve compatibility with 0.1 stores and backups.
    public var color: String?
    public var folded: Bool?
    public var order: Double?
    public var trashedWithFolder: Bool?
    public var usesInlineImages: Bool?
    public var calculationAnnotations: [NoteCalculationAnnotation]?
    public var favorite: Bool?
    public var collectionSources: [NoteCollectionSource]?
    public init(id: UUID = UUID(), folderID: UUID, text: String = "") {
        self.id = id
        self.folderID = folderID
        self.text = text
        createdAt = Date()
        updatedAt = createdAt
        pinned = false
        trashed = false
        attachments = []
        color = nil
        folded = nil
        order = nil
    }
    public var title: String {
        NoteImagePlacement.blocks(text).compactMap { block -> String? in
            if case .text(let value) = block { return value }
            return nil
        }.joined().split(whereSeparator: \.isNewline).first.map { String($0.prefix(80)) } ?? L10n.text("新筆記")
    }
}

public struct NotesDocument: Codable, Equatable {
    public var schemaVersion: Int
    public var folders: [NoteFolder]
    public var notes: [DeskNote]
    public init() {
        schemaVersion = 1
        folders = [NoteFolder(name: L10n.text("收件匣"))]
        notes = []
    }
    public func validate() throws {
        let folderIDs = Set(folders.map(\.id))
        guard schemaVersion == 1, !folders.isEmpty, folders.count <= 100,
            folderIDs.count == folders.count, notes.count <= 5000,
            Set(notes.map(\.id)).count == notes.count, notes.filter({ $0.favorite == true }).count <= 100,
            folders.allSatisfy({
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.utf8.count <= 256
            })
        else {
            throw DeskError.invalid(L10n.text("筆記檔案版本、資料夾或識別碼不正確。"))
        }
        var attachments = Set<UUID>()
        let deletedFolders = Set(folders.filter { $0.trashed == true }.map(\.id))
        var total = 0
        for note in notes {
            guard (note.collectionSources?.count ?? 0) <= 100 else {
                throw DeskError.invalid(L10n.text("每張筆記最多保留 100 個來源紀錄。"))
            }
            for source in note.collectionSources ?? [] {
                guard source.capturedAt.timeIntervalSince1970.isFinite else {
                    throw DeskError.invalid(L10n.text("筆記來源日期無效。"))
                }
                try source.source?.validate()
            }
            guard folderIDs.contains(note.folderID), note.text.utf8.count <= 1_000_000,
                !deletedFolders.contains(note.folderID) || note.trashed,
                note.trashedWithFolder != true || (note.trashed && deletedFolders.contains(note.folderID)),
                note.attachments.count <= 20, note.updatedAt.timeIntervalSince1970.isFinite,
                note.createdAt.timeIntervalSince1970.isFinite,
                note.order?.isFinite != false,
                note.color == nil || ["default", "yellow", "green", "blue", "pink"].contains(note.color!)
            else { throw DeskError.invalid(L10n.text("筆記資料不完整或超出上限。")) }
            for attachment in note.attachments {
                total += attachment.data.count
                guard attachments.insert(attachment.id).inserted, attachment.data.count <= 5_000_000,
                    attachment.name.utf8.count <= 256, total <= 20_000_000
                else {
                    throw DeskError.invalid(L10n.text("附件超出上限（每個 5 MB，合共 20 MB）。"))
                }
            }
        }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 50_000_000 else { throw DeskError.invalid(L10n.text("備份最多 50 MB。")) }
        let document = try JSONDecoder().decode(Self.self, from: data)
        try document.validate()
        return document
    }
}

/// Commits only after validation and atomic write succeed. Never opens another app's store.
public final class NotesRepository {
    public let directory: URL
    public private(set) var document: NotesDocument
    private let file: URL
    private var resourceCache: [UUID: CachedNoteResource] = [:]
    private var commitsSinceResourceCleanup = 0
    public init(directory: URL) throws {
        self.directory = directory
        file = directory.appendingPathComponent("notes.json")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: file.path) {
            document = try NoteResources.load(BoundedFile.read(file, limit: 50_000_000), directory: directory)
        } else {
            document = NotesDocument()
        }
    }
    public func commit(_ next: NotesDocument) throws {
        guard next != document || !FileManager.default.fileExists(atPath: file.path) else { return }
        try next.validate()
        let prepared = try NoteResources.prepare(next, directory: directory, cache: resourceCache)
        let data = prepared.data
        guard data.count <= 50_000_000 else { throw DeskError.invalid(L10n.text("筆記資料超出 50 MB。")) }
        if FileManager.default.fileExists(atPath: file.path) {
            let snapshots = directory.appendingPathComponent("Snapshots", isDirectory: true)
            try FileManager.default.createDirectory(
                at: snapshots, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let previous = try BoundedFile.read(file, limit: 50_000_000)
            let name = String(format: "%.3f", Date().timeIntervalSince1970) + "-" + UUID().uuidString + ".json"
            try BoundedFile.write(previous, to: snapshots.appendingPathComponent(name))
            let old = try FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
            for url in old.dropFirst(5) { try? FileManager.default.removeItem(at: url) }
        }
        try BoundedFile.write(data, to: file)
        document = next
        let resourcesChanged = Set(resourceCache.keys) != Set(prepared.cache.keys)
        resourceCache = prepared.cache
        commitsSinceResourceCleanup += 1
        if resourcesChanged || commitsSinceResourceCleanup >= 5 {
            NoteResources.collectUnreferenced(directory: directory, current: resourceCache)
            commitsSinceResourceCleanup = 0
        }
    }
    public func exportData() throws -> Data {
        try document.validate()
        return try JSONEncoder().encode(document)
    }
    /// Removes trash from this store and its retained internal snapshots, never external exports.
    public func emptyTrash() throws {
        let noteIDs = Set(document.notes.filter(\.trashed).map(\.id))
        let folderIDs = Set(document.folders.filter { $0.trashed == true }.map(\.id))
        guard !noteIDs.isEmpty || !folderIDs.isEmpty else { return }
        func removingDeleted(_ original: NotesDocument) -> NotesDocument {
            var next = original
            next.notes.removeAll { noteIDs.contains($0.id) || folderIDs.contains($0.folderID) }
            next.folders.removeAll { folderIDs.contains($0.id) }
            if next.folders.isEmpty { next.folders.append(NoteFolder(name: L10n.text("收件匣"))) }
            return next
        }
        let snapshots = directory.appendingPathComponent("Snapshots", isDirectory: true)
        if FileManager.default.fileExists(atPath: snapshots.path) {
            for url in try FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
                let original = try NoteResources.load(BoundedFile.read(url, limit: 50_000_000), directory: directory)
                let next = removingDeleted(original)
                try next.validate()
            }
        }
        // Verify every snapshot first, so unreadable history cannot be silently discarded.
        let next = removingDeleted(document)
        try commit(next)
        // commit() retained the old current document as a new snapshot; sanitize that too.
        if FileManager.default.fileExists(atPath: snapshots.path) {
            for url in try FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
                let original = try NoteResources.load(BoundedFile.read(url, limit: 50_000_000), directory: directory)
                let next = removingDeleted(original)
                if next != original {
                    try BoundedFile.write(NoteResources.prepare(next, directory: directory, cache: [:]).data, to: url)
                }
            }
        }
        NoteResources.collectUnreferenced(directory: directory, current: resourceCache)
    }
    public func importSnapshot(at url: URL) throws {
        let snapshots = directory.appendingPathComponent("Snapshots", isDirectory: true).standardizedFileURL
        guard url.standardizedFileURL.deletingLastPathComponent() == snapshots,
            url.resolvingSymlinksInPath().deletingLastPathComponent() == snapshots.resolvingSymlinksInPath(),
            url.pathExtension == "json"
        else { throw DeskError.invalid(L10n.text("只接受此筆記庫的內部快照。")) }
        let restored = try NoteResources.load(BoundedFile.read(url, limit: 50_000_000), directory: directory)
        try importData(JSONEncoder().encode(restored))
    }
    /// Merge import preserves existing notes; conflicting IDs with changed contents get new IDs.
    public func importData(_ data: Data) throws {
        let imported = try NotesDocument.decode(data)
        var next = document
        var mapping: [UUID: UUID] = [:]
        for folder in imported.folders {
            if let existing = next.folders.first(where: {
                $0.name == folder.name && ($0.trashed == true) == (folder.trashed == true)
            }) {
                mapping[folder.id] = existing.id
            } else {
                var fresh = folder
                fresh.id = UUID()
                next.folders.append(fresh)
                mapping[folder.id] = fresh.id
            }
        }
        for var note in imported.notes {
            note.folderID = mapping[note.folderID]!
            if let existing = next.notes.first(where: { $0.id == note.id }) {
                if existing == note { continue }
                // A repeated restore must not create the same conflict copy again.
                let alreadyRestored = next.notes.contains { saved in
                    guard saved.attachments.count == note.attachments.count else { return false }
                    var comparable = note
                    comparable.id = saved.id
                    for index in comparable.attachments.indices {
                        comparable.text = NoteImagePlacement.replacingIDs(
                            in: comparable.text, with: [comparable.attachments[index].id: saved.attachments[index].id])
                        comparable.attachments[index].id = saved.attachments[index].id
                    }
                    return comparable == saved
                }
                if alreadyRestored { continue }
                note.id = UUID()
            }
            let used = Set(next.notes.flatMap(\.attachments).map(\.id))
            for index in note.attachments.indices where used.contains(note.attachments[index].id) {
                let old = note.attachments[index].id
                let new = UUID()
                note.text = NoteImagePlacement.replacingIDs(in: note.text, with: [old: new])
                note.attachments[index].id = new
            }
            next.notes.append(note)
        }
        try commit(next)
    }
}
