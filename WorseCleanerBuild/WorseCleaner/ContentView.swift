import SwiftUI

// 3105 CleanerView's layout: search, summary, sortable/selectable app rows,
// selection menu, bulk action, and confirmation. The backend is worse_query.
struct ContentView: View {
    @StateObject private var model = WorseCleanerModel()
    @State private var searchText = ""
    @State private var largestFirst = true
    @State private var selectedIDs = Set<String>()
    @State private var manualPath = ""
    @State private var confirmingClean = false
    @State private var showingDiagnostics = false

    private var filteredApps: [WCTarget] {
        let matching = model.apps.filter {
            searchText.isEmpty ||
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
        return matching.sorted { lhs, rhs in
            let a = model.usage[lhs.id]?.totalBytes ?? -1
            let b = model.usage[rhs.id]?.totalBytes ?? -1
            if a != b { return largestFirst ? a > b : a < b }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var selectedSize: Int64 {
        model.apps.reduce(0) { result, app in
            result + (selectedIDs.contains(app.id) ? model.usage[app.id]?.totalBytes ?? 0 : 0)
        }
    }

    private var availableSize: Int64 {
        model.usage.values.reduce(0) { $0 + $1.totalBytes }
    }

    private var accessibleGroups: [String] {
        WCFileAccess.accessibleGroups()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索 App 名称或 Bundle ID", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                Divider()

                List {
                    summarySection
                    applicationSection
                    if !model.appGroupReady || !model.groupConfirmed {
                        signingWarning
                    }
                    diagnosticsSection
                    Section("运行结果") {
                        Text(model.status)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("App 缓存清理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    selectionMenu
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    sortMenu
                    Button { model.loadApps() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.busy)
                    .accessibilityLabel("刷新 App 列表")
                }
            }
            .alert("确认清理缓存", isPresented: $confirmingClean) {
                Button("确认删除", role: .destructive) {
                    model.cleanSelected(selectedIDs)
                    selectedIDs.removeAll()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将清理选中的 \(selectedIDs.count) 个 App 的 Caches/tmp（约 \(sizeText(selectedSize))），不能撤销。")
            }
            .onChange(of: model.groupID) { _, _ in
                model.groupConfirmed = false
                model.refreshSigning()
            }
            .task { model.loadApps() }
        }
    }

    private var summarySection: some View {
        Section {
            LabeledContent("可清理缓存") {
                Text(sizeText(availableSize)).monospacedDigit()
            }
            LabeledContent("已选中") {
                Text("\(selectedIDs.count) 个 App · \(sizeText(selectedSize))")
                    .monospacedDigit()
            }
            Button {
                model.scanAll()
            } label: {
                HStack(spacing: 8) {
                    if model.busy { ProgressView() }
                    else { Image(systemName: "magnifyingglass") }
                    Text(model.busy ? "正在扫描 \(model.scannedAppCount) 项" : "扫描已发现的 App")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 36)
            }
            .disabled(model.busy || !model.appGroupReady || !model.groupConfirmed)

            Button {
                confirmingClean = true
            } label: {
                Label("清理选中 · \(sizeText(selectedSize))", systemImage: "trash")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || selectedIDs.isEmpty ||
                      !selectedIDs.contains(where: { model.usage[$0] != nil }))
        } header: {
            Label("有限清理模式", systemImage: "checkmark.shield")
        } footer: {
            Text("仅操作所选 App 的 Library/Caches 与 tmp；不删除 Documents、数据库或 App 容器。")
        }
    }

    private var applicationSection: some View {
        Section {
            if filteredApps.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("尚未发现可访问的 App")
                        .font(.headline)
                    Text("容器枚举可能被系统限制。可在下方诊断中手动添加已知容器路径。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(filteredApps) { app in
                    Button {
                        if selectedIDs.contains(app.id) { selectedIDs.remove(app.id) }
                        else { selectedIDs.insert(app.id) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "app.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.blue)
                                .frame(width: 36, height: 36)
                                .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(app.bundleID)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if let usage = model.usage[app.id] {
                                Text(sizeText(usage.totalBytes))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("未扫描")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Image(systemName: selectedIDs.contains(app.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIDs.contains(app.id) ? Color.blue : Color.secondary)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy)
                }
            }
        } header: {
            HStack {
                Text("已发现 App（\(filteredApps.count)）")
                Spacer()
                if model.busy { ProgressView().controlSize(.mini) }
            }
            .textCase(nil)
        } footer: {
            Text("如果这里只显示清存自己，代表容器目录发现功能被系统限制，并不代表其他 App 没有缓存。")
        }
    }

    private var signingWarning: some View {
        Section {
            Label("尚未获得有效的专用 App Group 权限", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("当前 IPA 里的示例标识不能自动获得签名授权。需要签名工具实际授予一个专用 App Group；未确认前禁止扫描与删除。")
                .font(.footnote)
        }
    }

    private var diagnosticsSection: some View {
        Section {
            DisclosureGroup("访问诊断与手动添加", isExpanded: $showingDiagnostics) {
                LabeledContent("签名里声明的 App Group") {
                    Text(model.grantedGroups.isEmpty
                         ? "无（签名可能已移除授权）"
                         : "\(model.grantedGroups.count) 个")
                        .foregroundStyle(model.grantedGroups.isEmpty ? Color.red : Color.secondary)
                }
                ForEach(model.grantedGroups, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group).font(.caption.monospaced()).textSelection(.enabled)
                        Text(accessibleGroups.contains(group) ? "容器可访问" : "容器不可访问")
                            .font(.caption2)
                            .foregroundStyle(accessibleGroups.contains(group) ? Color.green : Color.red)
                    }
                }
                if !accessibleGroups.isEmpty {
                    Picker("用于 worse_query 的 App Group", selection: $model.groupID) {
                        ForEach(accessibleGroups, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    Toggle("确认该 App Group 专供本清理器使用", isOn: $model.groupConfirmed)
                    Text("worse_query 会临时替换所选 App Group 的 Library/Caches。共享组可能影响其他 App；只有专用组才能勾选。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                TextField("App 容器 UUID 根路径", text: $manualPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                Button("深度发现 App 容器（慢速）") {
                    model.deepDiscoverApps()
                }
                .disabled(model.busy)
                Text("参考 worse_query 原版 pathleak；通过 inode 查找目录，可能耗时且不能保证列出全部 App。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("添加 App 容器") {
                    model.addManualPath(manualPath.trimmingCharacters(in: .whitespacesAndNewlines))
                    manualPath = ""
                }
                .disabled(manualPath.isEmpty || model.busy)
            }
        }
    }

    private var selectionMenu: some View {
        Menu {
            Button("全选当前列表", systemImage: "checkmark.circle") {
                selectedIDs.formUnion(filteredApps.map(\.id))
            }
            Button("取消全选", systemImage: "circle") {
                selectedIDs.removeAll()
            }
        } label: {
            Image(systemName: "checklist")
        }
        .disabled(model.busy || filteredApps.isEmpty)
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $largestFirst) {
                Text("缓存从大到小").tag(true)
                Text("缓存从小到大").tag(false)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .disabled(model.busy)
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
