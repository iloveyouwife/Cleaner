import Foundation
import Darwin

enum WCPathDiscovery {
    // The source project calls this slow and non-exhaustive. Never describe
    // a capped inode walk as a complete installed-app inventory.
    static let maximumInodes: UInt64 = 5_000_000

    static func enumerateRoots() throws -> ([WCTarget], Bool) {
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
        let roots = pathleak("/private/var/mobile/Containers/Data/Application", cap) ?? []
        let targets = roots.compactMap { path -> WCTarget? in
            guard WCFileAccess.isValidApplicationContainer(path) else { return nil }
            let uuid = URL(fileURLWithPath: path).lastPathComponent
            return try? WCTarget(
                bundleID: "容器 " + String(uuid.prefix(8)),
                name: "App 容器 " + String(uuid.prefix(8)),
                path: path
            )
        }
        return (targets, baselineInode > cap)
    }
}
