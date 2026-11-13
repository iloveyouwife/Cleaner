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
    /// Treat /var and /private/var as the same container in every UI and
    /// backend exclusion operation. Never excludes Cleaner automatically.
    static func normalizedPaths(_ paths: Set<String>) -> Set<String> {
        Set(paths.map(WCPathDiscovery.containerIdentity))
    }

    private static func filter(
        _ candidates: [WCTarget], excludedPaths: Set<String>, includeExcluded: Bool
    ) -> [WCTarget] {
        let excluded = normalizedPaths(excludedPaths)
        return candidates.filter {
            excluded.contains(WCPathDiscovery.containerIdentity($0.path)) == includeExcluded
        }
    }

    static func eligibleTargets(_ candidates: [WCTarget], excludedPaths: Set<String>) -> [WCTarget] {
        filter(candidates, excludedPaths: excludedPaths, includeExcluded: false)
    }

    static func excludedTargets(_ candidates: [WCTarget], excludedPaths: Set<String>) -> [WCTarget] {
        filter(candidates, excludedPaths: excludedPaths, includeExcluded: true)
    }

    /// Keep saved exclusions manageable even when discovery cannot see an App.
    /// Reuse the existing management rows; never infer that an unknown App was uninstalled.
    static func managementTargets(_ candidates: [WCTarget], excludedPaths: Set<String>) -> [WCTarget] {
        let visible = excludedTargets(candidates, excludedPaths: excludedPaths)
        let known = Set(visible.map { WCPathDiscovery.containerIdentity($0.path) })
        let missing = normalizedPaths(excludedPaths).subtracting(known).sorted().compactMap { path in
            try? WCTarget(bundleID: URL(fileURLWithPath: path).lastPathComponent,
                          name: "未发现的 App 容器", path: path)
        }
        return visible + missing
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
    case catalog = "容器目录"
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
    case unresolvedManualContainer

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            return "路径必须是 App 或扩展数据容器根目录，且末尾紧跟 UUID。"
        case .noAppGroup:
            return "当前签名未提供所选 App Group 的访问权限。请检查已签名 IPA 的 entitlements 和 provisioning profile。"
        case .unavailable(let code):
            switch code {
            case -9:
                return "专用 App Group 中有无法核实来源的旧暂存备份（Caches.wq-preserved）。数据已保留，停止授权，请勿直接删除备份。"
            case -10:
                return "专用 App Group 缓存入口与暂存记录不符。现有目录及备份均已保留，停止授权。"
            case -11:
                return "专用 App Group 缓存暂存恢复未完成。原数据及事务记录已保留，下次授权前会重新核验。"
            case -12:
                return "专用 App Group 的暂存路径或事务记录无法安全验证，未继续授权。请查看访问诊断。"
            default: break
            }
            return "worse_query 未能取得权限（返回码 \(code)）。不执行扫描或删除。"
        case .inaccessible(let item, let code):
            return "\(item) 无法读取（errno=\(code)）。本次操作已停止，不能按 0 KB 处理。"
        case .unresolvedManualContainer:
            return "无法根据 UUID 唯一确认 App 或扩展容器，请填写来源明确的完整路径。"
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
        let name = WCAppNames.displayName(for: bundleID, names: knownNames)
            ?? WCLookupApplicationName(bundleID)
            ?? (hint.isEmpty ? nil : hint)
            ?? bundleID
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
        let normalized = target.path.hasPrefix("/var/")
            ? "/private" + target.path : target.path
        let catalogID = knownContainers[normalized]
        let originalID = isBundleIdentifier(target.bundleID) ? target.bundleID : nil
        func unknown() -> WCTarget {
            let uuid = URL(fileURLWithPath: target.path).lastPathComponent
            let title = target.path.contains("/PluginKitPlugin/") ? "扩展容器 " : "App 容器 "
            return (try? WCTarget(bundleID: "容器 " + String(uuid.prefix(8)),
                                  name: title + String(uuid.prefix(8)), path: target.path)) ?? target
        }

        // An exact LS path mapping and the original MCM/validated identity are
        // ownership evidence. A conflict must not silently relabel a container.
        if let catalogID, isBundleIdentifier(catalogID) {
            guard let id = WCIdentityEvidence.agreedIdentifier([catalogID, originalID]),
                  let resolved = resolvedTarget(target, bundleID: id, knownNames: knownNames)
            else { return (unknown(), .unresolved, nil) }
            return (resolved, .launchServices, nil)
        }

        let metadata = metadataPlist(target)
        let identifier = (metadata.plist?["MCMMetadataIdentifier"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let metadataID = isBundleIdentifier(identifier) ? identifier : nil
        if originalID != nil || metadataID != nil {
            guard let id = WCIdentityEvidence.agreedIdentifier([originalID, metadataID]) else {
                return (unknown(), .unresolved, metadata.code)
            }
            let info = metadata.plist?["MCMMetadataInfo"] as? [String: Any] ?? [:]
            let hint = metadataID == id
                ? ((info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? "")
                : (target.name == target.bundleID ? "" : target.name)
            if let resolved = resolvedTarget(target, bundleID: id, hint: hint, knownNames: knownNames) {
                return (resolved, metadataID != nil ? .metadata : .catalog, metadata.code)
            }
        }

        // A filename or the existence of another installed App is not proof
        // of ownership. Keep these fallbacks only when LS confirms the exact
        // data-container path for the candidate, including /var aliases.
        for (directory, suffix, source) in [
            ("Library/Saved Application State", ".savedState", WCIdentitySource.savedState),
            ("Library/Preferences", ".plist", WCIdentitySource.preferences)
        ] {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: target.path + "/" + directory)) ?? []
            let candidates = Set(entries.compactMap { name -> String? in
                guard name.hasSuffix(suffix) else { return nil }
                let id = String(name.dropLast(suffix.count))
                return isBundleIdentifier(id) ? id : nil
            })
            if let id = WCIdentityEvidence.pathConfirmedIdentifier(
                candidates, containerPath: target.path,
                lookup: { WCLookupApplicationDataContainer($0) }
            ), let resolved = resolvedTarget(target, bundleID: id, knownNames: knownNames) {
                return (resolved, source, metadata.code)
            }
        }
        return (unknown(), .unresolved, metadata.code)
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
