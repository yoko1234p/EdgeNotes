import CryptoKit
import DeskCore
import Foundation

struct NoteResource: Codable {
    let digest: String
    let bytes: Int
    func validate() throws {
        guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            bytes >= 0, bytes <= 5_000_000
        else { throw DeskError.invalid(L10n.text("附件索引無效，原有資料未有修改。")) }
    }
}

/// Version 2 stores the existing note fields plus content-addressed attachment references.
/// Portable exports remain version 1 with embedded bytes, readable without this resource directory.
struct NotesStoredDocument: Codable {
    var schemaVersion: Int
    var folders: [NoteFolder]
    var notes: [DeskNote]
    var resources: [String: NoteResource]?
}

struct CachedNoteResource {
    let data: Data
    let resource: NoteResource
    let modified: Date?
}

struct PreparedNoteResources {
    let data: Data
    let cache: [UUID: CachedNoteResource]
}

enum NoteResources {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func prepare(_ document: NotesDocument, directory: URL, cache: [UUID: CachedNoteResource]) throws
        -> PreparedNoteResources
    {
        guard document.notes.contains(where: { !$0.attachments.isEmpty }) else {
            return PreparedNoteResources(data: try JSONEncoder().encode(document), cache: [:])
        }
        let folder = directory.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard
            try FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType == .typeDirectory
        else {
            throw DeskError.invalid(L10n.text("附件資料夾不接受符號連結。"))
        }
        var updatedCache: [UUID: CachedNoteResource] = [:]
        var stored = NotesStoredDocument(
            schemaVersion: 2, folders: document.folders, notes: document.notes, resources: [:])
        for note in stored.notes.indices {
            for index in stored.notes[note].attachments.indices {
                let attachment = stored.notes[note].attachments[index]
                if let cached = cache[attachment.id], cached.data == attachment.data {
                    let path = folder.appendingPathComponent(cached.resource.digest + ".blob").path
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                        attrs[.type] as? FileAttributeType == .typeRegular,
                        (attrs[.size] as? NSNumber)?.intValue == cached.resource.bytes,
                        attrs[.modificationDate] as? Date == cached.modified
                    {
                        stored.resources?[attachment.id.uuidString] = cached.resource
                        stored.notes[note].attachments[index].data = Data()
                        updatedCache[attachment.id] = cached
                        continue
                    }
                }
                let hash = digest(attachment.data)
                let url = folder.appendingPathComponent(hash + ".blob")
                if FileManager.default.fileExists(atPath: url.path) {
                    let existing = try BoundedFile.read(url, limit: 5_000_000)
                    guard existing == attachment.data else { throw DeskError.invalid(L10n.text("附件內容與索引不符，未有覆蓋原檔。")) }
                } else {
                    try BoundedFile.write(attachment.data, to: url)
                }
                let resource = NoteResource(digest: hash, bytes: attachment.data.count)
                stored.resources?[attachment.id.uuidString] = resource
                stored.notes[note].attachments[index].data = Data()
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                updatedCache[attachment.id] = CachedNoteResource(
                    data: attachment.data, resource: resource,
                    modified: attrs[.modificationDate] as? Date)
            }
        }
        return PreparedNoteResources(data: try JSONEncoder().encode(stored), cache: updatedCache)
    }
    static func load(_ data: Data, directory: URL) throws -> NotesDocument {
        let stored = try JSONDecoder().decode(NotesStoredDocument.self, from: data)
        if stored.schemaVersion == 1 { return try NotesDocument.decode(data) }
        guard stored.schemaVersion == 2, let resources = stored.resources,
            stored.notes.count <= 5000, resources.count <= 100_000,
            resources.count == stored.notes.reduce(0, { $0 + $1.attachments.count })
        else { throw DeskError.invalid(L10n.text("附件索引版本或筆記資料無效，原檔保留。")) }
        let resourceFolder = directory.appendingPathComponent("Resources", isDirectory: true)
        guard
            try FileManager.default.attributesOfItem(atPath: resourceFolder.path)[.type] as? FileAttributeType
                == .typeDirectory
        else {
            throw DeskError.invalid(L10n.text("附件資料夾不接受符號連結，原檔保留。"))
        }
        // Validate note identities and limits before reading any referenced file.
        var document = NotesDocument()
        document.folders = stored.folders
        document.notes = stored.notes
        try document.validate()
        var total = 0
        var verifiedBlobs: [String: Data] = [:]
        for note in document.notes.indices {
            for index in document.notes[note].attachments.indices {
                let attachment = document.notes[note].attachments[index]
                guard attachment.data.isEmpty, let resource = resources[attachment.id.uuidString] else {
                    throw DeskError.invalid(L10n.text("附件索引不完整，原有筆記保留。"))
                }
                try resource.validate()
                total += resource.bytes
                guard total <= 20_000_000 else { throw DeskError.invalid(L10n.text("附件超出合共 20 MB 上限。")) }
                let url = directory.appendingPathComponent("Resources", isDirectory: true).appendingPathComponent(
                    resource.digest + ".blob")
                let bytes: Data
                if let existing = verifiedBlobs[resource.digest] {
                    bytes = existing
                } else {
                    bytes = try BoundedFile.read(url, limit: 5_000_000)
                    guard digest(bytes) == resource.digest else {
                        throw DeskError.invalid(L10n.text("附件內容未能驗證，原有筆記及附件保留。"))
                    }
                    verifiedBlobs[resource.digest] = bytes
                }
                guard bytes.count == resource.bytes else {
                    throw DeskError.invalid(L10n.text("附件內容未能驗證，原有筆記及附件保留。"))
                }
                document.notes[note].attachments[index].data = bytes
            }
        }
        try document.validate()
        return document
    }
    /// Current manifest plus the five retained snapshots own resources. Corrupt snapshots prevent cleanup.
    static func collectUnreferenced(directory: URL, current: [UUID: CachedNoteResource]) {
        struct SnapshotIndex: Decodable {
            let schemaVersion: Int
            let resources: [String: NoteResource]?
        }
        do {
            var retained = Set(current.values.map { $0.resource.digest })
            let snapshots = directory.appendingPathComponent("Snapshots", isDirectory: true)
            if FileManager.default.fileExists(atPath: snapshots.path) {
                for url in try FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)
                where url.pathExtension == "json" {
                    let index = try JSONDecoder().decode(
                        SnapshotIndex.self, from: BoundedFile.read(url, limit: 50_000_000))
                    guard index.schemaVersion == 1 || (index.schemaVersion == 2 && index.resources != nil) else {
                        return
                    }
                    for resource in index.resources?.values ?? [String: NoteResource]().values {
                        try resource.validate()
                        retained.insert(resource.digest)
                    }
                }
            }
            let folder = directory.appendingPathComponent("Resources", isDirectory: true)
            guard
                try FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType
                    == .typeDirectory
            else { return }
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where url.pathExtension == "blob" {
                let hash = url.deletingPathExtension().lastPathComponent
                guard !retained.contains(hash), hash.count == 64,
                    hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                    try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                        == .typeRegular
                else { continue }
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            // Keep resources whenever backup references cannot be verified.
        }
    }
}
