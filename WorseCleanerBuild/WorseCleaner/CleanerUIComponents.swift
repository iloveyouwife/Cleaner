import SwiftUI

/// Shared presentation rules for content rows. System text styles remain
/// dynamic; only stable icon columns and content spacing use point constants.
enum CleanerLayout {
    static let settingsIconColumn: CGFloat = 22
    static let settingsRowSpacing: CGFloat = 10
    static let listRowVerticalInset: CGFloat = 6
}

struct CleanerSettingsSymbol: View {
    let name: String
    var tint: Color = .primary

    var body: some View {
        Image(systemName: name)
            .font(.body.weight(.medium))
            .foregroundStyle(tint)
            .frame(width: CleanerLayout.settingsIconColumn,
                   height: CleanerLayout.settingsIconColumn)
            .accessibilityHidden(true)
    }
}

struct CleanerStatusPill: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.10), in: Capsule())
    }
}


struct CleanerSectionHeading: View {
    let title: String
    let count: Int?
    let expanded: Bool?

    init(_ title: String, count: Int? = nil, expanded: Bool? = nil) {
        self.title = title
        self.count = count
        self.expanded = expanded
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(count.map { "\(title)（\($0)）" } ?? title)
            Spacer(minLength: 8)
            if let expanded {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct CleanerEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)

            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }
}

struct CleanerAppRow: View {
    let app: WCTarget
    let usage: LimitedCleanerUsage?
    let selected: Bool
    let unidentified: Bool
    let disabled: Bool
    let onToggle: () -> Void

    private var displayTitle: String {
        unidentified ? "未知 App 数据容器" : app.name
    }

    private var detail: String {
        unidentified
            ? "UUID · " + URL(fileURLWithPath: app.path).lastPathComponent
            : app.bundleID
    }

    private var cacheSize: String {
        guard let usage else { return "未扫描" }
        return ByteCountFormatter.string(fromByteCount: usage.totalBytes, countStyle: .file)
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                Text(cacheSize)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(usage == nil ? .tertiary : .secondary)
                    .lineLimit(1)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, CleanerLayout.listRowVerticalInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayTitle + "，缓存 " + cacheSize)
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityHint("双击切换选择状态")
    }
}
