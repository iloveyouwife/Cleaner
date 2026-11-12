import SwiftUI
import Darwin

@MainActor
final class WorseCleanerModel: ObservableObject {
    @Published var apps: [WCTarget] = []
    @Published var usage: [String: LimitedCleanerUsage] = [:]
    @Published var busy = false
    @Published var status = "尚未扫描任何 App。"
    @Published var appGroupReady = false
    @Published var grantedGroups: [String] = []
    @Published var groupID = ""
    @Published var groupConfirmed = false
    @Published var scannedAppCount = 0
    @Published var accessDiagnostics = "尚未进行容器访问诊断。"
    @Published private(set) var excludedPaths = Set(
        UserDefaults.standard.stringArray(forKey: "wc.excludedPaths") ?? []
    )

    private let queue = DispatchQueue(label: "org.worsecleaner.serial", qos: .userInitiated)
    private let confirmedGroupKey = "wc.confirmedDedicatedGroup"
    private var discoveredBundleRoots: [String] = []
    private var discoveredLSStore: String?
    private var discoveryDiagnostics = ""
    private var lastPreparedGroup = ""
    private var discoveryPercent = 0

    // Reuse only verified App-name and container mappings for three minutes.
    // Cache sizes and access permissions are NEVER reused: scanAll always
    // measures Caches/tmp again, and cleanSelected always revalidates paths.
    private struct CatalogMemo {
        let value: WCAppCatalog
        let groupID: String
        let targetIDs: Set<String>
        let finishedAt: TimeInterval
    }
    private static let catalogReuseSeconds: TimeInterval = 180
    private var catalogMemo: CatalogMemo?
    private var lastLaunchServicesStamp: WCLaunchServicesStamp?
    private var completedCacheScan = false

    func setGroupConfirmed(_ value: Bool) {
        groupConfirmed = value && appGroupReady
        if groupConfirmed {
            UserDefaults.standard.set(groupID, forKey: confirmedGroupKey)
        } else if UserDefaults.standard.string(forKey: confirmedGroupKey) == groupID {
            UserDefaults.standard.removeObject(forKey: confirmedGroupKey)
        }
    }

    func exclude(_ paths: Set<String>) {
        excludedPaths.formUnion(paths)
        UserDefaults.standard.set(Array(excludedPaths), forKey: "wc.excludedPaths")
    }

    func restoreExcluded(_ paths: Set<String>) {
        excludedPaths.subtract(paths)
        UserDefaults.standard.set(Array(excludedPaths), forKey: "wc.excludedPaths")
    }

    func refreshSigning() {
        grantedGroups = WCFileAccess.signedGroups()
        let available = WCFileAccess.accessibleGroups()
        if !available.contains(groupID) {
            groupID = available.first(where: { $0.localizedCaseInsensitiveContains("worsecleaner") })
                ?? available.first ?? ""
        }
        appGroupReady = !groupID.isEmpty && available.contains(groupID)
        if lastPreparedGroup != groupID {
            catalogMemo = nil
            lastLaunchServicesStamp = nil
            completedCacheScan = false
            usage.removeAll()
            scannedAppCount = 0
            lastPreparedGroup = groupID
        }
        groupConfirmed = appGroupReady &&
            UserDefaults.standard.string(forKey: confirmedGroupKey) == groupID
    }

