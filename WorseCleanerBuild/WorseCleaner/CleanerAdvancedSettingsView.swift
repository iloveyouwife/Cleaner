import SwiftUI

/// Native grouped Form. Typography and symbols use the shared UI components.
struct CleanerAdvancedSettingsView: View {
    @ObservedObject var model: WorseCleanerModel
    @Binding var manualPath: String
    @Binding var showingDiagnostics: Bool
    @Binding var isPresented: Bool

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
            Form {
                Section {
                    HStack(spacing: CleanerLayout.settingsRowSpacing) {
                        settingsIcon("checkmark.shield", color: .accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("缓存访问权限")
                                .font(.body.weight(.medium))
                            Text(model.appGroupReady
                                 ? "已找到可访问的 App Group"
                                 : "当前签名没有可访问的 App Group")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        CleanerStatusPill(
                            title: !model.appGroupReady ? "不可用" :
                                   (model.groupConfirmed ? "已确认" : "待确认"),
                            tint: model.groupConfirmed ? .green : .orange
                        )
                    }
                    .padding(.vertical, 5)
                } header: {
                    CleanerSectionHeading("访问状态")
                }

                Section {
                    if accessibleGroups.isEmpty {
                        HStack(spacing: CleanerLayout.settingsRowSpacing) {
                            settingsIcon("exclamationmark.triangle", color: .orange)
                            Text("没有可选的 App Group")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("App Group", selection: $model.groupID) {
                            ForEach(accessibleGroups, id: \.self) { group in
                                Text(group).tag(group)
                            }
                        }
                        .disabled(model.busy)

                        Toggle("确认使用此 App Group", isOn: Binding(
                            get: { model.groupConfirmed },
                            set: { model.setGroupConfirmed($0) }
                        ))
                        .disabled(model.busy)
                    }
                } header: {
                    CleanerSectionHeading("App Group 设置")
                } footer: {
                    Text("只确认 Cleaner 独占的 App Group。清理时会临时替换该组缓存目录；共享组可能影响其他 App。")
                        .font(.footnote)
                }

                Section {
                    Button {
                        model.deepDiscoverApps()
                    } label: {
                        HStack(spacing: CleanerLayout.settingsRowSpacing) {
                            settingsIcon("arrow.triangle.2.circlepath")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("深度发现 App 容器")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("按 inode 搜索 · 可能需要几分钟")
                                    .font(.subheadline)
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
                    CleanerSectionHeading("扫描工具")
                } footer: {
                    Text("首页已自动执行发现；此处用于重试，结果可能不完整。")
                }

                Section {
                    TextField("输入容器 UUID 或完整路径", text: $manualPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Button {
                        model.addManualPath(manualPath.trimmingCharacters(in: .whitespacesAndNewlines))
                        manualPath = ""
                    } label: {
                        HStack(spacing: CleanerLayout.settingsRowSpacing) {
                            settingsIcon("plus.circle", color: .accentColor)
                            Text("添加 App 容器")
                                .font(.body)
                        }
                    }
                    .disabled(manualPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                } header: {
                    CleanerSectionHeading("手动添加")
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
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color(uiColor: .tertiarySystemGroupedBackground),
                                            in: RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack(spacing: CleanerLayout.settingsRowSpacing) {
                            settingsIcon("doc.text.magnifyingglass")
                            Text("查看访问诊断日志")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                    }
                } header: {
                    CleanerSectionHeading("诊断信息")
                } footer: {
                    Text("日志用于排查权限问题；系统拒绝元数据访问时可能无法识别 App 名称。")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("高级设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
            }
        }
    }

    private func settingsIcon(_ name: String, color: Color = .primary) -> some View {
        CleanerSettingsSymbol(name: name, tint: color)
    }

}
