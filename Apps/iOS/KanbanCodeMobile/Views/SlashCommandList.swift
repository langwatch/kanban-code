import SwiftUI
import KanbanCodeRemoteKit

/// The commands matching what is typed after `/`, over the chat composer.
/// A tap completes the composer to `/name `.
struct SlashCommandList: View {
    let matches: [RemoteSlashCommand]
    let onSelect: (RemoteSlashCommand) -> Void

    private static let rowHeight: CGFloat = 46
    private static let visibleRows: CGFloat = 4.5

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(matches.enumerated()), id: \.element.name) { index, command in
                    if index > 0 {
                        Divider().padding(.leading, 14)
                    }
                    Button {
                        onSelect(command)
                    } label: {
                        row(command, best: index == 0)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("slash-\(command.name)")
                }
            }
        }
        .frame(height: min(CGFloat(matches.count), Self.visibleRows) * Self.rowHeight)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
        )
        .accessibilityIdentifier("slashCommandList")
    }

    private func row(_ command: RemoteSlashCommand, best: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("/\(command.name)")
                    .font(.subheadline.monospaced().weight(.medium))
                    .foregroundStyle(best ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let label = command.sourceLabel {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            Text(command.description.isEmpty ? " " : command.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
