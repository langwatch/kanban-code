import SwiftUI
import KanbanCodeRemoteKit

/// The commands matching what is typed after `/`, over the chat composer:
/// the name, one line of description and where the command comes from.
struct SlashCommandList: View {
    let matches: [RemoteSlashCommand]
    var selectedIndex: Int = 0
    var onHover: (Int) -> Void = { _ in }
    let onSelect: (RemoteSlashCommand) -> Void

    static let rowHeight: CGFloat = 26
    static let visibleRows = 7

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.name) { index, command in
                        SlashCommandRow(command: command, isSelected: index == selectedIndex,
                                        onHover: { if $0 { onHover(index) } }) {
                            onSelect(command)
                        }
                        .id(command.name)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: min(CGFloat(matches.count), CGFloat(Self.visibleRows)) * Self.rowHeight + 8)
            .onChange(of: selectedIndex) { _, index in
                guard matches.indices.contains(index) else { return }
                proxy.scrollTo(matches[index].name)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .accessibilityIdentifier("slashCommandList")
    }
}

private struct SlashCommandRow: View {
    let command: RemoteSlashCommand
    let isSelected: Bool
    let onHover: (Bool) -> Void
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Text("/\(command.name)")
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .layoutPriority(2)
                Text(command.description)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
                Spacer(minLength: 4)
                if let label = command.sourceLabel {
                    Text(label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary.opacity(0.8))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: SlashCommandList.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { onHover($0) }
    }
}
