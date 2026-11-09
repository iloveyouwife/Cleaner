import Foundation
import Darwin

enum WCPathDiscovery {
    // The source project calls this slow and non-exhaustive. Never describe
    // a capped inode walk as a complete installed-app inventory.
    static let maximumInodes: UInt64 = 5_000_000

    static func enumerateRoots() throws -> (data: [WCTarget], bundles: [String], capped: Bool) {
        let baseline = FileManager.default.temporaryDirectory
            .appendingPathComponent(".wc-inode-\(UUID().uuidString)")
        try Data([0]).write(to: baseline)
        defer { try? FileManager.default.removeItem(at: baseline) }
        var information = stat()
        guard stat(baseline.path, &information) == 0 else {
            throw WCFailure.inaccessible("临时 inode 基准", errno)
        }
        let baselineInode = UInt64(information.st_ino)
        let cap = min(baselineInode, maximumInodes)
        let bundleRoot = "/private/var/containers/Bundle/Application/"
        let roots = pathleak_multiple([
            "/private/var/mobile/Containers/Data/Application",
            "/private/var/containers/Bundle/Application"
        ], cap) ?? []
        let targets = roots.compactMap { path -> WCTarget? in
            guard WCFileAccess.isValidApplicationContainer(path) else { return nil }
            let uuid = URL(fileURLWithPath: path).lastPathComponent
            return try? WCTarget(
                bundleID: "容器 " + String(uuid.prefix(8)),
                name: "App 容器 " + String(uuid.prefix(8)),
                path: path
            )
        }
        let bundles = roots.filter { path in
            guard path.hasPrefix(bundleRoot) else { return false }
            let suffix = String(path.dropFirst(bundleRoot.count))
            return !suffix.contains("/") && UUID(uuidString: suffix) != nil
        }
        return (targets, bundles, baselineInode > cap)
    }
}
