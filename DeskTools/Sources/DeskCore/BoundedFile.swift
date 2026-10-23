import Darwin
import Foundation

public enum DeskError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

public enum BoundedFile {
    public static func read(_ url: URL, limit: Int) throws -> Data {
        guard url.isFileURL, limit >= 0, limit < Int.max else { throw DeskError.invalid(L10n.text("只接受本機檔案。")) }
        // Check the descriptor actually opened; refuse symlinks/FIFOs without blocking.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw DeskError.invalid(L10n.text("無法開啟檔案；不接受符號連結。")) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_size >= 0, metadata.st_size <= limit
        else {
            throw DeskError.invalid(L10n.text("檔案類型不支援或檔案過大。"))
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw DeskError.invalid(L10n.text("檔案超出大小上限。")) }
        return data
    }

    public static func privateDirectory(_ app: String) throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent(app, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return directory
    }

    public static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
