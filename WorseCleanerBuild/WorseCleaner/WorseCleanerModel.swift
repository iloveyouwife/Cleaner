import SwiftUI

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
    @Published private(set) var excludedPaths = Set(
        UserDefaults.standard.stringArray(forKey: "wc.excludedPaths") ?? []
    )

    private let queue = DispatchQueue(label: "org.worsecleaner.serial", qos: .userInitiated)
    private let confirmedGroupKey = "wc.confirmedDedicatedGroup"

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
        groupConfirmed = appGroupReady &&
            UserDefaults.standard.string(forKey: confirmedGroupKey) == groupID
    }

    func loadApps() {
        guard !busy else { return }
        refreshSigning()
        busy = true
        status = "正在读取已安装 App 的容器列表……"
        queue.async {
            var error: NSString?
            let raw = WCEnumerateApplicationContainers(&error)
            let apps = raw.compactMap { item -> WCTarget? in
                guard let id = item["bundleID"], let path = item["path"] else { return nil }
                return try? WCTarget(
                    bundleID: id, name: item["name"] ?? id, path: path
                )
            }
            let message = error.map(String.init)
            DispatchQueue.main.async {
                self.apps = apps
                self.busy = false
                let onlySelf = apps.count == 1 &&
                    apps.first?.bundleID == Bundle.main.bundleIdentifier
                if onlySelf {
                    self.status = "仅发现本工具自己。系统限制了 MCM/LaunchServices 枚举；这不是全部已安装 App。可手动添加已知 UUID 容器。"
                } else {
                    self.status = apps.isEmpty
                        ? (message ?? "没有发现 App 容器，可手动添加已知 UUID 路径。")
                        : "发现 \(apps.count) 个可查询容器，尚未验证可读写权限。"
                }
                self.deepDiscoverApps(automaticallyScan: true)
            }
        }
    }

    func addManualPath(_ path: String) {
        guard !busy else { return }
        do {
            let target = try WCTarget(bundleID: "manual", name: "手动指定的 App", path: path)
            if !apps.contains(where: { $0.path == target.path }) {
                apps.insert(target, at: 0)
            }
            status = "已添加容器；尚未验证访问权限，请点击扫描。"
        } catch {
            status = error.localizedDescription
        }
    }

    func deepDiscoverApps(automaticallyScan: Bool = false) {
        guard !busy else { return }
        busy = true
        status = "正在使用 worse_query 项目的 pathleak 枚举容器 inode；可能需要几分钟，结果不保证完整。"
        queue.async {
            let result = Result { try WCPathDiscovery.enumerateRoots() }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let (found, capped)):
                    let existing = Set(self.apps.map(\.path))
                    self.apps.append(contentsOf: found.filter { !existing.contains($0.path) })
                    self.status = "inode 枚举发现 \(found.count) 个路径，当前列表 \(self.apps.count) 项"
                        + (capped ? "；已达到 500 万 inode 上限，可能漏掉 App。" : "。")
                    if automaticallyScan && self.appGroupReady && self.groupConfirmed {
                        self.scanAll()
                    }
                case .failure(let error):
                    self.status = "路径枚举失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func scan(_ target: WCTarget) {
        guard !busy else { return }
        guard appGroupReady, groupConfirmed else {
            status = "请先在「访问诊断」确认专用 App Group，避免操作其他软件的共享缓存。"
            return
        }
        busy = true
        status = "正在扫描 \(target.name)……"
        let selectedGroup = groupID
        queue.async {
            let result = Result { try WCFileAccess.inspect(target, groupID: selectedGroup) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let inspection):
                    self.usage[target.id] = inspection.usage
                    if let index = self.apps.firstIndex(where: { $0.path == target.path }) {
                        self.apps[index] = inspection.target
                    }
                    self.status = "\(inspection.target.name)：\(inspection.usage.removableItemCount) 项，预计 \(ByteCountFormatter.string(fromByteCount: inspection.usage.totalBytes, countStyle: .file))。"
                case .failure(let error):
                    self.usage.removeValue(forKey: target.id)
                    self.status = "\(target.name) 扫描失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func clean(_ target: WCTarget) {
        // A separate successful scan is mandatory; the UI also asks for
        // destructive-action confirmation before calling this method.
        guard !busy, groupConfirmed, appGroupReady, usage[target.id] != nil else { return }
        busy = true
        status = "正在清理 \(target.name) 的 Caches/tmp……"
        let selectedGroup = groupID
        queue.async {
            let result = Result { try WCFileAccess.clean(target, groupID: selectedGroup) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let report):
                    self.usage[target.id] = report.after
                    let size = ByteCountFormatter.string(
                        fromByteCount: report.freedBytes, countStyle: .file
                    )
                    self.status = "清理完成：\(target.name) 已删除 \(report.removedItemCount) 项，释放约 \(size)；失败 \(report.failedItemCount) 项。"
                case .failure(let error):
                    self.usage.removeValue(forKey: target.id)
                    self.status = "清理未确认：\(error.localizedDescription)"
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
        let targets = apps.filter { !excludedPaths.contains($0.path) }
        let selectedGroup = groupID
        scannedAppCount = 0
        status = "正在检查已发现 App 的缓存权限……"
        queue.async {
            var results: [String: LimitedCleanerUsage] = [:]
            var identities: [String: WCTarget] = [:]
            var failures = 0
            for (index, target) in targets.enumerated() {
                if let inspection = try? WCFileAccess.inspect(target, groupID: selectedGroup) {
                    results[target.id] = inspection.usage
                    identities[target.id] = inspection.target
                } else {
                    failures += 1
                }
                DispatchQueue.main.async { self.scannedAppCount = index + 1 }
            }
            DispatchQueue.main.async {
                self.usage.merge(results) { _, newer in newer }
                self.apps = self.apps.map { identities[$0.id] ?? $0 }
                self.busy = false
                self.status = "完成：扫描 \(targets.count) 个已发现容器，成功 \(results.count)，访问失败 \(failures)。失败容器未计为 0 KB。"
            }
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
            for target in targets {
                do {
                    let result = try WCFileAccess.clean(target, groupID: selectedGroup)
                    latest[target.id] = result.after
                    freed += result.freedBytes
                    removed += result.removedItemCount
                    failures += result.failedItemCount
                } catch {
                    failures += 1
                }
            }
            DispatchQueue.main.async {
                for (key, result) in latest { self.usage[key] = result }
                self.busy = false
                self.status = "已删除 \(removed) 项，释放约 \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))；失败或未验证 \(failures) 项。"
            }
        }
    }
}
