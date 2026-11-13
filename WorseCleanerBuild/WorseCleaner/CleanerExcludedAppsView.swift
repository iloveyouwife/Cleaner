import SwiftUI

struct CleanerExcludedAppsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var model: WorseCleanerModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                let excluded = WCScanExclusions.managementTargets(
                    model.apps, excludedPaths: model.excludedPaths
                )
                if excluded.isEmpty {
                    Section {
                        CleanerEmptyState(
                            symbol: "checkmark.shield",
                            title: "暂无已排除 App",
                            message: "在首页选中 App 后，通过选择菜单将其排除。"
                        )
                    }
                } else {
                    Section("已排除 App（\(excluded.count)）") {
                        ForEach(excluded) { app in
                            if dynamicTypeSize.isAccessibilitySize {
                                VStack(alignment: .leading, spacing: 8) {
                                    excludedDetails(app)
                                    restoreButton(for: app)
                                }
                            } else {
                                HStack {
                                    excludedDetails(app)
                                    Spacer()
                                    restoreButton(for: app)
                                }
                            }
                        }
                    }
                }
                if !model.excludedPaths.isEmpty {
                    Section {
                        Button("全部恢复") {
                            model.restoreExcluded(model.excludedPaths)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("管理已排除 App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
            }
        }
    }

    private func excludedDetails(_ app: WCTarget) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(app.name)
                .font(.body.weight(.medium))
                .lineLimit(2)
            Text(app.bundleID)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .truncationMode(.middle)
        }
    }

    private func restoreButton(for app: WCTarget) -> some View {
        Button("取消排除") { model.restoreExcluded([app.path]) }
            .font(.subheadline)
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityLabel("取消排除 " + app.name)
    }

}
