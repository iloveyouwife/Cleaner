// Adapted from YangJiiii/3105 (GPL-3.0-or-later), ThreeOneOSFive/helpers/LimitedCleanerService.swift.
// Original code copyright its respective authors; see README and LICENSE.
import Foundation
import Darwin

struct LimitedCleanerUsage: Equatable {
    let cacheBytes: Int64
    let temporaryBytes: Int64
    let removableItemCount: Int

    static let empty = LimitedCleanerUsage(
        cacheBytes: 0,
        temporaryBytes: 0,
        removableItemCount: 0
    )

    var totalBytes: Int64 {
        cacheBytes + temporaryBytes
    }
}

struct LimitedCleanerResult: Equatable {
    let before: LimitedCleanerUsage
    let after: LimitedCleanerUsage
    let removedItemCount: Int
    let failedItemCount: Int

    var freedBytes: Int64 {
        max(0, before.totalBytes - after.totalBytes)
    }
}

enum LimitedCleanerError: LocalizedError, Equatable {
    case unsafeContainerRoot
    case inaccessible(String, Int32)

    var errorDescription: String? {
        switch self {
        case .unsafeContainerRoot:
            return "无法安全打开 App 容器根目录。"
        case .inaccessible(let path, let code):
            return "缓存内部的 \(path) 不可读取（errno=\(code)）；不能将它计为 0 KB。"
        }
    }
}

enum LimitedCleanerService {
    typealias ContainerRootValidator = (URL) -> Bool

    /// This explicit allowlist is the product boundary. Do not add global `/var`
    /// paths here: this cleaner is intentionally limited to per-app disposable data.
    static let allowedRelativeDirectories = ["Library/Caches", "tmp"]

    static func scan(
        containerURL: URL,
        rootValidator: ContainerRootValidator
    ) throws -> LimitedCleanerUsage {
        try withValidatedRootDescriptor(containerURL, rootValidator: rootValidator) { rootDescriptor in
            let cache = try scanAllowedDirectory(
                components: ["Library", "Caches"],
                rootDescriptor: rootDescriptor
            )
            let temporary = try scanAllowedDirectory(
                components: ["tmp"],
                rootDescriptor: rootDescriptor
            )
            return LimitedCleanerUsage(
                cacheBytes: cache.bytes,
                temporaryBytes: temporary.bytes,
                removableItemCount: cache.itemCount + temporary.itemCount
            )
        }
    }

    static func clean(
        containerURL: URL,
        rootValidator: ContainerRootValidator
    ) throws -> LimitedCleanerResult {
        let before = try scan(containerURL: containerURL, rootValidator: rootValidator)
        var removal = RemovalSummary()

        try withValidatedRootDescriptor(containerURL, rootValidator: rootValidator) { rootDescriptor in
            for components in [["Library", "Caches"], ["tmp"]] {
                guard let directoryDescriptor = openDirectory(
                    components: components,
                    relativeTo: rootDescriptor
                ) else {
                    continue
                }
                removeDirectoryContents(directoryDescriptor, summary: &removal)
                close(directoryDescriptor)
            }
        }

        let after = try scan(containerURL: containerURL, rootValidator: rootValidator)
        return LimitedCleanerResult(
            before: before,
            after: after,
            removedItemCount: removal.removedItemCount,
            failedItemCount: removal.failedItemCount
        )
    }

