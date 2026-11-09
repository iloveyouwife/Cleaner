import SwiftUI

// 3105 CleanerView's layout: search, summary, sortable/selectable app rows,
// selection menu, bulk action, and confirmation. The backend is worse_query.
struct ContentView: View {
    private static let hiddenServiceIDs: Set<String> = [
        "com.apple.GameOverlayUI", "com.apple.HeadphoneProxService",
        "com.apple.PassbookUIService", "com.apple.PDUIApp",
        "com.apple.SIMSetupUIService", "com.apple.webapp"
    ]

    @StateObject private var model = WorseCleanerModel()
    @State private var searchText = ""
    @State private var searchExpanded = false
    @FocusState private var searchFocused: Bool
    @State private var largestFirst = true
    @State private var selectedIDs = Set<String>()
    @State private var manualPath = ""
    @State private var confirmingClean = false
    @State private var showingDiagnostics = false
    @State private var showingAdvancedSettings = false
    @State private var showingExcluded = false
    @State private var confirmingOnlineNames = false
    @State private var showingBundleIDOnly = false
    @State private var showingUnidentifiedContainers = false

    private var filteredApps: [WCTarget] {
        let matching = model.apps.filter {
            !model.excludedPaths.contains($0.path) &&
            !isInternalSystemService($0.bundleID) && (
                searchText.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.bundleID.localizedCaseInsensitiveContains(searchText) ||
                URL(fileURLWithPath: $0.path).lastPathComponent
                    .localizedCaseInsensitiveContains(searchText)
            )
        }
        return matching.sorted { lhs, rhs in
            let a = model.usage[lhs.id]?.totalBytes ?? -1
            let b = model.usage[rhs.id]?.totalBytes ?? -1
            if a != b { return largestFirst ? a > b : a < b }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // A data-container UUID is not an App identifier. Keep these entries
    // separate from apps with a verifiable Bundle ID or display name.
    private var namedApps: [WCTarget] {
        filteredApps.filter {
            !isUnknownContainer($0) && $0.name != $0.bundleID
        }
    }

    private var bundleIDOnlyApps: [WCTarget] {
        filteredApps.filter {
            !isUnknownContainer($0) && $0.name == $0.bundleID
        }
    }

    private var unidentifiedContainers: [WCTarget] {
        filteredApps.filter(isUnknownContainer)
    }

    private var displayedApps: [WCTarget] {
        namedApps + ((showingBundleIDOnly || !searchText.isEmpty) ? bundleIDOnlyApps : [])
            + ((showingUnidentifiedContainers || !searchText.isEmpty) ? unidentifiedContainers : [])
    }

    private func isUnknownContainer(_ app: WCTarget) -> Bool {
        app.bundleID.hasPrefix("容器 ") || app.bundleID == "manual" ||
        app.name.hasPrefix("App 容器 ")
    }

    private var selectedSize: Int64 {
        model.apps.reduce(0) { result, app in
            result + (selectedIDs.contains(app.id) ? model.usage[app.id]?.totalBytes ?? 0 : 0)
        }
    }

    private var availableSize: Int64 {
        model.apps.reduce(0) { sum, app in
            let visible = !isInternalSystemService(app.bundleID)
            return sum + ((!visible || model.excludedPaths.contains(app.path))
                ? 0 : model.usage[app.id]?.totalBytes ?? 0)
        }
    }

    private var accessibleGroups: [String] {
        WCFileAccess.accessibleGroups()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)
                .background(Color(uiColor: .systemGroupedBackground))

                List {
                    summarySection
                    applicationSection
                    bundleIDOnlySection
                    unidentifiedContainerSection
                    if !model.appGroupReady || !model.groupConfirmed {
                        signingWarning
                    }
                Section("运行结果") {
                    Text(model.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                }
                .listStyle(.insetGrouped)
                .scrollDismissesKeyboard(.interactively)
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
                        toolbarIcon("arrow.clockwise")
                    }
                    .disabled(model.busy)
                    .accessibilityLabel("刷新 App 列表")
                    Menu {
                        Button {
                            confirmingOnlineNames = true
                        } label: {
                            menuItem("联网补全 App 名称", icon: "magnifyingglass")
                        }
                        .disabled(model.busy)
                        Button {
                            showingAdvancedSettings = true
                        } label: {
                            menuItem("高级设置", icon: "gearshape")
                        }
                    } label: {
                        toolbarIcon("ellipsis.circle")
                    }
                    .accessibilityLabel("更多选项")
                }
            }
            .sheet(isPresented: $showingAdvancedSettings) { advancedSettingsSheet }
            .sheet(isPresented: $showingExcluded) { excludedAppsSheet }
            .confirmationDialog("联网补全 App 名称", isPresented: $confirmingOnlineNames,
                                titleVisibility: .visible) {
                Button("联网补全") { model.completeMissingNamesOnline() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将向 Apple 商店发送未识别的 Bundle ID 查询名称，不上传缓存文件；每次最多 80 个。仅适用于已知 Bundle ID 的项目。")
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
                selectedIDs.removeAll()
                model.refreshSigning()
            }
            .onChange(of: model.apps) { _, currentApps in
                selectedIDs.formIntersection(Set(currentApps.map(\.id)))
            }
            .task { model.loadApps() }
        }
    }

