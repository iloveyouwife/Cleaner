import SwiftUI

struct ContentView: View {
    @StateObject private var model = WorseCleanerModel()
    @State private var manualPath = ""
    @State private var pendingCleanup: WCTarget?
    @State private var confirmCleanup = false

    var body: some View {
        NavigationStack {
            List {
                Section("访问环境") {
                    HStack {
                        Text("App Group")
                        Spacer()
                        Text(model.appGroupReady ? "已授权" : "未授权")
                            .foregroundStyle(model.appGroupReady ? .green : .red)
                    }
                    Text("使用 worse_query 获取 App 容器访问权限，不需要设备配对、AFC、VPN 或后台音频。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("手动添加容器（列表不可用时）") {
                    TextField("/var/mobile/Containers/Data/Application/<UUID>", text: $manualPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                    Button("添加 App 容器") {
                        model.addManualPath(manualPath.trimmingCharacters(in: .whitespacesAndNewlines))
                        manualPath = ""
                    }
                    .disabled(model.busy || manualPath.isEmpty)
                }

                Section {
                    Button {
                        model.loadApps()
                    } label: {
                        Label("刷新已安装 App 列表", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.busy)

                    ForEach(model.apps) { target in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(target.name).font(.headline)
                            Text(target.bundleID)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            if let data = model.usage[target.id] {
                                Text("\(data.removableItemCount) 项 · \(ByteCountFormatter.string(fromByteCount: data.totalBytes, countStyle: .file))")
                                    .font(.subheadline)
                            } else {
                                Text("未扫描").font(.subheadline).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 18) {
                                Button("扫描") { model.scan(target) }
                                    .buttonStyle(.bordered)
                                    .disabled(model.busy)
                                Button("清理") {
                                    pendingCleanup = target
                                    confirmCleanup = true
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .disabled(model.busy || model.usage[target.id] == nil)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                } header: {
                    Text("App 缓存")
                } footer: {
                    Text("仅操作每个 App 的 Library/Caches 与 tmp。不会删除 Documents、数据库或整个 App 容器。需要先成功扫描，再逐个确认清理。")
                }

                Section("运行结果") {
                    if model.busy { ProgressView() }
                    Text(model.status)
                        .font(.footnote)
                        .textSelection(.enabled)
                }

                Section("提醒") {
                    Text("这是测试版。某些 App 把离线资源和登录数据保存在缓存中，清理前请备份。若访问被拒绝，会直接报告错误而不声称清理了 0 KB。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("清存 · worse_query")
            .navigationBarTitleDisplayMode(.inline)
            .task { model.loadApps() }
            .confirmationDialog(
                "确认清理 \(pendingCleanup?.name ?? "")？",
                isPresented: $confirmCleanup,
                titleVisibility: .visible
            ) {
                Button("删除 Caches 和 tmp 内的缓存", role: .destructive) {
                    if let target = pendingCleanup { model.clean(target) }
                    pendingCleanup = nil
                }
                Button("取消", role: .cancel) { pendingCleanup = nil }
            } message: {
                Text("将删除此 App 可访问的缓存与临时文件，无法撤销；不会删除目录本身。")
            }
        }
    }
}
