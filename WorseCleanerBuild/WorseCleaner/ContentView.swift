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
    @State private var showingRunDetails = false
    @State private var showingAdvancedSettings = false
    @State private var showingExcluded = false
    @State private var confirmingOnlineNames = false
    @State private var showingSelectionPopup = false
    @State private var showingSortPopup = false
    @State private var showingMorePopup = false
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
        #if targetEnvironment(simulator)
        // Screenshot-only fixture: show the full settings layout even when
        // the unsigned simulator build has no App Group entitlements.
        if ProcessInfo.processInfo.arguments.contains("-captureAdvancedSettings") {
            return ["group.example.cleaner"]
        }
        #endif
        return WCFileAccess.accessibleGroups()
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
                    if !model.appGroupReady || !model.groupConfirmed {
                        signingWarning
                    }
                    applicationSection
                    bundleIDOnlySection
                    unidentifiedContainerSection
                    Section {
                        DisclosureGroup(isExpanded: $showingRunDetails) {
                            Text(model.status)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(.top, 4)
                        } label: {
                            HStack(spacing: 8) {
                                contentIcon(model.busy ? "hourglass" : "checkmark.circle")
                                    .foregroundStyle(.secondary)
                                Text(model.busy ? "正在处理，请稍候" : model.status)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    } header: {
                        appSectionHeading("运行结果")
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    // One toolbar item prevents the system from inserting
                    // extra inter-item gaps between these three controls.
                    HStack(spacing: 0) {
                        sortMenu
                        Button { model.loadApps() } label: {
                            toolbarIcon("arrow.clockwise")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .disabled(model.busy)
                        .accessibilityLabel("刷新 App 列表")
                        Button {
                            showingSelectionPopup = false
                            showingSortPopup = false
                            showingMorePopup.toggle()
                        } label: {
                            toolbarIcon("ellipsis.circle")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("更多选项")
                        .popover(isPresented: $showingMorePopup, attachmentAnchor: .rect(.bounds),
                                 arrowEdge: .top) {
                            compactPopup {
                                compactPopupAction("补全App名称", icon: "magnifyingglass",
                                                   enabled: !model.busy) {
                                    showingMorePopup = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                        confirmingOnlineNames = true
                                    }
                                }
                                compactPopupAction("高级设置", icon: "gearshape") {
                                    showingMorePopup = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                        showingAdvancedSettings = true
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAdvancedSettings) { advancedSettingsSheet }
            .sheet(isPresented: $showingExcluded) { excludedAppsSheet }
            .confirmationDialog("补全App名称", isPresented: $confirmingOnlineNames,
                                titleVisibility: .visible) {
                Button("补全App名称") { model.completeMissingNamesOnline() }
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
            .task {
                #if targetEnvironment(simulator)
                // Simulator-only layout QA. Keep the production discovery path
                // untouched and avoid privileged scans during UI screenshots.
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("-captureAdvancedSettings") {
                    showingAdvancedSettings = true
                } else if arguments.contains("-captureSortPopup") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        showingSortPopup = true
                    }
                } else if arguments.contains("-captureSelectionPopupSelected") {
                    // A fake selection exercises the conditional menu rows;
                    // only the simulator preview uses this placeholder ID.
                    selectedIDs.insert("simulator-preview-selection")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        showingSelectionPopup = true
                    }
                } else if arguments.contains("-captureSelectionPopup") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        showingSelectionPopup = true
                    }
                } else if arguments.contains("-captureMorePopup") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        showingMorePopup = true
                    }
                } else if arguments.contains("-captureToolbarHome") {
                    // No background discovery during a toolbar-only layout preview.
                } else {
                    model.loadApps()
                }
                #else
                model.loadApps()
                #endif
            }
        }
    }

    // The idle search prompt is its own centered control. TextField's intrinsic
    // width and caret padding cannot push this icon/text pair off-center.
    private var searchBar: some View {
        Group {
            if searchExpanded || !searchText.isEmpty {
                HStack(spacing: 6) {
                    searchIcon("magnifyingglass")
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
                        searchIcon("xmark.circle.fill")
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
                    HStack(spacing: 4) {
                        searchIcon("magnifyingglass")
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
                    HStack(spacing: 10) {
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
            HStack(alignment: .center, spacing: 4) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 16, height: 16, alignment: .center)
                    .accessibilityHidden(true)
                Text("有限清理模式")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundColor(Color(uiColor: .secondaryLabel))
            .textCase(nil)
        } footer: {
            Text("仅清理所选项目的 Caches/tmp；保留 Documents 和容器本身。")
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
            HStack(spacing: 8) {
                appSectionHeading("已识别名称", count: namedApps.count)
                if model.busy { ProgressView().controlSize(.mini) }
            }
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
                appSectionHeading("仅识别 Bundle ID", count: bundleIDOnlyApps.count,
                                  expanded: showingBundleIDOnly)
            }
            .buttonStyle(.plain)
        } footer: {
            if showingBundleIDOnly || !searchText.isEmpty {
                Text("这些项目有 Bundle ID，但系统未返回名称；可尝试联网补全。")
            }
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
                appSectionHeading("未识别数据容器", count: unidentifiedContainers.count,
                                  expanded: showingUnidentifiedContainers)
            }
            .buttonStyle(.plain)
        } footer: {
            if showingUnidentifiedContainers || !searchText.isEmpty {
                Text("UUID 不是 App 名称。无法确认归属时请勿清理。")
            }
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

    /// All app-category headings share one typography and color treatment.
    /// Collapsible categories add a chevron without changing the text style.
    private func appSectionHeading(_ title: String, count: Int? = nil,
                                   expanded: Bool? = nil) -> some View {
        HStack(spacing: 8) {
            Text(count.map { "\(title)（\($0)）" } ?? title)
            Spacer(minLength: 8)
            if let expanded {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundColor(Color(uiColor: .secondaryLabel))
        .textCase(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var signingWarning: some View {
        Section {
            HStack(spacing: 8) {
                settingsIcon("exclamationmark.triangle", color: .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("请确认 App Group")
                        .font(.subheadline.weight(.semibold))
                    Text("未确认前无法扫描或清理缓存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button("打开高级设置") { showingAdvancedSettings = true }
        }
    }

    private var advancedSettingsSheet: some View {
        NavigationStack {
            Form {
                Section("访问状态") {
                    HStack(spacing: 8) {
                        settingsIcon("checkmark.shield", color: .accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("缓存访问权限")
                                .font(.subheadline.weight(.medium))
                            Text(model.appGroupReady
                                 ? "已找到可访问的 App Group"
                                 : "当前签名没有可访问的 App Group")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(!model.appGroupReady ? "不可用" :
                             (model.groupConfirmed ? "已确认" : "待确认"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(model.groupConfirmed ? Color.green : Color.orange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background((model.groupConfirmed ? Color.green : Color.orange)
                                            .opacity(0.10), in: Capsule())
                    }
                    .padding(.vertical, 5)
                }

                Section {
                    if accessibleGroups.isEmpty {
                        HStack(spacing: 8) {
                            settingsIcon("exclamationmark.triangle", color: .orange)
                            Text("没有可选的 App Group")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("App Group", selection: $model.groupID) {
                            ForEach(accessibleGroups, id: \.self) { group in
                                Text(group).tag(group)
                            }
                        }
                        .font(.subheadline)
                        .disabled(model.busy)

                        Toggle("Cleaner", isOn: Binding(
                            get: { model.groupConfirmed },
                            set: { model.setGroupConfirmed($0) }
                        ))
                        .font(.subheadline)
                        .disabled(model.busy)
                    }
                } header: {
                    Text("App Group 设置")
                } footer: {
                    Text("只确认 Cleaner 独占的 App Group。清理时会临时替换该组缓存目录；共享组可能影响其他 App。")
                        .font(.footnote)
                }

                Section {
                    Button {
                        model.deepDiscoverApps()
                    } label: {
                        HStack(spacing: 8) {
                            settingsIcon("arrow.triangle.2.circlepath")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("深度发现 App 容器")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("按 inode 搜索 · 可能需要几分钟")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy)
                } header: {
                    Text("扫描工具")
                } footer: {
                    Text("首页已自动执行发现；此处用于重试，结果可能不完整。")
                }

                Section {
                    TextField("输入容器 UUID 或完整路径", text: $manualPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.subheadline.monospaced())
                    Button {
                        model.addManualPath(manualPath.trimmingCharacters(in: .whitespacesAndNewlines))
                        manualPath = ""
                    } label: {
                        HStack(spacing: 8) {
                            settingsIcon("plus.circle", color: .accentColor)
                            Text("添加 App 容器")
                                .font(.subheadline)
                        }
                    }
                    .disabled(manualPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                } header: {
                    Text("手动添加")
                } footer: {
                    Text("只添加来源明确的容器路径；添加后仍需扫描验证权限。")
                }

                Section {
                    DisclosureGroup(isExpanded: $showingDiagnostics) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("签名声明的 App Group")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text("\(model.grantedGroups.count) 个")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            if model.grantedGroups.isEmpty {
                                Text("当前签名未声明 App Group")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(model.grantedGroups, id: \.self) { group in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: accessibleGroups.contains(group)
                                              ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .font(.system(size: 15))
                                            .foregroundStyle(accessibleGroups.contains(group)
                                                             ? Color.green : Color.orange)
                                            .frame(width: 18, height: 18)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(group)
                                                .font(.caption.monospaced())
                                                .textSelection(.enabled)
                                            Text(accessibleGroups.contains(group)
                                                 ? "容器可访问" : "容器不可访问")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }

                            Text("扫描诊断日志")
                                .font(.caption.weight(.semibold))
                            Text(model.accessDiagnostics)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color(uiColor: .tertiarySystemGroupedBackground),
                                            in: RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack(spacing: 8) {
                            settingsIcon("doc.text.magnifyingglass")
                            Text("查看访问诊断日志")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                        }
                    }
                } header: {
                    Text("诊断信息")
                } footer: {
                    Text("日志用于排查权限问题；系统拒绝元数据访问时可能无法识别 App 名称。")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("高级设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showingAdvancedSettings = false }
                }
            }
        }
    }

    private func settingsIcon(_ name: String, color: Color = .primary) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 20, height: 20, alignment: .center)
            .accessibilityHidden(true)
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
        Button {
            showingSortPopup = false
            showingMorePopup = false
            showingSelectionPopup.toggle()
        } label: {
            toolbarIcon("checklist")
        }
        .accessibilityLabel("选择操作")
        .disabled(model.busy)
        .popover(isPresented: $showingSelectionPopup, attachmentAnchor: .rect(.bounds),
                 arrowEdge: .top) {
            compactPopup {
                compactPopupAction("全选当前列表", icon: "checkmark.circle") {
                    selectedIDs.formUnion(displayedApps.map(\.id))
                    showingSelectionPopup = false
                }
                if !selectedIDs.isEmpty {
                    compactPopupAction("取消全选", icon: "circle") {
                        selectedIDs.removeAll()
                        showingSelectionPopup = false
                    }
                    compactPopupAction("排除选中的 \(selectedIDs.count) 个 App", icon: "minus.circle") {
                        let paths = Set(model.apps.filter { selectedIDs.contains($0.id) }.map(\.path))
                        model.exclude(paths)
                        selectedIDs.removeAll()
                        showingSelectionPopup = false
                    }
                }
                compactPopupAction(model.excludedPaths.isEmpty
                                   ? "管理已排除 App"
                                   : "管理已排除 App（\(model.excludedPaths.count)）",
                                   icon: "list.bullet") {
                    showingSelectionPopup = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showingExcluded = true
                    }
                }
            }
        }
    }

    /// The native Menu reserves an OS-controlled icon column. Keep the left
    /// and right popovers on one compact set of optical layout metrics.
    private func compactPopup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(5)
        .frame(width: 250)
        .presentationCompactAdaptation(.popover)
    }

    private func compactPopupAction(_ title: String, icon: String,
                                    symbolVisible: Bool = true,
                                    enabled: Bool = true,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    // Normalize the *drawn bounds* of every symbol, not just
                    // the font point size; some glyphs (especially checkmark,
                    // magnifyingglass and gearshape) have oversized outlines.
                    .resizable()
                    .scaledToFit()
                    .frame(width: menuSymbolSize(icon), height: menuSymbolSize(icon))
                    .frame(width: 14, height: 14, alignment: .center)
                    .opacity(symbolVisible ? 1 : 0)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .frame(minHeight: 38)
            .padding(.horizontal, 10)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(CompactPopupButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private var sortMenu: some View {
        Button {
            showingSelectionPopup = false
            showingMorePopup = false
            showingSortPopup.toggle()
        } label: {
            toolbarIcon("arrow.up.arrow.down")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("排序")
        .disabled(model.busy)
        .popover(isPresented: $showingSortPopup, attachmentAnchor: .rect(.bounds),
                 arrowEdge: .top) {
            compactPopup {
                compactPopupAction("缓存从大到小", icon: "checkmark",
                                   symbolVisible: largestFirst) {
                    largestFirst = true
                    showingSortPopup = false
                }
                compactPopupAction("缓存从小到大", icon: "checkmark",
                                   symbolVisible: !largestFirst) {
                    largestFirst = false
                    showingSortPopup = false
                }
            }
        }
    }

    private func sizeText(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Font point size alone does not equalize SF Symbols' visual bounds.
    /// Scale each vector proportionally to the same 20pt optical bounding box.
    private func toolbarIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20, alignment: .center)
            .frame(width: 24, height: 24, alignment: .center)
            .accessibilityHidden(true)
    }

    /// 15pt Chinese menu labels have a smaller visible glyph box than their
    /// nominal font size. Keep every symbol within 11–12pt optical bounds.
    private func menuSymbolSize(_ symbol: String) -> CGFloat {
        switch symbol {
        case "checkmark", "magnifyingglass", "gearshape": return 11
        default: return 12
        }
    }

    private func searchIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .regular))
            .frame(width: 17, height: 17)
            .accessibilityHidden(true)
    }

    private func contentIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .regular))
            .frame(width: 22, height: 22, alignment: .center)
            .accessibilityHidden(true)
    }

    private func isInternalSystemService(_ bundleID: String) -> Bool {
        // These are system helper services, not independently launchable apps.
        // They stay hidden rather than being offered as cache-cleaning targets.
        Self.hiddenServiceIDs.contains(bundleID)
    }
}

private struct CompactPopupButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(uiColor: .tertiarySystemFill) : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
    }
}
