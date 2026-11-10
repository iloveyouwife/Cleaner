import Foundation
import Darwin

enum WCPathDiscovery {
    // Bundle/Application may be on a different volume, where an unprivileged
    // app cannot create an inode probe. Names remain best-effort; a missing
    // bundle path must never hide a data container found on the Data volume.
    private static let bundleLookupCap: UInt64 = 5_000_000
    private static let bundleCacheKey = "wc.bundleRootIndex"
    private static let bundleCacheTimeKey = "wc.bundleRootIndexTime"

    static func enumerateRoots(
        forceFull: Bool = false,
        progress: ((UInt64, UInt64) -> Void)? = nil
    ) throws -> (data: [WCTarget], bundles: [String], incremental: Bool,
                 scannedInodes: UInt64, extensionCount: Int, completeBound: Bool) {
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
                (result["completeBound"] as? NSNumber)?.boolValue ?? false)
    }
}
