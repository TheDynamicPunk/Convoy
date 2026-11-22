import SwiftUI
import DownloadEngine

/// Sheet for choosing which files of an existing torrent task to download.
/// Works both while paused and at runtime while downloading.
struct TorrentFilesSheet: View {
    @ObservedObject var task: DownloadTask
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<Int>
    @State private var filterText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(task: DownloadTask) {
        self.task = task
        let initial = Set(
            task.torrentFiles.enumerated()
                .filter { !$0.element.isHiddenPadding && $0.element.isIncluded }
                .map(\.offset)
        )
        _selected = State(initialValue: initial)
    }

    private var visibleFiles: [TorrentFileItem] {
        TorrentFileItem.visibleItems(from: task.torrentFiles)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 36, height: 36)
                    Image(systemName: "checklist")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose Files")
                        .font(.system(size: 14, weight: .semibold))
                    Text(task.filename)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                TorrentFileListView(
                    files: visibleFiles,
                    selected: $selected,
                    filterText: $filterText,
                    maxListHeight: 260
                )

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { applySelection() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480)
    }

    private func applySelection() {
        guard !selected.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        let picks = selected
        Task {
            do {
                try await task.setSelectedTorrentFiles(picks)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
