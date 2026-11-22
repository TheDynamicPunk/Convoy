import SwiftUI
import UniformTypeIdentifiers
import DownloadEngine

/// State for one capture's dialog.
///
/// The window asks no questions the capture can already answer: Chrome hands
/// over a size and a name for a download the person clicked, so those show at
/// once and the server is not contacted. Only a capture missing one of them
/// (a right-clicked link, say) triggers a probe, and the probe only ever fills
/// in what is missing; it never overwrites something the person typed.
///
/// For torrents: `.torrent` files parse locally and show their full file list
/// immediately; magnet links probe the swarm when the dialog opens so the
/// file list appears as soon as metadata arrives, while still allowing Start
/// before metadata finishes.
@MainActor
final class CaptureDialogModel: ObservableObject {
    let capture: CapturedDownload

    /// What the name field shows.
    @Published var filename: String
    /// A folder the person picked. Nil means automatic.
    @Published var folder: URL?
    @Published var dontAskAgain = false
    @Published private(set) var info: LinkInfo?
    @Published private(set) var isProbing = false

    // Torrent-specific state
    @Published private(set) var torrentFiles: [TorrentFileItem] = []
    @Published var selectedTorrentFiles: Set<Int> = []
    @Published var fileFilterText = ""
    @Published private(set) var torrentTotalSize: Int64?
    @Published private(set) var torrentInfoHashHex: String?
    /// Non-nil when the `.torrent` file or magnet URI itself is invalid and
    /// cannot be added. Disables both Start and Download Later.
    @Published private(set) var torrentFatalError: String?
    /// Non-nil when a magnet swarm probe failed or timed out. Shown as a note
    /// while still allowing the user to start now and choose files later.
    @Published private(set) var torrentProbeError: String?

    /// The last name this model put in the field itself (initially, or from
    /// the probe). Anything else in the field was typed by the person.
    private var autoName: String
    /// Parsed `.torrent` metadata (from a `.torrent` file or a completed magnet
    /// probe), forwarded to `TorrentAddRequest` so the engine doesn't re-probe.
    private var resolvedTorrent: TorrentFile?

    init(capture: CapturedDownload) {
        self.capture = capture
        let initial = capture.suggestedFilename ?? FilenameResolver.provisionalFilename(for: capture.url)
        self.filename = initial
        self.autoName = initial
        self.folder = capture.initialFolder

        if let torrent = capture.torrent {
            switch torrent {
            case .torrentFile(let data):
                if let preParsed = capture.parsedTorrent {
                    applyParsedTorrent(preParsed)
                } else {
                    do {
                        let parsed = try TorrentFile(data)
                        applyParsedTorrent(parsed)
                    } catch {
                        torrentFatalError = error.localizedDescription
                    }
                }
            case .magnet(let uri):
                if let parsed = try? MagnetURI(uri) {
                    torrentInfoHashHex = parsed.infoHash.hex
                } else {
                    torrentFatalError = "This magnet link is not valid."
                }
            }
        }
    }

    var nameWasEdited: Bool { filename != autoName }

    var hasDeselectedTorrentFiles: Bool {
        !torrentFiles.isEmpty && selectedTorrentFiles.count < torrentFiles.count
    }

    var canSubmit: Bool {
        if torrentFatalError != nil {
            return false
        }
        if capture.isTorrent && !torrentFiles.isEmpty && selectedTorrentFiles.isEmpty {
            return false
        }
        return true
    }

    private func applyParsedTorrent(_ parsed: TorrentFile) {
        resolvedTorrent = parsed
        torrentInfoHashHex = parsed.infoHash.hex
        torrentTotalSize = parsed.totalSize
        let items = TorrentFileItem.visibleItems(from: parsed.files)
        torrentFiles = items
        selectedTorrentFiles = Set(items.map(\.id))
        if !nameWasEdited, let safe = FilenameResolver.sanitize(parsed.name) {
            filename = safe
            autoName = safe
        }
    }

