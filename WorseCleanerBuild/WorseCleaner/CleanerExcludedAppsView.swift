import SwiftUI

struct CleanerExcludedAppsView: View {
    @ObservedObject var model: WorseCleanerModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                let excluded = model.apps.filter { model.excludedPaths.contains($0.path) }
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
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name)
                                        .font(.body.weight(.medium))
                                        .lineLimit(2)
                                    Text(app.bundleID)
                                        .font(.footnote.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button("取消排除") { model.restoreExcluded([app.path]) }
                                    .font(.subheadline)
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)
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

}
