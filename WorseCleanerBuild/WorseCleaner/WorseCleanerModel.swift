import SwiftUI

@MainActor
final class WorseCleanerModel: ObservableObject {
    @Published var apps: [WCTarget] = []
    @Published var usage: [String: LimitedCleanerUsage] = [:]
    @Published var busy = false
    @Published var status = "尚未扫描任何 App。"
    @Published var appGroupReady = false

    private let queue = DispatchQueue(label: "org.worsecleaner.serial", qos: .userInitiated)

    func loadApps() {
        guard !busy else { return }
        appGroupReady = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WCFileAccess.groupID
        ) != nil
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
                self.status = apps.isEmpty
                    ? (message ?? "没有发现 App 容器，可手动添加已知 UUID 路径。")
                    : "发现 \(apps.count) 个 App 容器。请选择要扫描的 App。"
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

    func scan(_ target: WCTarget) {
        guard !busy else { return }
        busy = true
        status = "正在扫描 \(target.name)……"
        queue.async {
            let result = Result { try WCFileAccess.scan(target) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let report):
                    self.usage[target.id] = report
                    self.status = "\(target.name)：\(report.removableItemCount) 项，预计 \(ByteCountFormatter.string(fromByteCount: report.totalBytes, countStyle: .file))。"
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
        guard !busy, usage[target.id] != nil else { return }
        busy = true
        status = "正在清理 \(target.name) 的 Caches/tmp……"
        queue.async {
            let result = Result { try WCFileAccess.clean(target) }
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
}
