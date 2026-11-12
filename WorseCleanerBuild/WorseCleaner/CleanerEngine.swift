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

/// Skip only manually excluded App containers. /var and /private/var
/// refer to the same identity, including entries added by UUID.
enum WCScanExclusions {
    static func eligibleTargets(_ candidates: [WCTarget], excludedPaths: Set<String>) -> [WCTarget] {
        let excluded = Set(excludedPaths.map(WCPathDiscovery.containerIdentity))
        return candidates.filter {
            !excluded.contains(WCPathDiscovery.containerIdentity($0.path))
        }
    }
}

struct WCInspection {
    let target: WCTarget
    let usage: LimitedCleanerUsage
    let identitySource: WCIdentitySource
    let metadataErrno: Int32?
}

enum WCIdentitySource: String {
    case launchServices = "LaunchServices"
    case metadata = "元数据"
    case savedState = "保存状态"
    case preferences = "偏好文件"
    case unresolved = "未识别"
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
            return "路径必须是 App 或扩展数据容器根目录，且末尾紧跟 UUID。"
        case .noAppGroup:
            return "当前签名未提供所选 App Group 的访问权限。请检查已签名 IPA 的 entitlements 和 provisioning profile。"
        case .unavailable(let code):
            return "worse_query 未能取得权限（返回码 \(code)）。不执行扫描或删除。"
        case .inaccessible(let item, let code):
            return "\(item) 无法读取（errno=\(code)）。本次操作已停止，不能按 0 KB 处理。"
        case .noCacheDirectories:
            return "目标容器的 Library/Caches 与 tmp 都不存在，不执行删除。"
        }
    }
}

enum WCFileAccess {
    static func signedGroups() -> [String] {
        WCSignedAppGroups()
    }