    /// Runs from the view's `.task`, so it is cancelled with the window.
    func probeIfNeeded() async {
        if let torrent = capture.torrent {
            guard case .magnet(let uri) = torrent, torrentFatalError == nil else { return }
            isProbing = true
            do {
                let parsed = try await DownloadManager.shared.probeMagnet(uri)
                guard !Task.isCancelled else { return }
                applyParsedTorrent(parsed)
            } catch {
                guard !Task.isCancelled else { return }
                torrentProbeError = error.localizedDescription
            }
            isProbing = false
            return
        }

        // Streams are manifests: a ranged GET of one says nothing about the
        // video. A capture that already has a size and a name has nothing to
        // ask the server.
        guard capture.stream == nil else { return }
        guard capture.expectedSize == nil || capture.suggestedFilename == nil else { return }

        isProbing = true
        let result = await LinkInfoProbe.fetch(url: capture.url, headers: capture.headers)
        isProbing = false
        guard !Task.isCancelled, let result else { return }
        info = result

        if capture.suggestedFilename == nil, !nameWasEdited, let better = result.suggestedFilename {
            filename = better
            autoName = better
        }
    }

    /// The size to show: the torrent's total size, the browser's measurement,
    /// or the server's.
    var size: Int64? { torrentTotalSize ?? capture.expectedSize ?? info?.size }

    /// Only what the person changed. An untouched name is left out so the
    /// engine can still improve it from Content-Disposition or torrent metadata;
    /// a typed one is final.
    func choices() -> CaptureChoices {
        var choices = CaptureChoices()
        if nameWasEdited, FilenameResolver.sanitize(filename) != nil {
            choices.filename = filename
        }
        choices.folder = folder
        if capture.isTorrent && !torrentFiles.isEmpty && selectedTorrentFiles.count < torrentFiles.count {
            choices.selectedTorrentFiles = selectedTorrentFiles
        }
        choices.resolvedTorrentMetadata = resolvedTorrent
        return choices
    }
}

/// The capture dialog's content, laid out like the download rows it is
/// about to become: the type icon, a semibold title, a line of metrics; then
/// the destination folder (and flat file list for torrents).
struct CaptureDialogView: View {
    let capture: CapturedDownload
    let waitingCount: Int
    let onDecision: (CaptureDecision) -> Void

    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var model: CaptureDialogModel
    @FocusState private var nameFocused: Bool

