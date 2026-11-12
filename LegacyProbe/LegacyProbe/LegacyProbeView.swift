import SwiftUI
import Darwin

/// Read-only privilege diagnostic for TrollStore on iOS 15.4.
/// This app never deletes data, modifies another app, or starts a root helper.
struct LegacyProbeView: View {
    @State private var report = LegacyAccessReport.notStarted
    @State private var isScanning = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("设备与版本")) {
                    detail("系统", UIDevice.current.systemVersion)
                    detail("进程 UID / EUID", "\(getuid()) / \(geteuid())")
                    Text("此探针专用于验证 TrollStore 的直接读取权限；不会使用 worse_query。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section(header: Text("只读检查")) {
                    Button(isScanning ? "检查中…" : "检查 App 容器读取权限") {
                        runReadOnlyProbe()
                    }
                    .disabled(isScanning)
                    Text("仅枚举 App 数据容器并尝试打开 Caches/tmp，不修改或删除文件。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    detail("目录发现", report.discovery)
                    detail("发现数据容器", "\(report.discoveredCount)")
                    detail("可打开的容器根目录", "\(report.readableRootCount)")
                    detail("可打开的 Caches 目录", "\(report.readableCachesCount)")
                    detail("可打开的 tmp 目录", "\(report.readableTmpCount)")
                    if !report.error.isEmpty {
                        Text(report.error).foregroundColor(.red)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                }
                if !report.samples.isEmpty {
                    Section(header: Text("前 20 个样例（均为只读检查）")) {
                        ForEach(report.samples) { sample in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sample.uuid)
                                    .font(.caption.monospaced())
                                Text("容器 \(sample.root)  |  Caches \(sample.caches)  |  tmp \(sample.tmp)")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                Section(header: Text("下一阶段")) {
                    Text("如果容器能读取，再把 Cleaner 现有的 Caches/tmp 文件描述符安全扫描和选择性删除逻辑移植到 Legacy 版本。")
                        .font(.footnote)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Cleaner Legacy")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func runReadOnlyProbe() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let next = LegacyAccessScanner.run()
            DispatchQueue.main.async {
                self.report = next
                self.isScanning = false
            }
        }
    }
}
