import Foundation
import Darwin

struct LegacyContainerSample: Identifiable {
    let uuid: String
    let root: String
    let caches: String
    let tmp: String
    var id: String { uuid }
}

struct LegacyAccessReport {
    let discovery: String
    let discoveredCount: Int
    let readableRootCount: Int
    let readableCachesCount: Int
    let readableTmpCount: Int
    let error: String
    let samples: [LegacyContainerSample]

    static let notStarted = LegacyAccessReport(
        discovery: "尚未检查", discoveredCount: 0,
        readableRootCount: 0, readableCachesCount: 0,
        readableTmpCount: 0, error: "", samples: []
    )
}

enum LegacyAccessScanner {
    /// POSIX open is only for checking whether access works.
    /// O_NOFOLLOW refuses symlinks and no file operations are destructive.
    private static func openResult(_ path: String) -> String {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
            close(fd)
            return "可打开"
        }
        let code = errno
        return code == ENOENT ? "不存在" : "errno=\(code)"
    }

    static func run() -> LegacyAccessReport {
        let roots = [
            "/var/mobile/Containers/Data/Application",
            "/private/var/mobile/Containers/Data/Application"
        ]
        var candidates: [String] = []
        var rootUsed: String? = nil
        var problem = ""

        for root in roots {
            do {
                candidates = try FileManager.default.contentsOfDirectory(atPath: root)
                    .filter { UUID(uuidString: $0) != nil }
                    .sorted()
                rootUsed = root
                break
            } catch {
                problem = "目录 \(root) 不可枚举：\(error.localizedDescription)"
            }
        }

        guard let rootUsed else {
            return LegacyAccessReport(
                discovery: "无权限", discoveredCount: 0,
                readableRootCount: 0, readableCachesCount: 0,
                readableTmpCount: 0, error: problem, samples: []
            )
        }

        var rootsOpened = 0
        var cachesOpened = 0
        var tmpOpened = 0
        var samples: [LegacyContainerSample] = []

        for uuid in candidates {
            let container = rootUsed + "/" + uuid
            let rootResult = openResult(container)
            let cacheResult = openResult(container + "/Library/Caches")
            let tmpResult = openResult(container + "/tmp")

            if rootResult == "可打开" { rootsOpened += 1 }
            if cacheResult == "可打开" { cachesOpened += 1 }
            if tmpResult == "可打开" { tmpOpened += 1 }

            if samples.count < 20 {
                samples.append(LegacyContainerSample(
                    uuid: uuid, root: rootResult, caches: cacheResult, tmp: tmpResult
                ))
            }
        }

        return LegacyAccessReport(
            discovery: "可枚举：\(rootUsed)",
            discoveredCount: candidates.count, readableRootCount: rootsOpened,
            readableCachesCount: cachesOpened, readableTmpCount: tmpOpened,
            error: "", samples: samples
        )
    }
}