    init(capture: CapturedDownload, waitingCount: Int, onDecision: @escaping (CaptureDecision) -> Void) {
        self.capture = capture
        self.waitingCount = waitingCount
        self.onDecision = onDecision
        _model = StateObject(wrappedValue: CaptureDialogModel(capture: capture))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            // Label and menu on one line: the menu takes the rest of the row.
            HStack(spacing: 12) {
                Text("Save to")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                SaveFolderPicker(
                    folder: $model.folder,
                    automaticTitle: automaticTitle,
                    allowsAutomatic: !capture.isTorrent,
                    activatesAppForOpenPanel: true
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)

            if capture.isTorrent {
                torrentFileSection
            } else if model.info?.isWebPage == true {
                Label("This link opens a web page, not a file.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            footer
        }
        .padding(20)
        .frame(width: capture.isTorrent ? 500 : 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(escapeCatcher)
        .task { await model.probeIfNeeded() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            typeIcon

            VStack(alignment: .leading, spacing: 6) {
                // Editable in place with a clear field outline so it reads as
                // editable; Return submits using the default action (Start or
                // Download Later, matching the user's auto-start setting).
                TextField("File name", text: $model.filename)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                nameFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                                lineWidth: nameFocused ? 2 : 1
                            )
                    )
                    .onSubmit {
                        guard model.canSubmit else { return }
                        decide(startNow: settings.autoStartDownloads)
                    }

                HStack(spacing: 10) {
                    if capture.stream == nil {
                        sizeMetric
                        metricDivider
                    }
                    Text(kindText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    metricDivider
                    if capture.isTorrent, let hash = model.torrentInfoHashHex {
                        metric(String(hash.prefix(12)), symbol: "number")
                            .help(hash)
                    } else {
                        metric(sourceText, symbol: "globe")
                            .help(capture.url.absoluteString)
                    }
                }
                .padding(.leading, 8)
            }

            Spacer(minLength: 0)
        }
    }

    /// The download rows' type icon: a tinted rounded square with a symbol.
    /// Recomputes live as the user edits the filename extension.
    private var typeIcon: some View {
        if capture.isTorrent {
            return AnyView(
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(TorrentStyle.tint.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: TorrentStyle.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(TorrentStyle.tint)
                }
            )
        }
        let kind: FileKind = capture.stream != nil ? .video : FileKind(filename: model.filename)
        return AnyView(
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(kind.tint.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: kind.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(kind.tint)
            }
        )
    }

    /// Prefer the page the person clicked on over the CDN host serving the file.
    private var sourceText: String {
        capture.referrerURL?.host ?? capture.url.host ?? capture.url.absoluteString
    }

    @ViewBuilder
    private var sizeMetric: some View {
        if let size = model.size {
            metric(ByteFormat.size(size), symbol: "internaldrive")
        } else if model.isProbing {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(capture.isTorrent ? "Getting details\u{2026}" : "Checking\u{2026}")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
        } else {
            metric("Size unknown", symbol: "internaldrive")
        }
    }

    private func metric(_ text: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
    }

    private var metricDivider: some View {
        Text("|")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
    }

    private var kindText: String {
        if capture.isTorrent {
            let count = model.torrentFiles.count
            if count > 0 {
                return count == 1 ? "Torrent · 1 file" : "Torrent · \(count) files"
            }
            return "Torrent"
        }
        if let stream = capture.stream {
            return stream.streamType == "hls" ? "HLS stream" : "DASH stream"
        }
        let ext = (model.filename as NSString).pathExtension
        if !ext.isEmpty, let description = UTType(filenameExtension: ext)?.localizedDescription {
            return description.prefix(1).uppercased() + description.dropFirst()
        }
        if let mime = model.info?.mimeType,
           let description = UTType(mimeType: mime)?.localizedDescription {
            return description.prefix(1).uppercased() + description.dropFirst()
        }
        return ext.isEmpty ? "Unknown type" : "\(ext.uppercased()) file"
    }

    private var automaticTitle: String {
        let defaultFolder = SaveFolderPicker.defaultFolder(for: settings)
        let route = DownloadManager.shared.categoryRoute(
            filename: model.filename,
            matchName: capture.stream != nil ? CategoryRouting.streamMatchName(for: model.filename) : nil,
            hosts: CategoryRouter.hosts(from: [capture.url, capture.referrerURL]),
            folderIsExplicit: false
        )
        let target = (route?.category.folder ?? defaultFolder).standardizedFileURL
        return SaveFolderPicker.automaticTitle(for: target)
    }

    // MARK: - Torrent file list

    private var torrentFileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fatal = model.torrentFatalError {
                Label(fatal, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.torrentFiles.isEmpty {
                TorrentFileListView(
                    files: model.torrentFiles,
                    selected: $model.selectedTorrentFiles,
                    filterText: $model.fileFilterText,
                    maxListHeight: 200
                )

                if model.hasDeselectedTorrentFiles, let total = model.torrentTotalSize {
                    Text("Needs \(ByteFormat.size(total)) free on disk, even for files you skip.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if model.isProbing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to peers to fetch the file list\u{2026} You can start now and choose files afterwards.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            } else if let error = model.torrentProbeError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.torrentFatalError == nil {
                Text("Files appear in the folder as they download. Peers in the swarm can see your IP address.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if !capture.isTorrent {
                    Toggle("Don't ask again", isOn: $model.dontAskAgain)
                        .toggleStyle(.checkbox)
                        .help("Captured downloads will be added straight away. Turn the dialog back on in Settings \u{2192} General.")
                }
                if waitingCount > 0 {
                    Text("\(waitingCount) more waiting")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            actionButton("Download Later", isDefault: !settings.autoStartDownloads) {
                decide(startNow: false)
            }
            .disabled(!model.canSubmit)

            actionButton("Start Download", isDefault: settings.autoStartDownloads) {
                decide(startNow: true)
            }
            .disabled(!model.canSubmit)
        }
        .controlSize(.large)
    }

    /// Applies `.defaultAction` (Return) to whichever button matches the user's
    /// auto-start preference so pressing Return never contradicts Settings.
    private func actionButton(_ title: String, isDefault: Bool, action: @escaping () -> Void) -> some View {
        Group {
            if isDefault {
                Button(title, action: action).keyboardShortcut(.defaultAction)
            } else {
                Button(title, action: action)
            }
        }
    }

    /// Hidden button bound to Escape so pressing Esc dismisses the floating
    /// panel without adding a visible Cancel button beside the two actions.
    private var escapeCatcher: some View {
        Button("Close") { onDecision(.cancel) }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func decide(startNow: Bool) {
        let choices = model.choices()
        if let folder = choices.folder { RecentDownloadFolders.record(folder) }
        if model.dontAskAgain { settings.confirmCapturedDownloads = false }
        onDecision(startNow ? .start(choices) : .later(choices))
    }
}
