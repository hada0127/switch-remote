import Foundation
import Darwin

public enum AgentFiles {
    public enum CopyError: Error, Equatable {
        case destinationIsDirectory
        case failed(String)
    }

    /// Copies `source` to `destination` without ever deleting first: the bytes go to a temporary
    /// file beside the destination, which then atomically replaces it. A failure leaves any
    /// existing destination untouched. Directories are refused. Copying a file onto itself is a no-op.
    @discardableResult
    public static func copyReplacing(_ source: URL, to destination: URL) throws -> URL {
        let target = destination.standardizedFileURL
        var info = stat()
        if stat(target.path, &info) == 0 {
            if info.st_mode & S_IFMT == S_IFDIR { throw CopyError.destinationIsDirectory }
            var sourceInfo = stat()
            if stat(source.path, &sourceInfo) == 0, sourceInfo.st_dev == info.st_dev, sourceInfo.st_ino == info.st_ino { return target }
        }
        let directory = target.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw CopyError.failed(error.localizedDescription)
        }
        guard rename(temporary.path, target.path) == 0 else {
            let message = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw CopyError.failed(message)
        }
        return target
    }
}
