import Foundation
import Darwin

// A cheap identity stamp: file metadata only; it does not read or parse
// LaunchServices on every cache rescan.
struct WCLaunchServicesStamp: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

enum WCContainerPresence {
    case present
    case missing
    case unknown
}

enum WCPathDiscovery {
    // Compare equivalent /var and /private/var paths without changing the
    // actual path used for permission checks or cleanup.
    static func containerIdentity(_ path: String) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return normalized.hasPrefix("/private/var/")
            ? String(normalized.dropFirst("/private".count)) : normalized
    }

    /// Deduplicate all sources by canonical /var and /private/var identity.
    static func uniqueContainers(_ candidates: [WCTarget]) -> [WCTarget] {
        var seen = Set<String>()
        return candidates.filter { seen.insert(containerIdentity($0.path)).inserted }
    }

    static func containerPresence(_ path: String) -> WCContainerPresence {
        var details = stat()
        if lstat(path, &details) == 0 {
            return (details.st_mode & S_IFMT) == S_IFDIR ? .present : .missing
        }
        let code = errno
        return code == ENOENT || code == ENOTDIR ? .missing : .unknown
    }

    // A partial catalog cannot remove known items, and a stale MCM result
    // cannot reintroduce a container known to be absent on disk.
    static func mergeContainerCandidates(
        existing: [WCTarget], candidates: [WCTarget],
        presence: (String) -> WCContainerPresence
    ) -> (apps: [WCTarget], changed: Bool) {
        var observed = [String: WCContainerPresence]()
        func keep(_ app: WCTarget) -> Bool {
            if app.bundleID == "manual" { return true }
            let key = containerIdentity(app.path)
            let result: WCContainerPresence
            if let prior = observed[key] {
                result = prior
            } else {
                result = presence(app.path)
                observed[key] = result
            }
            return result != .missing
        }
        var seen = Set<String>()
        var merged = [WCTarget]()
        for app in existing where keep(app) {
            if seen.insert(containerIdentity(app.path)).inserted { merged.append(app) }
        }
        for app in candidates where keep(app) {
            if seen.insert(containerIdentity(app.path)).inserted { merged.append(app) }
        }
        let original = Set(existing.map { containerIdentity($0.path) })
        return (merged, seen != original || merged.count != existing.count)
    }

    static func stampIsCurrent(
        _ previous: WCLaunchServicesStamp?, _ current: WCLaunchServicesStamp?
    ) -> Bool {
        guard let previous, let current else { return false }
        return previous == current
    }
    static func launchServicesStamp(storePath: String?, groupID: String) -> WCLaunchServicesStamp? {
        guard let storePath else { return nil }
        var details = stat()
        if lstat(storePath, &details) != 0 {
            // A valid sandbox grant may allow metadata on an otherwise hidden file.
            let lease = WCGrant.readablePath(storePath, groupID: groupID)
            guard lease > 0 else { return nil }
            defer { worse_query_release(lease) }
            guard lstat(storePath, &details) == 0 else { return nil }
        }
        guard (details.st_mode & S_IFMT) == S_IFREG,
              details.st_size >= 4096, details.st_size <= 64 * 1024 * 1024 else { return nil }
        return WCLaunchServicesStamp(
            device: UInt64(details.st_dev), inode: UInt64(details.st_ino),
            size: details.st_size,
            modifiedSeconds: Int64(details.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(details.st_mtimespec.tv_nsec),
            changedSeconds: Int64(details.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(details.st_ctimespec.tv_nsec)
        )
    }

    // Best-effort change probe. A partial MCM result can never make a known
    // container disappear: only ENOENT / ENOTDIR proves removal. When the
    // database stamp changed, read it once to discover new UUID paths.
    static func quickRecheckApps(
        existing: [WCTarget], groupID: String, storePath: String?,
        previousStamp: WCLaunchServicesStamp?
    ) -> (apps: [WCTarget], changed: Bool, storePath: String?) {
        let currentStamp = launchServicesStamp(storePath: storePath, groupID: groupID)
        let storeChanged = !stampIsCurrent(previousStamp, currentStamp)
        var error: NSString?
        let raw = WCEnumerateApplicationContainers(&error)
        let mcm = raw.compactMap { item -> WCTarget? in
            guard let bundleID = item["bundleID"], let path = item["path"] else { return nil }
            return try? WCTarget(bundleID: bundleID, name: item["name"] ?? bundleID, path: path)
        }
        // Unknown stamp invalidates reuse without triggering an expensive
        // LaunchServices inode search when no readable database exists.
        let updatedIndex = storeChanged && currentStamp != nil
            ? quickLaunchServicesRoots(groupID: groupID, knownPaths: Set(mcm.map(\.path)))
            : nil
        let merged = mergeContainerCandidates(
            existing: existing, candidates: (updatedIndex?.data ?? []) + mcm,
            presence: containerPresence
        )
        return (merged.apps, storeChanged || merged.changed, updatedIndex?.launchServicesStore)
    }
    // Bundle/Application may be on a different volume, where an unprivileged
    // app cannot create an inode probe. Names remain best-effort; a missing
    // bundle path must never hide a data container found on the Data volume.
    private static let bundleLookupCap: UInt64 = 5_000_000
    private static let bundleCacheKey = "wc.bundleRootIndex"
    private static let bundleCacheTimeKey = "wc.bundleRootIndexTime"

    // WQFiles v0.8: the LaunchServices index records installed Application and
    // PluginKitPlugin data-container UUIDs. Prefer those verified paths over a
    // full-volume inode walk; retain enumerateRoots() as an explicit fallback.
    static func quickLaunchServicesRoots(
        groupID: String, knownPaths: Set<String>
    ) -> (data: [WCTarget], launchServicesStore: String, diagnostics: String)? {
        guard !groupID.isEmpty, let store = WCFindLaunchServicesStoreQuick(),
              let snapshot = WCLaunchServices.load(
                storePath: store, groupID: groupID, knownPaths: knownPaths,
                allowUnmatched: true
              ) else { return nil }

        var targets: [WCTarget] = []
        var removed = 0
        for (path, bundleID) in snapshot.containers.sorted(by: { $0.key < $1.key }) {
            var details = stat()
            if lstat(path, &details) != 0 {
                // LaunchServices also retains entries from uninstalled apps.
                // EPERM is not proof of absence on a sandboxed device.
                if errno == ENOENT || errno == ENOTDIR { removed += 1; continue }
            } else if (details.st_mode & S_IFMT) != S_IFDIR {
                removed += 1
                continue
            }
            guard WCFileAccess.isValidApplicationContainer(path) else { continue }
            let name = WCAppNames.displayName(for: bundleID, names: snapshot.names) ?? bundleID
            if let target = try? WCTarget(bundleID: bundleID, name: name, path: path) {
                targets.append(target)
            }
        }
        let appCount = targets.filter {
            $0.path.contains("/Containers/Data/Application/")
        }.count
        // At least two real app records are needed to trust this shortcut.
        // Otherwise proceed with the original complete discovery mechanism.
        guard appCount >= 2 else { return nil }
        // A device may already have hundreds of previously verified inode
        // containers absent from the current LS database. Keep those entries
        // in the list, without performing an expensive new full-volume walk.
        let cached = WCReadCachedDataContainers()
        var known = Set(targets.map { containerIdentity($0.path) })
        var reused = 0
        for (type, prefix) in [("apps", "App 容器 "), ("extensions", "扩展容器 ")] {
            for raw in cached?[type] ?? [] {
                let path = raw.hasPrefix("/var/") ? "/private" + raw : raw
                let key = containerIdentity(path)
                guard !known.contains(key), WCFileAccess.isValidApplicationContainer(path) else {
                    continue
                }
                let uuid = URL(fileURLWithPath: path).lastPathComponent
                let bundleID = snapshot.containers[path] ?? ("容器 " + String(uuid.prefix(8)))
                let name = snapshot.containers[path] != nil
                    ? (WCAppNames.displayName(for: bundleID, names: snapshot.names) ?? bundleID)
                    : prefix + String(uuid.prefix(8))
                if let target = try? WCTarget(bundleID: bundleID, name: name, path: path) {
                    targets.append(target)
                    known.insert(key)
                    reused += 1
                }
            }
        }
        return (targets, store,
                "\(snapshot.diagnostics) 已排除 \(removed) 条无效容器记录，沿用已验证 inode 索引 \(reused) 项。")
    }

    static func enumerateRoots(
        forceFull: Bool = false,
        progress: ((UInt64, UInt64) -> Void)? = nil
    ) throws -> (data: [WCTarget], bundles: [String], incremental: Bool,
                 scannedInodes: UInt64, extensionCount: Int, completeBound: Bool,
                 launchServicesStore: String?) {
        guard let result = WCDiscoverDataContainers(forceFull, progress) else {
            throw WCFailure.inaccessible("文件系统 inode 范围", errno)
        }
        let appPaths = result["apps"] as? [String] ?? []
        let extensionPaths = result["extensions"] as? [String] ?? []
        let extensionSet = Set(extensionPaths)
        let targets: [WCTarget] = (appPaths + extensionPaths).compactMap { path in
            guard WCFileAccess.isValidApplicationContainer(path) else { return nil }
            let uuid = URL(fileURLWithPath: path).lastPathComponent
            let title = extensionSet.contains(path) ? "扩展容器 " : "App 容器 "
            return try? WCTarget(
                bundleID: "容器 " + String(uuid.prefix(8)),
                name: title + String(uuid.prefix(8)),
                path: path
            )
        }

        let defaults = UserDefaults.standard
        let previous = defaults.stringArray(forKey: bundleCacheKey) ?? []
        let age = Date().timeIntervalSince1970 - defaults.double(forKey: bundleCacheTimeKey)
        let bundleRoots: [String]
        if !forceFull, !previous.isEmpty, age >= 0, age < 24 * 3600 {
            bundleRoots = previous
        } else {
            // The Data-volume pass is done; make this second, optional lookup
            // visible instead of leaving the UI apparently stuck at 100%.
            progress?(0, 0)
            let prefix = "/private/var/containers/Bundle/Application/"
            let found = pathleak_multiple(
                ["/private/var/containers/Bundle/Application"], bundleLookupCap
            ) ?? []
            bundleRoots = found.filter { path in
                guard path.hasPrefix(prefix) else { return false }
                let uuid = String(path.dropFirst(prefix.count))
                return !uuid.contains("/") && UUID(uuidString: uuid) != nil
            }
            defaults.set(bundleRoots, forKey: bundleCacheKey)
            defaults.set(Date().timeIntervalSince1970, forKey: bundleCacheTimeKey)
        }

        return (targets, bundleRoots,
                (result["incremental"] as? NSNumber)?.boolValue ?? false,
                (result["scanned"] as? NSNumber)?.uint64Value ?? 0,
                extensionPaths.count,
                (result["completeBound"] as? NSNumber)?.boolValue ?? false,
                (result["lsStore"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}
