import SwiftUI
import UIKit

// 3105 CleanerView's layout: search, summary, sortable/selectable app rows,
// selection menu, bulk action, and confirmation. The backend is worse_query.
struct ContentView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let hiddenServiceIDs: Set<String> = [
        "com.apple.GameOverlayUI", "com.apple.HeadphoneProxService",
        "com.apple.PassbookUIService", "com.apple.PDUIApp",
        "com.apple.SIMSetupUIService", "com.apple.webapp"
    ]

    @StateObject private var model = WorseCleanerModel()
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var searchCollapse: CGFloat = 0
    @State private var listNearTop = true
    @State private var searchDragStartCollapse: CGFloat?
    @State private var searchDragStartTranslation: CGFloat?
    @FocusState private var searchFieldFocused: Bool
    @State private var appliedSearchText = ""
    @State private var orderedApps: [WCTarget] = []
    @State private var searchSections = SearchSections()
    @State private var largestFirst = true
    @State private var selectedIDs = Set<String>()
    @State private var manualPath = ""
    @State private var confirmingClean = false
    @State private var showingDiagnostics = false
    @State private var showingRunDetails = false
    @State private var showingAdvancedSettings = false
    @State private var showingExcluded = false
    @State private var confirmingOnlineNames = false
    @State private var showingBundleIDOnly = false
    @State private var showingUnidentifiedContainers = false
    @State private var deviceStorage: CleanerDeviceStorage?
    @State private var deviceStorageRefreshRevision = 0
    @ScaledMetric(relativeTo: .body) private var progressSize: CGFloat = 22
    @ScaledMetric(relativeTo: .footnote) private var shieldSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var searchBarHeight: CGFloat = 42

    // v71 timing and visual behavior, but now applied to a persistent
    // search control outside the list's dynamic Section headers.
    private var searchAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.28)
    }

    // The header follows finger displacement in small, clamped increments.
    // Do not feed List.contentOffset straight back into this height: changing
    // the sibling header changes List's geometry and can cause visible jumps.
    // Its TextField remains mounted even when the header is fully clipped.
    private var searchFullHeight: CGFloat { searchBarHeight + 28 }
    private var searchHeaderHeight: CGFloat {
        max(0, searchFullHeight - searchCollapse)
    }

    private func trackSearchDrag(_ value: DragGesture.Value) {
        let vertical = value.translation.height
        guard abs(vertical) > abs(value.translation.width) else { return }
        // While scrolled deep into the App list, don't reveal a detached
        // search drawer. Allow the same downward gesture to reveal it only
        // after the List reaches its top.
        if vertical > 0 && !listNearTop && searchCollapse > 0 { return }

        if searchDragStartTranslation == nil {
            searchDragStartTranslation = vertical
            searchDragStartCollapse = searchCollapse
        }
        let distance = vertical - (searchDragStartTranslation ?? vertical)
        // Use a gentler response than a 1:1 fling. A fast swipe no longer
        // jumps 70pt based on a single coarse contentOffset notification.
        let target = (searchDragStartCollapse ?? searchCollapse) - distance * 0.7
        let clamped = min(searchFullHeight, max(0, target))
        if abs(searchCollapse - clamped) > 0.25 {
            searchCollapse = clamped
        }
    }

    private func finishSearchDrag(_ value: DragGesture.Value) {
        searchDragStartCollapse = nil
        searchDragStartTranslation = nil
        let delta = value.translation
        guard abs(delta.height) > 28, abs(delta.height) > abs(delta.width) else { return }
        // Keep v71 behavior of ending an active keyboard session on swipes.
        if searchPresented { setSearchPresented(false) }
        // Only settle the remaining partial distance, with a short ease-out.
        // Never switch visibility abruptly on gesture completion.
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
            searchCollapse = searchCollapse >= searchFullHeight * 0.5
                ? searchFullHeight : 0
        }
    }

    private func setSearchPresented(_ presented: Bool, clearQuery: Bool = false) {
        if presented && searchPresented && searchFieldFocused && !clearQuery {
            return
        }
        withAnimation(searchAnimation) {
            searchPresented = presented
            if presented || clearQuery { searchFieldFocused = presented }
            if clearQuery { searchText = "" }
        }
        if !presented && !clearQuery {
            DispatchQueue.main.async {
                if !searchPresented { searchFieldFocused = false }
            }
        }
    }

    private struct SearchSections {
        var named: [WCTarget] = []
        var bundleIDOnly: [WCTarget] = []
        var unidentified: [WCTarget] = []
    }

    // Keep this sort out of SwiftUI's per-keystroke body evaluation.
    // Scanning may update progress hundreds of times; neither progress nor a
    // text-field edit should cause multiple copies of the full list to sort.
    private func rebuildOrderedApps() {
        orderedApps = model.apps.filter {
            !model.excludedPaths.contains($0.path) &&
                !isInternalSystemService($0.bundleID)
        }.sorted { lhs, rhs in
            let a = model.usage[lhs.id]?.totalBytes ?? -1
            let b = model.usage[rhs.id]?.totalBytes ?? -1
            if a != b { return largestFirst ? a > b : a < b }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        rebuildSearchResults()
    }

    private func rebuildSearchResults() {
        let query = appliedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections = SearchSections()
        for app in orderedApps {
            if !query.isEmpty &&
                !app.name.localizedCaseInsensitiveContains(query) &&
                !app.bundleID.localizedCaseInsensitiveContains(query) &&
                !app.path.localizedCaseInsensitiveContains(query) {
                continue
            }
            if isUnknownContainer(app) {
                sections.unidentified.append(app)
            } else if app.name == app.bundleID {
                sections.bundleIDOnly.append(app)
            } else {
                sections.named.append(app)
            }
        }
        searchSections = sections
    }

    // A data-container UUID is not an App identifier. Keep these entries
    // separate from apps with a verifiable Bundle ID or display name.
    private var namedApps: [WCTarget] {
        searchSections.named
    }

    private var bundleIDOnlyApps: [WCTarget] {
        searchSections.bundleIDOnly
    }

    private var unidentifiedContainers: [WCTarget] {
        searchSections.unidentified
    }

    // Bulk selection follows the explicit expansion state of the two optional
    // groups. Search may reveal matches without expanding a group, but that
    // alone must not silently include the group in "全选".
    private var bulkSelectableApps: [WCTarget] {
        namedApps + (showingBundleIDOnly ? bundleIDOnlyApps : [])
            + (showingUnidentifiedContainers ? unidentifiedContainers : [])
    }

    private var allBulkSelectable: Bool {
        !bulkSelectableApps.isEmpty && bulkSelectableApps.allSatisfy {
            selectedIDs.contains($0.id)
        }
    }

    private func toggleBulkSelection() {
        if allBulkSelectable {
            selectedIDs.removeAll()
        } else {
            selectedIDs.formUnion(bulkSelectableApps.map(\.id))
        }
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Never put this first responder in a List Section header:
                // dynamic result rows must not detach/recreate its keyboard.
                // Keep v71 search shape, active shrink animation and cancel.
                animatedSearchBar
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 10)
                    .frame(height: searchHeaderHeight, alignment: .top)
                    .clipped()
                    .allowsHitTesting(searchHeaderHeight > 20)
                    .accessibilityHidden(searchHeaderHeight <= 1)
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
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                    .truncationMode(.tail)
                            }
                        }
                    } header: {
                        appSectionHeading("运行结果")
                    }
                }
                .listStyle(.insetGrouped)
                // Match the gentle blur under the floating top toolbar in
                // the reference recording. Use the system's native SOFT
                // scroll-edge treatment, not a custom glass overlay or an
                // extra opaque/hard separator strip. Keep the List's native
                // scrolling and the persistent search responder unchanged.
                .scrollEdgeEffectStyle(.soft, for: .top)
                .contentMargins(.top, 0, for: .scrollContent)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    // Observe only whether the list has returned near top.
                    // Unlike a raw CGFloat offset, a Bool avoids constantly
                    // rebuilding the whole List while its header collapses.
                    geometry.contentOffset.y + geometry.contentInsets.top < 10
                } action: { _, atTop in
                    listNearTop = atTop
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { _ in
                        // All List taps are outside the persistent search bar.
                        // Dismiss editing without clearing the current filter.
                        if searchPresented { setSearchPresented(false) }
                    }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in trackSearchDrag(value) }
                        .onEnded { value in finishSearchDrag(value) }
                )
                .task(id: searchText) {
                // The keyboard remains responsive; filter once after a brief
                // typing pause, instead of rebuilding every list on each key.
                if !searchText.isEmpty {
                    try? await Task.sleep(nanoseconds: 160_000_000)
                    guard !Task.isCancelled else { return }
                }
                appliedSearchText = searchText
                rebuildSearchResults()
            }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("App 缓存清理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    selectionMenu
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    sortMenu
                    Button {
                        refreshDeviceStorage()
                        model.loadApps()
                    } label: {
                        CleanerToolbarSymbol(name: "arrow.clockwise")
                    }
                    .disabled(model.busy)
                    .accessibilityLabel("刷新 App 列表")
                    Menu {
                        Button {
                            confirmingOnlineNames = true
                        } label: {
                            Label("补全 App 名称", systemImage: "magnifyingglass.circle")
                        }
                        .disabled(model.busy)
                        Button {
                            showingAdvancedSettings = true
                        } label: {
                            Label("高级设置", systemImage: "gearshape.circle")
                        }
                    } label: {
                        CleanerToolbarSymbol(name: "ellipsis.circle")
                    }
                    .menuOrder(.fixed)
                    .accessibilityLabel("更多选项")
                }
            }
            .sheet(isPresented: $showingAdvancedSettings) {
                CleanerAdvancedSettingsView(
                    model: model,
                    manualPath: $manualPath,
                    showingDiagnostics: $showingDiagnostics,
                    isPresented: $showingAdvancedSettings
                )
            }
            .sheet(isPresented: $showingExcluded) {
                CleanerExcludedAppsView(model: model, isPresented: $showingExcluded)
            }
            .confirmationDialog("补全App名称", isPresented: $confirmingOnlineNames,
                                titleVisibility: .visible) {
                Button("补全App名称") { model.completeMissingNamesOnline() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将向 Apple 商店发送未识别的 Bundle ID 查询名称，不上传缓存文件。每次最多 80 个。仅适用于已知 Bundle ID 的项目。")
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
                rebuildOrderedApps()
            }
            .onChange(of: model.excludedPaths) { _, _ in rebuildOrderedApps() }
            .onChange(of: largestFirst) { _, _ in rebuildOrderedApps() }
            .onChange(of: availableSize) { _, _ in rebuildOrderedApps() }
            .onChange(of: model.busy) { _, busy in
                if !busy {
                    rebuildOrderedApps()
                    refreshDeviceStorage()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshDeviceStorage() }
            }
            .task {
                rebuildOrderedApps()
                refreshDeviceStorage()
                #if targetEnvironment(simulator)
                // Simulator-only layout QA. Keep the production discovery path
                // untouched and avoid privileged scans during UI screenshots.
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("-captureLongRows") {
                    CleanerScreenshotFixtures.install(into: model, longNamesOnly: true)
                } else if arguments.contains(where: { $0.hasPrefix("-capturePopulated") }) {
                    CleanerScreenshotFixtures.install(into: model)
                    if arguments.contains("-capturePopulatedSelection") {
                        selectedIDs = Set(model.apps.prefix(2).map(\.id))
                    }
                } else if arguments.contains("-captureAdvancedSettings") {
                    showingAdvancedSettings = true
                } else if arguments.contains("-captureExcludedApps") {
                    showingExcluded = true
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

    // The exact v71 active/inactive search animation and round close control,
    // kept as a sibling of List so results never recreate the text responder.
    private var animatedSearchBar: some View {
        HStack(spacing: searchPresented ? 8 : 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color(uiColor: .label))
                    .accessibilityHidden(true)

                TextField("搜索 App", text: $searchText)
                    .font(.body)
                    .foregroundStyle(Color(uiColor: .label))
                    .focused($searchFieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityLabel("搜索 App")

                if !searchText.isEmpty {
                    Button {
                        // Clear without resetting focus or swapping the field.
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .frame(width: 25, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索文字")
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: searchBarHeight)
            .background {
                ZStack {
                    Capsule()
                        .fill(Color(uiColor: .tertiarySystemFill))
                        .opacity(searchPresented ? 0 : 1)
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular, in: Capsule())
                        .opacity(searchPresented ? 1 : 0)
                }
            }
            .contentShape(Capsule())
            .simultaneousGesture(
                TapGesture().onEnded {
                    if !searchPresented { setSearchPresented(true) }
                }
            )

            Button {
                setSearchPresented(false, clearQuery: true)
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.medium))
                    .frame(width: searchBarHeight, height: searchBarHeight)
                    .glassEffect(.regular, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭搜索")
            .frame(width: searchPresented ? searchBarHeight : 0, alignment: .leading)
            .offset(x: searchPresented ? 0 : searchBarHeight + 8)
            .opacity(searchPresented ? 1 : 0)
            .allowsHitTesting(searchPresented)
            .accessibilityHidden(!searchPresented)
        }
        .frame(height: searchBarHeight)
        .animation(searchAnimation, value: searchPresented)
    }

    private var summarySection: some View {
        Section {
            VStack(spacing: 14) {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 12) {
                            scannedCacheMetric
                            selectedCacheMetric
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            scannedCacheMetric
                            Spacer(minLength: 8)
                            selectedCacheMetric
                        }
                    }
                }
                .padding(.top, 4)

                storageCapacityRow

                Divider()

                Button {
                    model.scanAll()
                } label: {
                    HStack(spacing: 10) {
                        if model.busy {
                            ProgressView().frame(width: progressSize, height: progressSize)
                        } else {
                            contentIcon("arrow.triangle.2.circlepath")
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.busy ? "扫描中 · \(model.scannedAppCount) / \(model.apps.count)" : "重新扫描缓存")
                                .font(.subheadline.weight(.semibold))
                            Text("\(model.apps.count) 个数据容器 · 仅检查 Caches / tmp")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    .font(.footnote.weight(.semibold))
                    .frame(width: shieldSize, height: shieldSize, alignment: .center)
                    .accessibilityHidden(true)
                Text("有限清理模式")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundColor(Color(uiColor: .secondaryLabel))
            .textCase(nil)
        } footer: {
            Text("仅清理所选项目的 Caches/tmp，保留 Documents 和容器本身。")
        }
    }

    private var scannedCacheMetric: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("已扫描缓存")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(sizeText(availableSize))
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()
        }
    }

    private var selectedCacheMetric: some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing,
               spacing: 4) {
            Text("已选择 \(selectedIDs.count) 项")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(sizeText(selectedSize))
                .font(.headline.monospacedDigit())
        }
    }

    private var storageCapacityRow: some View {
        LabeledContent {
            if let deviceStorage {
                Text("可用 \(sizeText(deviceStorage.available)) / 总计 \(sizeText(deviceStorage.total))")
            } else {
                Text("容量读取中…")
            }
        } label: {
            Text("本机储存")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private func refreshDeviceStorage() {
        deviceStorageRefreshRevision += 1
        let revision = deviceStorageRefreshRevision
        Task {
            let latest = await Task.detached(priority: .utility) {
                CleanerDeviceStorage.read()
            }.value
            guard revision == deviceStorageRefreshRevision else { return }
            deviceStorage = latest
        }
    }

    private var applicationSection: some View {
        Section {
            if namedApps.isEmpty {
                CleanerEmptyState(
                    symbol: "square.stack.3d.up",
                    title: "目前没有已识别名称的 App",
                    message: "仅识别包名或容器编号的项目位于下方的独立分组。"
                )
            } else {
                ForEach(namedApps) { app in
                    appRow(app)
                }
            }
        } header: {
            HStack(spacing: 8) {
                appSectionHeading("已识别名称", count: namedApps.count)
                if model.busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Button(action: toggleBulkSelection) {
                        Text(allBulkSelectable ? "取消全选" : "全选")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color(uiColor: .label).opacity(0.58))
                            .textCase(nil)
                    }
                    .buttonStyle(.plain)
                    .disabled(bulkSelectableApps.isEmpty)
                    .accessibilityHint("切换当前展开分组中可见 App 的选择状态")
                }
            }
        }
    }

    private var bundleIDOnlySection: some View {
        Section {
            if showingBundleIDOnly || !appliedSearchText.isEmpty {
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
            .accessibilityValue(showingBundleIDOnly ? "已展开" : "已折叠")
            .accessibilityHint(showingBundleIDOnly ? "双击收起此分组" : "双击展开此分组")
        } footer: {
            if showingBundleIDOnly || !appliedSearchText.isEmpty {
                Text("这些项目有 Bundle ID，但系统未返回名称，可尝试联网补全。")
            }
        }
    }

    private var unidentifiedContainerSection: some View {
        Section {
            if showingUnidentifiedContainers || !appliedSearchText.isEmpty {
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
            .accessibilityValue(showingUnidentifiedContainers ? "已展开" : "已折叠")
            .accessibilityHint(showingUnidentifiedContainers ? "双击收起此分组" : "双击展开此分组")
        } footer: {
            if showingUnidentifiedContainers || !appliedSearchText.isEmpty {
                Text("UUID 不是 App 名称。无法确认归属时请勿清理。")
            }
        }
    }

    private func appRow(_ app: WCTarget, unidentified: Bool = false) -> some View {
        CleanerAppRow(
            app: app,
            usage: model.usage[app.id],
            selected: selectedIDs.contains(app.id),
            unidentified: unidentified,
            disabled: model.busy
        ) {
            if selectedIDs.contains(app.id) {
                selectedIDs.remove(app.id)
            } else {
                selectedIDs.insert(app.id)
            }
        }
    }

    private func appSectionHeading(_ title: String, count: Int? = nil,
                                   expanded: Bool? = nil) -> some View {
        CleanerSectionHeading(title, count: count, expanded: expanded)
    }

    private var signingWarning: some View {
        Section {
            CleanerSettingsLabel(symbol: "exclamationmark.triangle",
                                 title: "请确认 App Group",
                                 subtitle: "未确认前无法扫描或清理缓存。",
                                 tint: .orange)
            Button("打开高级设置") { showingAdvancedSettings = true }
        }
    }

    private var selectionMenu: some View {
        Menu {
            if !selectedIDs.isEmpty {
                Button {
                    let paths = Set(model.apps.filter { selectedIDs.contains($0.id) }.map(\.path))
                    model.exclude(paths)
                    selectedIDs.removeAll()
                } label: {
                    Label("排除选中的 \(selectedIDs.count) 个 App", systemImage: "minus.circle")
                }
            }
            Button {
                showingExcluded = true
            } label: {
                Label(model.excludedPaths.isEmpty
                      ? "管理已排除 App"
                      : "管理已排除 App（\(model.excludedPaths.count)）",
                      systemImage: "hand.raised.circle")
            }
        } label: {
            CleanerToolbarSymbol(name: "checklist")
        }
        .menuOrder(.fixed)
        .accessibilityLabel("选择操作")
        .disabled(model.busy)
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序方式", selection: $largestFirst) {
                Label("缓存从大到小", systemImage: "arrow.down.circle").tag(true)
                Label("缓存从小到大", systemImage: "arrow.up.circle").tag(false)
            }
        } label: {
            CleanerToolbarSymbol(name: "arrow.up.arrow.down")
        }
        .menuOrder(.fixed)
        .accessibilityLabel("排序")
        .disabled(model.busy)
    }

    private func sizeText(_ bytes: Int64) -> String {
        CleanerSizeText.bytes(bytes)
    }

    private func contentIcon(_ symbol: String) -> some View {
        CleanerContentSymbol(name: symbol)
    }

    private func isInternalSystemService(_ bundleID: String) -> Bool {
        // These are system helper services, not independently launchable apps.
        // They stay hidden rather than being offered as cache-cleaning targets.
        Self.hiddenServiceIDs.contains(bundleID)
    }
}

private struct CleanerDeviceStorage: Sendable {
    let available: Int64
    let total: Int64

    static func read() -> Self? {
        let home = NSHomeDirectory()
        let url = URL(fileURLWithPath: home, isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        if let values = try? url.resourceValues(forKeys: keys),
           let total = values.volumeTotalCapacity.map(Int64.init),
           let available = values.volumeAvailableCapacityForImportantUsage
                ?? values.volumeAvailableCapacity.map(Int64.init),
           total > 0, available >= 0 {
            return Self(available: available, total: total)
        }

        // Compatibility fallback when a resource capacity key is unavailable.
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: home),
              let total = (attributes[.systemSize] as? NSNumber)?.int64Value,
              let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
              total > 0, available >= 0 else { return nil }
        return Self(available: available, total: total)
    }
}