    private static func withValidatedRootDescriptor<T>(
        _ rawURL: URL,
        rootValidator: ContainerRootValidator,
        operation: (Int32) throws -> T
    ) throws -> T {
        guard rawURL.isFileURL else { throw LimitedCleanerError.unsafeContainerRoot }
        let root = rawURL.standardizedFileURL
        guard root.path.hasPrefix("/"),
              root.path != "/",
              rootValidator(root) else {
            throw LimitedCleanerError.unsafeContainerRoot
        }

        let descriptor = open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw LimitedCleanerError.unsafeContainerRoot }
        defer { close(descriptor) }
        return try operation(descriptor)
    }

    private static func scanAllowedDirectory(
        components: [String],
        rootDescriptor: Int32
    ) throws -> ScanSummary {
        guard let directoryDescriptor = try openDirectoryStrict(
            components: components,
            relativeTo: rootDescriptor
        ) else {
            return .empty
        }
        defer { close(directoryDescriptor) }
        return try scanDirectory(directoryDescriptor)
    }

    private static func openDirectoryStrict(
        components: [String],
        relativeTo rootDescriptor: Int32
    ) throws -> Int32? {
        var descriptor = dup(rootDescriptor)
        guard descriptor >= 0 else {
            throw LimitedCleanerError.inaccessible("容器句柄", errno)
        }
        for component in components {
            let next = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            let openError = errno
            close(descriptor)
            guard next >= 0 else {
                if openError == ENOENT { return nil }
                throw LimitedCleanerError.inaccessible(
                    components.joined(separator: "/"), openError
                )
            }
            descriptor = next
        }
        return descriptor
    }

    private static func openDirectory(
        components: [String],
        relativeTo rootDescriptor: Int32
    ) -> Int32? {
        var currentDescriptor = dup(rootDescriptor)
        guard currentDescriptor >= 0 else { return nil }

        for component in components {
            let nextDescriptor = component.withCString {
                openat(
                    currentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            close(currentDescriptor)
            guard nextDescriptor >= 0 else { return nil }
            currentDescriptor = nextDescriptor
        }
        return currentDescriptor
    }

    private static func scanDirectory(_ directoryDescriptor: Int32) throws -> ScanSummary {
        var result = ScanSummary.empty
        try forEachEntryStrict(in: directoryDescriptor) { name, information in
            switch information.st_mode & S_IFMT {
            case S_IFREG:
                result.bytes += max(0, Int64(information.st_size))
                result.itemCount += 1
            case S_IFDIR:
                let childDescriptor = name.withCString {
                    openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard childDescriptor >= 0 else {
                    if errno == ENOENT { return }
                    throw LimitedCleanerError.inaccessible(name, errno)
                }
                defer { close(childDescriptor) }
                let nested = try scanDirectory(childDescriptor)
                result.bytes += nested.bytes
                result.itemCount += nested.itemCount
            default:
                // Symbolic links, sockets and device nodes are never followed or counted.
                break
            }
        }
        return result
    }

    private static func forEachEntryStrict(
        in directoryDescriptor: Int32,
        body: (String, stat) throws -> Void
    ) throws {
        let iterationDescriptor = dup(directoryDescriptor)
        guard iterationDescriptor >= 0 else {
            throw LimitedCleanerError.inaccessible("目录句柄", errno)
        }
        guard let directory = fdopendir(iterationDescriptor) else {
            let error = errno
            close(iterationDescriptor)
            throw LimitedCleanerError.inaccessible("目录遍历", error)
        }
        defer { closedir(directory) }

        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw LimitedCleanerError.inaccessible("readdir", errno) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }

            var information = stat()
            let status = name.withCString {
                fstatat(directoryDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
            }
            if status != 0 {
                if errno == ENOENT { continue }
                throw LimitedCleanerError.inaccessible(name, errno)
            }
            try body(name, information)
        }
    }

    private static func removeDirectoryContents(
        _ directoryDescriptor: Int32,
        summary: inout RemovalSummary
    ) {
        forEachEntry(in: directoryDescriptor) { name, information in
            switch information.st_mode & S_IFMT {
            case S_IFREG:
                let result = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
                if result == 0 {
                    summary.removedItemCount += 1
                } else if errno != ENOENT {
                    summary.failedItemCount += 1
                }
            case S_IFDIR:
                let childDescriptor = name.withCString {
                    openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard childDescriptor >= 0 else {
                    if errno != ENOENT && errno != ELOOP {
                        summary.failedItemCount += 1
                    }
                    return
                }
                removeDirectoryContents(childDescriptor, summary: &summary)
                close(childDescriptor)

                let result = name.withCString {
                    unlinkat(directoryDescriptor, $0, AT_REMOVEDIR)
                }
                if result != 0,
                   errno != ENOENT,
                   errno != ENOTEMPTY {
                    summary.failedItemCount += 1
                }
            default:
                // Preserve and never follow symbolic links or special nodes.
                break
            }
        }
    }

    private static func forEachEntry(
        in directoryDescriptor: Int32,
        body: (String, stat) -> Void
    ) {
        let iterationDescriptor = dup(directoryDescriptor)
        guard iterationDescriptor >= 0,
              let directory = fdopendir(iterationDescriptor) else {
            if iterationDescriptor >= 0 { close(iterationDescriptor) }
            return
        }
        defer { closedir(directory) }

        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }

            var information = stat()
            let status = name.withCString {
                fstatat(directoryDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else { continue }
            body(name, information)
        }
    }
}

private struct ScanSummary {
    var bytes: Int64
    var itemCount: Int

    static let empty = ScanSummary(bytes: 0, itemCount: 0)
}

private struct RemovalSummary {
    var removedItemCount = 0
    var failedItemCount = 0
}
