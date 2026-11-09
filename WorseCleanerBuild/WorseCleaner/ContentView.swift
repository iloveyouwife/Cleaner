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
    @State private var showingAdvancedSettings = false
    @State private var showingExcluded = false

    private var filteredApps: [WCTarget] {
        let matching = model.apps.filter {
            !model.excludedPaths.contains($0.path) && (
                searchText.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.bundleID.localizedCaseInsensitiveContains(searchText)
            )
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
        model.apps.reduce(0) { sum, app in
            sum + (model.excludedPaths.contains(app.path) ? 0 : model.usage[app.id]?.totalBytes ?? 0)
        }
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
                    Menu {
                        Button("管理已排除 App（\(model.excludedPaths.count)）", systemImage: "eye.slash") {
                            showingExcluded = true
                        }
                        Button("高级设置", systemImage: "gearshape") {
                            showingAdvancedSettings = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingAdvancedSettings) { advancedSettingsSheet }
            .sheet(isPresented: $showingExcluded) { excludedAppsSheet }
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
                    Text("正在自动发现容器，或当前搜索条件下没有结果。可从右上角进入高级设置。")
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
            Text("自动深度发现可能耗时数分钟；部分容器若无法获取系统元数据，将显示 Bundle ID 或容器编号。已排除 \(model.excludedPaths.count) 个 App。")
        }
    }

    private var signingWarning: some View {
        Section {
            Label("请确认专用 App Group", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("首次使用需在右上角「高级设置」确认签名授权的专用 App Group；以后相同组将记住确认。未确认前禁止扫描与删除。")
                .font(.footnote)
            Button("打开高级设置") { showingAdvancedSettings = true }
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
                    Toggle("确认该 App Group 专供本清理器使用", isOn: Binding(
                        get: { model.groupConfirmed },
                        set: { model.setGroupConfirmed($0) }
                    ))
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

    private var advancedSettingsSheet: some View {
        NavigationStack {
            Form {
                diagnosticsSection
                Section {
                    Text("此页面为高级诊断功能。首页默认自动深度发现 App 容器；组权限仅对已确认的专用 App Group 生效。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("高级设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showingAdvancedSettings = false }
                }
            }
        }
    }

    private var excludedAppsSheet: some View {
        NavigationStack {
            List {
                let excluded = model.apps.filter { model.excludedPaths.contains($0.path) }
                if excluded.isEmpty {
                    ContentUnavailableView("暂无已排除 App", systemImage: "eye.slash",
                                           description: Text("在首页勾选一个或多个 App，再点击左上角的排除选项。"))
                } else {
                    Section("已排除 App（\(excluded.count)）") {
                        ForEach(excluded) { app in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name).font(.subheadline.weight(.medium))
                                    Text(app.bundleID).font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("取消排除") { model.restoreExcluded([app.path]) }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    Section {
                        Button("全部恢复") {
                            model.restoreExcluded(model.excludedPaths)
                        }
                    }
                }
            }
            .navigationTitle("管理已排除 App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showingExcluded = false }
                }
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
            Divider()
            Button("排除选中的 \(selectedIDs.count) 个 App", systemImage: "eye.slash") {
                let paths = Set(model.apps.filter { selectedIDs.contains($0.id) }.map(\.path))
                model.exclude(paths)
                selectedIDs.removeAll()
            }
            .disabled(selectedIDs.isEmpty)
            Button("管理已排除 App（\(model.excludedPaths.count)）", systemImage: "list.bullet") {
                showingExcluded = true
            }
        } label: {
            Image(systemName: "checklist")
        }
        .disabled(model.busy)
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
        if bytes == 0 { return "0 KB" }
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