    // The idle search prompt is its own centered control. TextField's intrinsic
    // width and caret padding cannot push this icon/text pair off-center.
    private var searchBar: some View {
        Group {
            if searchExpanded || !searchText.isEmpty {
                HStack(spacing: 10) {
                    contentIcon("magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onAppear { searchFocused = true }
                        .onSubmit {
                            searchFocused = false
                            if searchText.isEmpty { searchExpanded = false }
                        }
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            searchFocused = true
                        } label: {
                            contentIcon("xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 18)
            } else {
                Button {
                    searchExpanded = true
                } label: {
                    HStack(spacing: 8) {
                        contentIcon("magnifyingglass")
                        Text("搜索")
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索")
            }
        }
        .font(.system(size: 17))
        .frame(height: 46)
        .background(Color(uiColor: .systemGray5), in: Capsule())
        .onChange(of: searchFocused) { _, focused in
            if !focused && searchText.isEmpty { searchExpanded = false }
        }
    }

    private var summarySection: some View {
        Section {
            VStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已扫描缓存")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(sizeText(availableSize))
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("已选择 \(selectedIDs.count) 项")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(sizeText(selectedSize))
                            .font(.headline.monospacedDigit())
                    }
                }
                .padding(.top, 4)

                Divider()

                Button {
                    model.scanAll()
                } label: {
                    HStack(spacing: 12) {
                        if model.busy {
                            ProgressView().frame(width: 22, height: 22)
                        } else {
                            contentIcon("arrow.triangle.2.circlepath")
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.busy ? "扫描中 · \(model.scannedAppCount) / \(model.apps.count)" : "重新扫描缓存")
                                .font(.subheadline.weight(.semibold))
                            Text("\(model.apps.count) 个数据容器 · 仅检查 Caches / tmp")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if !model.busy {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 18, height: 22)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.accentColor.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.busy || !model.appGroupReady || !model.groupConfirmed)

                Button {
                    confirmingClean = true
                } label: {
                    HStack(spacing: 8) {
                        contentIcon("trash")
                        Text("清理所选 \(selectedIDs.count) 项 · \(sizeText(selectedSize))")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || !model.appGroupReady || !model.groupConfirmed || selectedIDs.isEmpty ||
                          !selectedIDs.contains(where: { model.usage[$0] != nil }))
            }
            .padding(.vertical, 8)
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18, height: 18)
                Text("有限清理模式")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .textCase(nil)
        } footer: {
            Text("只清理手动选中项目的 Caches/tmp，不删除 Documents 或整个容器。")
        }
    }

    private var applicationSection: some View {
        Section {
            if namedApps.isEmpty {
                VStack(spacing: 10) {
                    Text("目前没有已识别名称的 App")
                        .font(.subheadline.weight(.medium))
                    Text("仅识别包名或容器编号的项目位于下方的独立分组。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ForEach(namedApps) { app in
                    appRow(app)
                }
            }
        } header: {
            HStack {
                Text("已识别名称（\(namedApps.count)）")
                Spacer()
                if model.busy { ProgressView().controlSize(.mini) }
            }
            .textCase(nil)
        } footer: {
            Text("展示已识别名称及 Bundle ID · 已排除 \(model.excludedPaths.count) 项")
        }
    }

    private var bundleIDOnlySection: some View {
        Section {
            if showingBundleIDOnly || !searchText.isEmpty {
                ForEach(bundleIDOnlyApps) { app in
                    appRow(app)
                }
            }
        } header: {
            Button {
                showingBundleIDOnly.toggle()
            } label: {
                HStack {
                    Text("仅识别 Bundle ID（\(bundleIDOnlyApps.count)）")
                    Spacer()
                    Image(systemName: showingBundleIDOnly ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 18, height: 18)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .textCase(nil)
        } footer: {
            Text("系统未提供显示名称，可通过右上角菜单尝试补全。")
        }
    }

    private var unidentifiedContainerSection: some View {
        Section {
            if showingUnidentifiedContainers || !searchText.isEmpty {
                ForEach(unidentifiedContainers) { app in
                    appRow(app, unidentified: true)
                }
            }
        } header: {
            Button {
                showingUnidentifiedContainers.toggle()
            } label: {
                HStack {
                    Text("未识别数据容器（\(unidentifiedContainers.count)）")
                    Spacer()
                    Image(systemName: showingUnidentifiedContainers ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 18, height: 18)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .textCase(nil)
        } footer: {
            Text("UUID 不是软件名称。归属不明时请勿勾选清理。")
        }
    }

    private func appRow(_ app: WCTarget, unidentified: Bool = false) -> some View {
        Button {
            if selectedIDs.contains(app.id) { selectedIDs.remove(app.id) }
            else { selectedIDs.insert(app.id) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(unidentified ? "未知 App 数据容器" : app.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(unidentified
                         ? "UUID · \(URL(fileURLWithPath: app.path).lastPathComponent)"
                         : app.bundleID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
                    .foregroundStyle(selectedIDs.contains(app.id) ? Color.accentColor : Color.secondary)
                    .font(.system(size: 21, weight: .regular))
                    .frame(width: 24, height: 24)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
    }

    private var signingWarning: some View {
        Section {
            HStack(spacing: 8) {
                contentIcon("exclamationmark.triangle")
                Text("请确认专用 App Group")
            }
            .foregroundStyle(.orange)
            Text("首次使用需在右上角「高级设置」确认签名授权的专用 App Group；以后相同组将记住确认。未确认前禁止扫描与删除。")
                .font(.footnote)
            Button("打开高级设置") { showingAdvancedSettings = true }
        }
    }

    private var diagnosticsSection: some View {
        Section {
            DisclosureGroup("访问诊断与手动添加", isExpanded: $showingDiagnostics) {
                Text(model.accessDiagnostics)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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
                    .disabled(model.busy)
                    Toggle("确认该 App Group 专供本清理器使用", isOn: Binding(
                        get: { model.groupConfirmed },
                        set: { model.setGroupConfirmed($0) }
                    ))
                    .disabled(model.busy)
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
            Button {
                selectedIDs.formUnion(displayedApps.map(\.id))
            } label: {
                menuItem("全选当前列表", icon: "checkmark.circle")
            }
            Button {
                selectedIDs.removeAll()
            } label: {
                menuItem("取消全选", icon: "circle")
            }
            Divider()
            Button {
                let paths = Set(model.apps.filter { selectedIDs.contains($0.id) }.map(\.path))
                model.exclude(paths)
                selectedIDs.removeAll()
            } label: {
                menuItem("排除选中的 \(selectedIDs.count) 个 App", icon: "eye.slash")
            }
            .disabled(selectedIDs.isEmpty)
            Button {
                showingExcluded = true
            } label: {
                menuItem("管理已排除 App（\(model.excludedPaths.count)）", icon: "list.bullet")
            }
        } label: {
            toolbarIcon("checklist")
        }
        .accessibilityLabel("选择操作")
        .disabled(model.busy)
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $largestFirst) {
                Text("缓存从大到小").tag(true)
                Text("缓存从小到大").tag(false)
            }
        } label: {
            toolbarIcon("arrow.up.arrow.down")
        }
        .accessibilityLabel("排序")
        .disabled(model.busy)
    }

    private func sizeText(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// One optical slot per symbol prevents different intrinsic symbol widths
    /// from shifting toolbar and row alignment. Native menus still apply the
    /// system's accessibility scaling to their presented icons.
    private func toolbarIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .medium))
            .frame(width: 24, height: 24, alignment: .center)
            .accessibilityHidden(true)
    }

    private func contentIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .regular))
            .frame(width: 22, height: 22, alignment: .center)
            .accessibilityHidden(true)
    }

    private func menuItem(_ title: String, icon: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .frame(width: 22, height: 22, alignment: .center)
        }
    }

    private func isInternalSystemService(_ bundleID: String) -> Bool {
        // These are system helper services, not independently launchable apps.
        // They stay hidden rather than being offered as cache-cleaning targets.
        Self.hiddenServiceIDs.contains(bundleID)
    }
}