    func loadApps() {
        guard !busy else { return }
        // Explicit App-list refresh must re-read current app identities.
        catalogMemo = nil
        lastLaunchServicesStamp = nil
        completedCacheScan = false
        refreshSigning()
        busy = true
        status = "正在读取已安装 App 的容器列表……"
        let selectedGroup = groupConfirmed && appGroupReady ? groupID : ""
        queue.async {
            var error: NSString?
            let raw = WCEnumerateApplicationContainers(&error)
            let apps = WCPathDiscovery.uniqueContainers(raw.compactMap { item -> WCTarget? in
                guard let id = item["bundleID"], let path = item["path"] else { return nil }
                return try? WCTarget(
                    bundleID: id, name: item["name"] ?? id, path: path
                )
            })
            let quick = WCPathDiscovery.quickLaunchServicesRoots(
                groupID: selectedGroup, knownPaths: Set(apps.map(\.path))
            )
            let discovered: [WCTarget]
            if let quick {
                // The database owns identities for exact UUID paths. Keep any
                // additional MCM entries; never lose a real container when
                // either catalog alone is incomplete.
                discovered = WCPathDiscovery.uniqueContainers(quick.data + apps)
            } else {
                discovered = apps
            }
            let message = error.map(String.init)
            DispatchQueue.main.async {
                self.usage.removeAll()
                self.apps = discovered
                self.busy = false
                if let quick {
                    self.discoveredLSStore = quick.launchServicesStore
                    self.discoveredBundleRoots = []
                    self.discoveryDiagnostics = quick.diagnostics
                    self.status = "通过 App 数据库发现 \(quick.data.count) 个容器，当前列表 \(discovered.count) 项。"
                    if self.appGroupReady && self.groupConfirmed { self.scanAll() }
                    return
                }
                self.discoveryDiagnostics = "App 数据库快速发现不可用，已使用原有 inode 枚举回退。"
                let onlySelf = discovered.count == 1 &&
                    discovered.first?.bundleID == Bundle.main.bundleIdentifier
                if onlySelf {
                    self.status = "仅发现本工具自己。系统限制了 MCM/LaunchServices 枚举。这不是全部已安装 App。可手动添加已知 UUID 容器。"
                } else {
                    self.status = discovered.isEmpty
                        ? (message ?? "没有发现 App 容器，可手动添加已知 UUID 路径。")
                        : "发现 \(discovered.count) 个可查询容器，尚未验证可读写权限。"
                }
                self.deepDiscoverApps(automaticallyScan: true)
            }
        }
    }

    func addManualPath(_ path: String) {
        guard !busy else { return }
        do {
            let target = try WCTarget(bundleID: "manual", name: "手动指定的 App", path: path)
            let identity = WCPathDiscovery.containerIdentity(target.path)
            if !apps.contains(where: { WCPathDiscovery.containerIdentity($0.path) == identity }) {
                apps.insert(target, at: 0)
            }
            status = "已添加容器，尚未验证访问权限，请点击扫描。"
        } catch {
            status = error.localizedDescription
        }
    }

