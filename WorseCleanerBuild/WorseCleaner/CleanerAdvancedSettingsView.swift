import SwiftUI

/// Native grouped Form. Typography and symbols use the shared UI components.
struct CleanerAdvancedSettingsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var model: WorseCleanerModel
    @Binding var manualPath: String
    @Binding var showingDiagnostics: Bool
    @Binding var isPresented: Bool
    @ScaledMetric(relativeTo: .subheadline) private var diagnosticIconSize: CGFloat = 18

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
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 8) {
                                accessStatusLabel
                                accessStatusPill
                            }
                        } else {
                            HStack(spacing: CleanerLayout.settingsAccessorySpacing) {
                                accessStatusLabel
                                accessStatusPill
                            }
                        }
                    }
                    .padding(.vertical, 5)
                } header: {
                    CleanerSectionHeading("访问状态")
                }

                Section {
                    if accessibleGroups.isEmpty {
                        CleanerSettingsLabel(symbol: "exclamationmark.triangle",
                                             title: "没有可选的 App Group",
                                             tint: .orange,
                                             titleColor: .secondary,
                                             emphasized: false)
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
                        CleanerSettingsLabel(symbol: "arrow.triangle.2.circlepath",
                                             title: "深度发现 App 容器",
                                             subtitle: "按 inode 搜索 · 可能需要几分钟")
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
                        CleanerSettingsLabel(symbol: "plus.circle",
                                             title: "添加 App 容器",
                                             tint: .accentColor,
                                             emphasized: false)
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
                                            .font(.subheadline)
                                            .foregroundStyle(accessibleGroups.contains(group)
                                                             ? Color.green : Color.orange)
                                            .frame(width: diagnosticIconSize, height: diagnosticIconSize)
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
                        CleanerSettingsLabel(symbol: "doc.text.magnifyingglass",
                                             title: "查看访问诊断日志")
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

    private var accessStatusLabel: some View {
        CleanerSettingsLabel(
            symbol: "checkmark.shield",
            title: "缓存访问权限",
            subtitle: model.appGroupReady
                ? "已找到可访问的 App Group"
                : "当前签名没有可访问的 App Group",
            tint: .accentColor
        )
    }

    private var accessStatusPill: some View {
        CleanerStatusPill(
            title: !model.appGroupReady ? "不可用" :
                   (model.groupConfirmed ? "已确认" : "待确认"),
            tint: model.appGroupReady && model.groupConfirmed ? .green : .orange
        )
    }
}
