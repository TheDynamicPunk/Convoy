import SwiftUI
import DownloadEngine

/// One selectable file inside a torrent, carrying its original engine file index
/// so BEP 47 padding entries can be filtered out without shifting `only_files`.
struct TorrentFileItem: Identifiable, Equatable {
    let id: Int
    let path: String
    let length: Int64

    static func visibleItems(from entries: [TorrentFile.Entry]) -> [TorrentFileItem] {
        entries.enumerated().compactMap { index, entry in
            guard !entry.isPadding else { return nil }
            return TorrentFileItem(id: index, path: entry.displayPath, length: entry.length)
        }
    }

    static func visibleItems(from files: [TorrentDetails.File]) -> [TorrentFileItem] {
        files.enumerated().compactMap { index, file in
            guard !file.isHiddenPadding else { return nil }
            return TorrentFileItem(id: index, path: file.displayPath, length: file.length)
        }
    }
}

/// Shared flat file picker with search filter, All/None buttons, and selection
/// summary used by both `CaptureDialogView` and `TorrentFilesSheet`.
struct TorrentFileListView: View {
    let files: [TorrentFileItem]
    @Binding var selected: Set<Int>
    @Binding var filterText: String
    var maxListHeight: CGFloat = 220

    private var filteredFiles: [TorrentFileItem] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return files }
        return files.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    private var filteredIDs: Set<Int> { Set(filteredFiles.map(\.id)) }

    private var filteredSelectedCount: Int {
        filteredFiles.reduce(0) { $0 + (selected.contains($1.id) ? 1 : 0) }
    }

    private var visibleSelectedCount: Int {
        files.reduce(0) { $0 + (selected.contains($1.id) ? 1 : 0) }
    }

    private var selectedBytes: Int64 {
        files
            .filter { selected.contains($0.id) }
            .reduce(0) { $0 + $1.length }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Filter files\u{2026}", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                Button("All") {
                    selected.formUnion(filteredIDs)
                }
                .controlSize(.small)
                .disabled(filteredFiles.isEmpty || filteredSelectedCount == filteredFiles.count)

                Button("None") {
                    selected.subtract(filteredIDs)
                }
                .controlSize(.small)
                .disabled(filteredSelectedCount == 0)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredFiles) { file in
                        HStack(spacing: 8) {
                            Toggle(isOn: Binding(
                                get: { selected.contains(file.id) },
                                set: { isOn in
                                    if isOn {
                                        selected.insert(file.id)
                                    } else {
                                        selected.remove(file.id)
                                    }
                                }
                            )) {
                                Text(file.path)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .toggleStyle(.checkbox)

                            Spacer(minLength: 8)

                            Text(ByteFormat.size(file.length))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: maxListHeight)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            Text("\(visibleSelectedCount) of \(files.count) selected (\(ByteFormat.size(selectedBytes)))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
