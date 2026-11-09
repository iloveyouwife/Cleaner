import SwiftUI

/// Shared presentation rules for content rows. System text styles remain
/// dynamic; only stable icon columns and content spacing use point constants.
enum CleanerLayout {
    static let settingsRowSpacing: CGFloat = 10
}

struct CleanerSettingsSymbol: View {
    let name: String
    var tint: Color = .primary
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 22

    var body: some View {
        Image(systemName: name)
            .font(.body.weight(.medium))
            .foregroundStyle(tint)
            .frame(width: iconSize,
                   height: iconSize)
            .accessibilityHidden(true)
    }
}

/// A single leading-icon/title layout for every Settings row. The symbol's
/// 22-point scaled slot follows the first text line, not the combined height
/// of a title and subtitle (which caused the v45 alignment regression).
struct CleanerSettingsLabel: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = .primary
    var titleColor: Color = .primary
    var emphasized: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: CleanerLayout.settingsRowSpacing) {
            CleanerSettingsSymbol(name: symbol, tint: tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(emphasized ? .body.weight(.medium) : .body)
                    .foregroundStyle(titleColor)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
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
    @ScaledMetric(relativeTo: .footnote) private var disclosureSize: CGFloat = 18
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
                    .frame(width: disclosureSize, height: disclosureSize)
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
    @ScaledMetric(relativeTo: .title3) private var symbolSize: CGFloat = 30
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: symbolSize, height: symbolSize)

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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title3) private var selectionSize: CGFloat = 26
    @ScaledMetric(relativeTo: .body) private var rowVerticalInset: CGFloat = 6
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

    private var cacheLabel: some View {
        Text(cacheSize)
            .font(.footnote.monospacedDigit())
            .foregroundStyle(usage == nil ? Color(uiColor: .tertiaryLabel) : Color.secondary)
            .lineLimit(1)
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
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .truncationMode(.middle)
                    if dynamicTypeSize.isAccessibilitySize {
                        cacheLabel
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                if !dynamicTypeSize.isAccessibilitySize {
                    cacheLabel
                }

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: selectionSize, height: selectionSize)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, rowVerticalInset)
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

/// Matches the v44 symbol at default text size, while scaling with Dynamic Type.
struct CleanerContentSymbol: View {
    let name: String
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 22

    var body: some View {
        Image(systemName: name)
            .font(.body.weight(.medium))
            .frame(width: iconSize, height: iconSize)
            .accessibilityHidden(true)
    }
}
