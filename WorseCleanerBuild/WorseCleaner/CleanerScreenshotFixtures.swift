#if targetEnvironment(simulator)
import Foundation

/// Deterministic simulator-only data for visual regression snapshots.
/// No discovery, cache reading, or deletion occurs in this fixture.
@MainActor
enum CleanerScreenshotFixtures {
    static func install(into model: WorseCleanerModel) {
        let entries: [(name: String, bundleID: String, bytes: Int64)] = [
            ("微信", "com.tencent.xin", 228_500_000),
            ("抖音", "com.ss.iphone.ugc.Aweme", 215_400_000),
            ("QQ", "com.tencent.mqq", 98_200_000),
            ("豆包", "com.bot.doubao", 51_400_000),
            ("X（前身为 Twitter）", "com.atebits.Tweetie2", 20_400_000),
            ("哔哩哔哩", "tv.danmaku.bilianime", 19_800_000),
            ("一款名称非常长的常用测试应用程序", "com.example.long-name.sample", 16_300_000),
            ("com.example.unresolved-name", "com.example.unresolved-name", 10_100_000)
        ]

        model.restoreExcluded(model.excludedPaths)
        var targets: [WCTarget] = []
        var usage: [String: LimitedCleanerUsage] = [:]
        for (index, entry) in entries.enumerated() {
            let tail = String(format: "%012d", index + 1)
            let path = "/var/mobile/Containers/Data/Application/00000000-0000-4000-8000-\(tail)"
            guard let target = try? WCTarget(
                bundleID: entry.bundleID, name: entry.name, path: path
            ) else { continue }
            targets.append(target)
            usage[target.id] = LimitedCleanerUsage(
                cacheBytes: entry.bytes * 4 / 5,
                temporaryBytes: entry.bytes / 5,
                removableItemCount: 12 + index
            )
        }

        model.apps = targets
        model.usage = usage
        model.busy = false
        model.appGroupReady = true
        model.groupConfirmed = true
        model.status = "模拟列表仅用于界面检查，不连接真实 App 容器。"
        model.scannedAppCount = targets.count
    }
}
#endif