    static func accessibleGroups() -> [String] {
        signedGroups().filter {
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: $0
            ) != nil
        }
    }

    static func isValidApplicationContainer(_ rawPath: String) -> Bool {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        for root in ["Application", "PluginKitPlugin"] {
            let prefix = "/var/mobile/Containers/Data/\(root)/"
            for fullPrefix in [prefix, "/private" + prefix] where path.hasPrefix(fullPrefix) {
                let uuid = String(path.dropFirst(fullPrefix.count))
                return !uuid.contains("/") && UUID(uuidString: uuid) != nil
            }
        }
        return false
    }

    private static func withLease<T>(
        for target: WCTarget,
        groupID: String,
        body: () throws -> T
    ) throws -> T {
        guard isValidApplicationContainer(target.path) else { throw WCFailure.invalidTarget }
        guard accessibleGroups().contains(groupID) else {
            throw WCFailure.noAppGroup
        }

        // 'true' deliberately skips upstream's lstat precheck: lstat can return
        // EPERM on a perfectly existing foreign container before the extension.
        // It does not create the foreign target directory.
        let handle = WCGrant.readablePath(target.path, groupID: groupID)
        guard handle > 0 else { throw WCFailure.unavailable(handle) }
        var scopedHandles: [Int64] = []
        defer {
            for token in scopedHandles.reversed() { worse_query_release(token) }
            worse_query_release(handle)
        }
        // Some containers grant their root but not the two cache locations.
        // Retry an EPERM *only* for the allowed cache directories; never
        // request a grant for Documents, private metadata, or system paths.
        for components in LimitedCleanerService.allowedDirectoryComponents {
            let cachePath = target.path + "/" + components.joined(separator: "/")
            let descriptor = open(cachePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor >= 0 {
                close(descriptor)
            } else if errno == EPERM {
                let scoped = WCGrant.readablePath(cachePath, groupID: groupID)
                if scoped > 0 { scopedHandles.append(scoped) }
            }
        }
        return try body()
    }

    private static func checkReadableDirectories(_ target: WCTarget) throws {
        let descriptor = open(target.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw WCFailure.inaccessible("App 容器根目录", errno)
        }
        defer { close(descriptor) }

        var readableCount = 0
        for components in LimitedCleanerService.allowedDirectoryComponents {
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

    static func inspect(
        _ target: WCTarget, groupID: String, knownNames: [String: String] = [:],
        knownContainers: [String: String] = [:]
    ) throws -> WCInspection {
        return try withLease(for: target, groupID: groupID) {
            try checkReadableDirectories(target)
            let identity = inspectIdentity(target, knownNames: knownNames,
                                           knownContainers: knownContainers)
            let usage = try LimitedCleanerService.scan(
                containerURL: URL(fileURLWithPath: target.path),
                rootValidator: { isValidApplicationContainer($0.path) && $0.path == target.path }
            )
            return WCInspection(target: identity.0, usage: usage,
                                identitySource: identity.1, metadataErrno: identity.2)
        }
    }

    private static func isBundleIdentifier(_ value: String) -> Bool {
        value.contains(".") && !value.contains("..") &&
            value.range(of: "^[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)+$",
                        options: .regularExpression) != nil &&
            !value.hasPrefix("group.") && !value.hasPrefix("systemgroup.")
    }

    private static func resolvedTarget(
        _ target: WCTarget, bundleID: String, hint: String = "",
        knownNames: [String: String]
    ) -> WCTarget? {
        guard isBundleIdentifier(bundleID) else { return nil }
        let localized = WCLookupApplicationName(bundleID)
        let name = WCAppNames.displayName(for: bundleID, names: knownNames)
            ?? (localized?.isEmpty == false ? localized : nil)
            ?? (hint.isEmpty ? bundleID : hint)
        return try? WCTarget(bundleID: bundleID, name: name, path: target.path)
    }

    private static func metadataPlist(_ target: WCTarget) -> (plist: [String: Any]?, code: Int32?) {
        let filename = ".com.apple.mobile_container_manager.metadata.plist"
        // Try both a fully qualified path and a descriptor-relative lookup.
        // iOS can impose different sandbox checks on a hidden root entry.
        var file = open(target.path + "/" + filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        var errorCode: Int32? = file < 0 ? errno : nil
        if file < 0 {
            let root = open(target.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if root >= 0 {
                file = filename.withCString { openat(root, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
                if file < 0 { errorCode = errno }
                close(root)
            }
        }
        guard file >= 0 else { return (nil, errorCode) }
        defer { close(file) }
        var statInfo = stat()
        guard fstat(file, &statInfo) == 0, (statInfo.st_mode & S_IFMT) == S_IFREG,
              statInfo.st_size <= 131_072 else { return (nil, nil) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 131_072 {
            let size = read(file, &buffer, min(buffer.count, 131_072 - data.count))
            if size <= 0 { break }
            data.append(contentsOf: buffer.prefix(size))
        }
        let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
        return (plist, nil)
    }

    private static func inspectIdentity(
        _ target: WCTarget, knownNames: [String: String],
        knownContainers: [String: String]
    ) -> (WCTarget, WCIdentitySource, Int32?) {
        // Highest-confidence route: CSStore2 explicitly binds the exact data
        // container UUID path to an installed app/extension Bundle ID.
        let normalized = target.path.hasPrefix("/var/")
            ? "/private" + target.path : target.path
        if let id = knownContainers[normalized],
           let resolved = resolvedTarget(target, bundleID: id, knownNames: knownNames) {
            return (resolved, .launchServices, nil)
        }
        // 3105's first route: MCMMetadataIdentifier and MCMMetadataInfo.
        let metadata = metadataPlist(target)
        if let plist = metadata.plist {
            let identifier = (plist["MCMMetadataIdentifier"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let info = plist["MCMMetadataInfo"] as? [String: Any] ?? [:]
            let hint = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String) ?? ""
            if let resolved = resolvedTarget(
                target, bundleID: identifier, hint: hint, knownNames: knownNames
            ) {
                return (resolved, .metadata, metadata.code)
            }
        }

        // 3105's second route: a saved-state name contains the hosting Bundle ID.
        let savedRoot = target.path + "/Library/Saved Application State"
        let savedEntries = (try? FileManager.default.contentsOfDirectory(atPath: savedRoot)) ?? []
        let savedCandidates = Array(Set(savedEntries.compactMap { name -> String? in
            guard name.hasSuffix(".savedState") else { return nil }
            let identifier = String(name.dropLast(".savedState".count))
            return isBundleIdentifier(identifier) ? identifier : nil
        })).sorted()
        for identifier in savedCandidates {
            if WCLookupApplicationName(identifier) != nil || savedCandidates.count == 1,
               let resolved = resolvedTarget(target, bundleID: identifier,
                                             knownNames: knownNames) {
                return (resolved, .savedState, metadata.code)
            }
        }

        // Third route from 3105: Preferences/*.plist. Only accept a candidate
        // when LaunchServices confirms its name, or it is the sole non-Apple
        // preference identifier. Never infer an identity from generic SDK files.
        let prefsRoot = target.path + "/Library/Preferences"
        let preferenceEntries = (try? FileManager.default.contentsOfDirectory(atPath: prefsRoot)) ?? []
        let preferenceCandidates = Array(Set(preferenceEntries.compactMap { name -> String? in
            guard name.hasSuffix(".plist") else { return nil }
            let identifier = String(name.dropLast(".plist".count))
            guard isBundleIdentifier(identifier), !identifier.hasPrefix("com.apple.") else { return nil }
            return identifier
        })).sorted()
        for identifier in preferenceCandidates {
            if WCLookupApplicationName(identifier) != nil || preferenceCandidates.count == 1,
               let resolved = resolvedTarget(target, bundleID: identifier,
                                             knownNames: knownNames) {
                return (resolved, .preferences, metadata.code)
            }
        }
        return (target, .unresolved, metadata.code)
    }

    static func clean(_ target: WCTarget, groupID: String) throws -> LimitedCleanerResult {
        return try withLease(for: target, groupID: groupID) {
            try checkReadableDirectories(target)
            return try LimitedCleanerService.clean(
                containerURL: URL(fileURLWithPath: target.path),
                rootValidator: { isValidApplicationContainer($0.path) && $0.path == target.path }
            )
        }
    }
}