    func deepDiscoverApps(automaticallyScan: Bool = false) {
        guard !busy else { return }
        catalogMemo = nil
        lastLaunchServicesStamp = nil
        completedCacheScan = false
        busy = true
        discoveryPercent = 0
        let forceFull = !automaticallyScan
        status = forceFull
            ? "正在完整发现 App 与扩展容器，首次全量扫描可能较久。"
            : "正在发现 App 与扩展容器，已有索引时仅扫描新增 inode。"
        queue.async {
            let result = Result {
                try WCPathDiscovery.enumerateRoots(forceFull: forceFull) { done, total in
                    if total == 0 {
                        DispatchQueue.main.async {
                            if self.busy { self.status = "正在解析安装包名称索引……" }
                        }
                        return
                    }
                    let percentage = Int(done * 100 / total)
                    DispatchQueue.main.async {
                        if self.busy && percentage > self.discoveryPercent {
                            self.discoveryPercent = percentage
                            self.status = "正在发现容器：\(percentage)%（\(done)/\(total) inode）"
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let result):
                    let found = result.data
                    self.discoveredBundleRoots = result.bundles
                    self.discoveredLSStore = result.launchServicesStore
                    var seen = Set(self.apps.map { WCPathDiscovery.containerIdentity($0.path) })
                    self.apps.append(contentsOf: found.filter {
                        seen.insert(WCPathDiscovery.containerIdentity($0.path)).inserted
                    })
                    self.status = "\(result.incremental ? "增量" : "完整")扫描 \(result.scannedInodes) 个 inode，发现 \(found.count - result.extensionCount) 个 App、\(result.extensionCount) 个扩展容器。当前列表 \(self.apps.count) 项。"
                    if !result.completeBound {
                        self.status += " 扫描结束时 inode 仍在增长或无法复核范围，列表可能不完整。"
                    }
                    if automaticallyScan && self.appGroupReady && self.groupConfirmed {
                        self.scanAll()
                    }
                case .failure(let error):
                    self.status = "路径枚举失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func scanAll() {
        guard !busy, groupConfirmed, appGroupReady else {
            status = "无法开始：需先确认专用 App Group 已授权。"
            return
        }
        busy = true
        let previousApps = apps
        let excluded = excludedPaths
        let selectedGroup = groupID
        let previousCatalog = catalogMemo
        let shouldRecheckApps = completedCacheScan
        let previousStamp = lastLaunchServicesStamp
        let bundleRoots = discoveredBundleRoots
        let lsStore = discoveredLSStore
        let discoveryInfo = discoveryDiagnostics
        scannedAppCount = 0
        status = "正在检查已发现 App 的缓存权限……"
        queue.async {
            // This is a lightweight MCM lookup plus LS file metadata check,
            // not the expensive full-volume inode discovery.
            let changes = shouldRecheckApps
                ? WCPathDiscovery.quickRecheckApps(
                    existing: previousApps, groupID: selectedGroup,
                    storePath: lsStore, previousStamp: previousStamp
                )
                : nil
            let currentApps = changes?.apps ?? previousApps
            let targets = currentApps.filter { !excluded.contains($0.path) }
            let targetIDs = Set(targets.map(\.id))
            let uptime = ProcessInfo.processInfo.systemUptime
            let recentCatalog: WCAppCatalog?
            if let memo = previousCatalog,
               changes?.changed != true,
               memo.groupID == selectedGroup,
               memo.targetIDs == targetIDs,
               memo.value.containers.count >= 2,
               uptime >= memo.finishedAt,
               uptime - memo.finishedAt < Self.catalogReuseSeconds {
                recentCatalog = memo.value
            } else {
                recentCatalog = nil
            }
            let effectiveLSStore = changes?.storePath ?? lsStore
            let scanStartLSStamp = WCPathDiscovery.launchServicesStamp(
                storePath: effectiveLSStore, groupID: selectedGroup
            )
            let catalogStarted = ProcessInfo.processInfo.systemUptime
            let catalog = recentCatalog ?? WCAppNames.catalog(
                groupID: selectedGroup, discoveredBundleRoots: bundleRoots,
                launchServicesStore: effectiveLSStore, knownPaths: Set(targets.map(\.path))
            )
            let catalogDuration = ProcessInfo.processInfo.systemUptime - catalogStarted
            let inspectionStarted = ProcessInfo.processInfo.systemUptime
            var lastProgressUpdate = inspectionStarted
            var results: [String: LimitedCleanerUsage] = [:]
            var identities: [String: WCTarget] = [:]
            var failures = 0
            var identityCounts: [WCIdentitySource: Int] = [:]
            var namedCount = 0
            var readableButUnnamed = 0
            var metadataErrors: [Int32: Int] = [:]
            for (index, target) in targets.enumerated() {
                if let inspection = try? WCFileAccess.inspect(
                    target, groupID: selectedGroup, knownNames: catalog.names,
                    knownContainers: catalog.containers
                ) {
                    results[target.id] = inspection.usage
                    identities[target.id] = inspection.target
                    identityCounts[inspection.identitySource, default: 0] += 1
                    if inspection.target.name != inspection.target.bundleID &&
                        !inspection.target.name.hasPrefix("App 容器 ") {
                        namedCount += 1
                    } else if inspection.identitySource != .unresolved {
                        readableButUnnamed += 1
                    }
                    if let code = inspection.metadataErrno {
                        metadataErrors[code, default: 0] += 1
                    }
                } else {
                    failures += 1
                }
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastProgressUpdate >= 0.15 || index + 1 == targets.count {
                    lastProgressUpdate = now
                    DispatchQueue.main.async { self.scannedAppCount = index + 1 }
                }
            }
            let inspectionDuration = ProcessInfo.processInfo.systemUptime - inspectionStarted
            let scannedLSStamp = WCPathDiscovery.launchServicesStamp(
                storePath: effectiveLSStore, groupID: selectedGroup
            )
            DispatchQueue.main.async {
                self.discoveredLSStore = effectiveLSStore
                self.lastLaunchServicesStamp = scannedLSStamp
                self.completedCacheScan = true
                // Reuse names only if the database did not change during the scan.
                // Cache sizes and access permissions are never cached.
                self.catalogMemo = catalog.containers.count >= 2 &&
                    WCPathDiscovery.stampIsCurrent(scanStartLSStamp, scannedLSStamp)
                    ? CatalogMemo(value: catalog, groupID: selectedGroup,
                                  targetIDs: targetIDs,
                                  finishedAt: ProcessInfo.processInfo.systemUptime)
                    : nil
                // Remove stale usage only after a verified removal; if MCM
                // was incomplete, quickRecheckApps kept those old entries.
                let stillPresent = Set(currentApps.map(\.id))
                self.usage = self.usage.filter { stillPresent.contains($0.key) }
                for target in targets { self.usage.removeValue(forKey: target.id) }
                self.usage.merge(results) { _, newer in newer }
                self.apps = currentApps.map { identities[$0.id] ?? $0 }
                self.busy = false
                let stats = "名称识别：\(namedCount) 个可显示名称（含离线名称映射）、\(readableButUnnamed) 个 Bundle ID、\(identityCounts[.unresolved, default: 0]) 个未识别容器。"
                let methods = "来源：LaunchServices \(identityCounts[.launchServices, default: 0])，元数据 \(identityCounts[.metadata, default: 0])，保存状态 \(identityCounts[.savedState, default: 0])，偏好文件 \(identityCounts[.preferences, default: 0])。"
                let access = metadataErrors.sorted { $0.value > $1.value }.prefix(2)
                    .map { "errno \($0.key): \($0.value)" }.joined(separator: "，")
                let permissionHint = metadataErrors[EPERM, default: 0] > 0
                    ? " 元数据受系统权限限制。详见高级设置中的访问诊断。" : ""
                self.status = "扫描完成：\(results.count)/\(targets.count) 个容器可访问，" +
                    "识别名称 \(namedCount) 个，识别 Bundle ID \(readableButUnnamed) 个。" +
                    (failures == 0 ? "" : " 扫描失败 \(failures) 个。") + permissionHint
                self.accessDiagnostics = discoveryInfo + "\n" + catalog.diagnostics +
                    "\n扫描耗时：名称索引 \(String(format: "%.1f", catalogDuration)) 秒，缓存计量 \(String(format: "%.1f", inspectionDuration)) 秒。" +
                    "\n" + stats + "\n" + methods +
                    (access.isEmpty ? "" : "\n元数据访问错误：\(access)。EPERM(1) 通常表示沙盒不允许读取该文件，缓存目录可访问不代表元数据可访问。")
            }
        }
    }

    /// Optional recovery when iOS blocks installed app Info.plist and
    /// LaunchServices names. The UI must explicitly disclose the Apple lookup.
    func completeMissingNamesOnline() {
        guard !busy else { return }
        let candidates = Array(Set(apps.compactMap { app -> String? in
            guard app.name == app.bundleID, app.bundleID.contains("."),
                  !app.bundleID.hasPrefix("group.") else { return nil }
            return app.bundleID
        })).sorted().prefix(80)
        guard !candidates.isEmpty else {
            status = "没有需要联网补全名称的 App。"
            return
        }
        busy = true
        status = "向 Apple 查询首批 \(candidates.count) 个未知 App 的公开名称……"
        Task {
            var found: [String: String] = [:]
            let ids = Array(candidates)
            for start in stride(from: 0, to: ids.count, by: 5) {
                let batch = Array(ids[start..<min(start + 5, ids.count)])
                await withTaskGroup(of: (String, String?).self) { group in
                    for id in batch {
                        group.addTask { (id, await WCAppNames.appStoreName(for: id)) }
                    }
                    for await (id, name) in group {
                        if let name { found[id] = name }
                    }
                }
                status = "已查询 \(min(start + 5, ids.count))/\(ids.count) 个 App，找到 \(found.count) 个名称。"
            }
            WCAppNames.storeVerifiedNames(found)
            catalogMemo = nil
            apps = apps.map { app in
                guard app.name == app.bundleID, let name = found[app.bundleID] else {
                    return app
                }
                return (try? WCTarget(bundleID: app.bundleID, name: name, path: app.path)) ?? app
            }
            busy = false
            status = "联网名称补全完成：本次识别 \(found.count) 个，其余可能未在 Apple 商店收录或已下架。"
        }
    }

    func cleanSelected(_ ids: Set<String>) {
        guard !busy, groupConfirmed, appGroupReady else { return }
        let targets = apps.filter {
            ids.contains($0.id) && !excludedPaths.contains($0.path) && usage[$0.id] != nil
        }
        guard !targets.isEmpty else { return }
        busy = true
        let selectedGroup = groupID
        queue.async {
            var latest: [String: LimitedCleanerUsage] = [:]
            var freed: Int64 = 0
            var removed = 0
            var failures = 0
            var failedIDs = Set<String>()
            for target in targets {
                do {
                    let result = try WCFileAccess.clean(target, groupID: selectedGroup)
                    latest[target.id] = result.after
                    freed += result.freedBytes
                    removed += result.removedItemCount
                    failures += result.failedItemCount
                } catch {
                    failures += 1
                    failedIDs.insert(target.id)
                }
            }
            DispatchQueue.main.async {
                for id in failedIDs { self.usage.removeValue(forKey: id) }
                for (key, result) in latest { self.usage[key] = result }
                self.busy = false
                self.status = "已删除 \(removed) 项，释放约 \(CleanerSizeText.bytes(freed))。失败或未验证 \(failures) 项。"
            }
        }
    }
}
