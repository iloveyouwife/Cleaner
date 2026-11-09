import Foundation
import Darwin

struct WCTarget: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let path: String

    var id: String { path }

    init(bundleID: String, name: String, path: String) throws {
        guard WCFileAccess.isValidApplicationContainer(path) else {
            throw WCFailure.invalidTarget
        }
        self.bundleID = bundleID
        self.name = name
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

enum WCFailure: LocalizedError {
    case invalidTarget
    case noAppGroup
    case unavailable(Int64)
    case inaccessible(String, Int32)
    case noCacheDirectories

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            return "路径必须是 /var/mobile/Containers/Data/Application/ 后面紧跟 UUID 的 App 容器根目录。"
        case .noAppGroup:
            return "签名不包含有效的 App Group。请配置 provisioning profile 和 group.com.example.worsecleaner 授权。"
        case .unavailable(let code):
            return "worse_query 未能取得权限（返回码 \(code)）。不执行扫描或删除。"
        case .inaccessible(let item, let code):
            return "\(item) 无法读取（errno=\(code)）；本次操作已停止，不能按 0 KB 处理。"
        case .noCacheDirectories:
            return "目标容器的 Library/Caches 与 tmp 都不存在；不执行删除。"
        }
    }
}

enum WCFileAccess {
    // Must match WorseCleaner.entitlements and the App Group in the signing profile.
    static let groupID = "group.com.example.worsecleaner"

    static func isValidApplicationContainer(_ rawPath: String) -> Bool {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        let prefix = "/var/mobile/Containers/Data/Application/"
        let privatePrefix = "/private" + prefix
        let uuid: String
        if path.hasPrefix(prefix) {
            uuid = String(path.dropFirst(prefix.count))
        } else if path.hasPrefix(privatePrefix) {
            uuid = String(path.dropFirst(privatePrefix.count))
        } else {
            return false
        }
        return !uuid.contains("/") && UUID(uuidString: uuid) != nil
    }

    private static func withLease<T>(for target: WCTarget, body: () throws -> T) throws -> T {
        guard isValidApplicationContainer(target.path) else { throw WCFailure.invalidTarget }
        guard FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) != nil else {
            throw WCFailure.noAppGroup
        }

        // 'true' deliberately skips upstream's lstat precheck: lstat can return
        // EPERM on a perfectly existing foreign container before the extension.
        // It does not create the foreign target directory.
        let handle = worse_query(target.path, groupID, false, true)
        guard handle > 0 else { throw WCFailure.unavailable(handle) }
        defer { worse_query_release(handle) }
        return try body()
    }

    private static func checkReadableDirectories(_ target: WCTarget) throws {
        let descriptor = open(target.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw WCFailure.inaccessible("App 容器根目录", errno)
        }
        defer { close(descriptor) }

        var readableCount = 0
        for components in [["Library", "Caches"], ["tmp"]] {
            var fd = dup(descriptor)
            guard fd >= 0 else {
                throw WCFailure.inaccessible("容器句柄", errno)
            }
            var exists = true
            for component in components {
                let next = component.withCString {
                    openat(fd, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                let openError = errno
                close(fd)
                if next < 0 {
                    if openError == ENOENT {
                        exists = false
                        break
                    }
                    throw WCFailure.inaccessible(components.joined(separator: "/"), openError)
                }
                fd = next
            }
            if !exists { continue }
            defer { close(fd) }

            // 'open' can succeed while getdirentries/readdir is still denied.
            let readFD = dup(fd)
            guard readFD >= 0 else {
                throw WCFailure.inaccessible(components.joined(separator: "/"), errno)
            }
            guard let dir = fdopendir(readFD) else {
                let err = errno
                close(readFD)
                throw WCFailure.inaccessible(components.joined(separator: "/"), err)
            }
            errno = 0
            _ = readdir(dir)
            let readError = errno
            closedir(dir)
            guard readError == 0 else {
                throw WCFailure.inaccessible(components.joined(separator: "/"), readError)
            }
            readableCount += 1
        }
        if readableCount == 0 { throw WCFailure.noCacheDirectories }
    }

    static func scan(_ target: WCTarget) throws -> LimitedCleanerUsage {
        try withLease(for: target) {
            try checkReadableDirectories(target)
            return try LimitedCleanerService.scan(
                containerURL: URL(fileURLWithPath: target.path),
                rootValidator: { isValidApplicationContainer($0.path) && $0.path == target.path }
            )
        }
    }

    static func clean(_ target: WCTarget) throws -> LimitedCleanerResult {
        try withLease(for: target) {
            try checkReadableDirectories(target)
            return try LimitedCleanerService.clean(
                containerURL: URL(fileURLWithPath: target.path),
                rootValidator: { isValidApplicationContainer($0.path) && $0.path == target.path }
            )
        }
    }
}
