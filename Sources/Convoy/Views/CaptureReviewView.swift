import SwiftUI
import UniformTypeIdentifiers
import DownloadEngine

/// State for one capture's review window.
///
/// The window asks no questions the capture can already answer: Chrome hands
/// over a size and a name for a download the person clicked, so those show at
/// once and the server is not contacted. Only a capture missing one of them
/// (a right-clicked link, say) triggers a probe, and the probe only ever fills
/// in what is missing; it never overwrites something the person typed.
@MainActor
final class CaptureReviewModel: ObservableObject {
    let capture: CapturedDownload

    /// What the name field shows.
    @Published var filename: String
    /// A folder the person picked. Nil means automatic.
    @Published var folder: URL?
    @Published var dontAskAgain = false
    @Published private(set) var info: LinkInfo?
    @Published private(set) var isProbing = false

    /// The last name this model put in the field itself (initially, or from
    /// the probe). Anything else in the field was typed by the person.
    private var autoName: String

    init(capture: CapturedDownload) {
        self.capture = capture
        let initial = capture.suggestedFilename ?? FilenameResolver.provisionalFilename(for: capture.url)
        self.filename = initial
        self.autoName = initial
    }

    var nameWasEdited: Bool { filename != autoName }

    /// Runs from the view's `.task`, so it is cancelled with the window.
    func probeIfNeeded() async {
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

    /// The size to show: the browser's measurement if it made one, else the
    /// server's.
    var size: Int64? { capture.expectedSize ?? info?.size }

    /// Only what the person changed. An untouched name is left out so the
    /// engine can still improve it from Content-Disposition; a typed one is
    /// final.
    func choices() -> CaptureChoices {
        var choices = CaptureChoices()
        if nameWasEdited, FilenameResolver.sanitize(filename) != nil {
            choices.filename = filename
        }
        choices.folder = folder
        return choices
    }
}

/// The capture review window's content, laid out like the download rows it is
/// about to become: the type icon, a semibold title, a line of metrics; then
/// the two things worth deciding, the name and the folder, at one width.
struct CaptureReviewView: View {
    let capture: CapturedDownload
    let waitingCount: Int
    let onDecision: (CaptureDecision) -> Void

    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var model: CaptureReviewModel
    @FocusState private var nameFocused: Bool

    init(capture: CapturedDownload, waitingCount: Int, onDecision: @escaping (CaptureDecision) -> Void) {
        self.capture = capture
        self.waitingCount = waitingCount
        self.onDecision = onDecision
        _model = StateObject(wrappedValue: CaptureReviewModel(capture: capture))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            // Label and menu on one line: the menu takes the rest of the row.
            HStack(spacing: 12) {
                Text("Save to")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                CaptureFolderPicker(
                    folder: $model.folder,
                    filename: model.filename,
                    isStream: capture.stream != nil,
                    hosts: CategoryRouter.hosts(from: [capture.url, capture.referrerURL])
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)

            if model.info?.isWebPage == true {
                Label("This link opens a web page, not a file.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            footer
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(escapeCatcher)
        .task { await model.probeIfNeeded() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            typeIcon

            VStack(alignment: .leading, spacing: 6) {
                // The file's own name is the title, and it is the field: click
                // it to rename. It is drawn as a real text field (the system's
                // text background, a hairline edge, an accent edge while
                // typing) so it reads as editable; a bare tint did not.
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
                    .onSubmit { decide(startNow: settings.autoStartDownloads) }

                // Inset to line up with the typed name above. A stream has no
                // size to show until it has been downloaded, so it gets none.
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
                    metric(sourceText, symbol: "globe")
                        .help(capture.url.absoluteString)
                }
                .padding(.leading, 8)
            }

            Spacer(minLength: 0)
        }
    }

    /// The download rows' type icon: a tinted rounded square with a symbol.
    private var typeIcon: some View {
        let style = Self.typeStyle(forName: model.filename, isStream: capture.stream != nil)
        return ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(style.color.opacity(0.15))
                .frame(width: 40, height: 40)
            Image(systemName: style.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(style.color)
        }
    }

    private static func typeStyle(forName name: String, isStream: Bool) -> (symbol: String, color: Color) {
        if isStream { return ("film", .purple) }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return ("doc", .gray) }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return ("film", .purple) }
        if type.conforms(to: .audio) { return ("waveform", .pink) }
        if type.conforms(to: .image) { return ("photo", .green) }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return ("archivebox", .orange) }
        if type.conforms(to: .pdf) || type.conforms(to: .text)
            || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) {
            return ("doc.text", .blue)
        }
        return ("doc", .gray)
    }

    /// Where it came from: the page the person was on, else the file's host.
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
                Text("Checking\u{2026}").font(.system(size: 11))
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

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Don't ask again", isOn: $model.dontAskAgain)
                    .toggleStyle(.checkbox)
                    .help("Captured downloads will be added straight away. Turn the dialog back on in Settings \u{2192} General.")
                if waitingCount > 0 {
                    Text("\(waitingCount) more waiting")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            // Return triggers whichever matches "Start downloads
            // automatically": Start when it is on, adding without starting
            // when it is off, which is what that setting already meant.
            actionButton("Download Later", isDefault: !settings.autoStartDownloads) {
                decide(startNow: false)
            }
            actionButton("Start Download", isDefault: settings.autoStartDownloads) {
                decide(startNow: true)
            }
        }
        .controlSize(.large)
    }

    private func actionButton(_ title: String, isDefault: Bool, action: @escaping () -> Void) -> some View {
        Group {
            if isDefault {
                Button(title, action: action).keyboardShortcut(.defaultAction)
            } else {
                Button(title, action: action)
            }
        }
    }

    /// Escape closes the window (discarding the capture), as the red close
    /// button does. A zero-size button because a keyboard shortcut needs a
    /// button to belong to.
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

// MARK: - Save-to picker

private enum SaveFolderChoice: Hashable {
    case automatic
    case folder(URL)
    case other
}

/// The same menu as the Add Downloads window's "Save to": Automatic first
/// (only while download categories are in effect, previewing where this very
/// file would be filed), then the usual folders, the last few used, and
/// Other...
private struct CaptureFolderPicker: View {
    @Binding var folder: URL?
    let filename: String
    /// A native HLS/DASH capture. Its name has no extension yet (it is
    /// assembled into a video file at the end), so the preview must match
    /// extension rules the way the real add does; see `automaticTitle`.
    let isStream: Bool
    let hosts: [String]

    @ObservedObject private var settings = AppSettings.shared
    private let manager = DownloadManager.shared
    @State private var recent = RecentDownloadFolders.load()

    var body: some View {
        Picker("Save to", selection: Binding<SaveFolderChoice>(
            get: {
                if let folder { return .folder(folder.standardizedFileURL) }
                return manager.sortingIsActive ? .automatic : .folder(defaultFolder.standardizedFileURL)
            },
            set: { choice in
                switch choice {
                case .automatic:
                    folder = nil
                case .folder(let url):
                    folder = url
                case .other:
                    // After the menu's fade-out, as in AddDownloadsView:
                    // opened any sooner, the panel froze the half-faded menu.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        chooseOther()
                    }
                }
            }
        )) {
            if manager.sortingIsActive {
                Label(automaticTitle, systemImage: "folder.badge.gearshape")
                    .tag(SaveFolderChoice.automatic)
                Divider()
            }
            ForEach(standardFolders, id: \.self) { row($0) }
            let recents = recentChoices
            if !recents.isEmpty {
                Divider()
                Text("Recent").disabled(true)
                ForEach(recents, id: \.self) { row($0) }
            }
            Divider()
            Text("Other\u{2026}").tag(SaveFolderChoice.other)
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private func row(_ url: URL) -> some View {
        Label(FileManager.default.displayName(atPath: url.path), systemImage: "folder")
            .tag(SaveFolderChoice.folder(url))
    }

    private var defaultFolder: URL {
        URL(fileURLWithPath: settings.downloadDirectory, isDirectory: true)
    }

    /// "Automatic (Videos)": the folder a category would give this file by its
    /// current name, from the same call the real add makes.
    ///
    /// A stream is matched as if named `.mp4`, exactly as
    /// `DownloadManager.addStreamDownload` does. Without that, the preview
    /// saw an extensionless name, matched no category and promised the
    /// default folder, while the real add then filed the video into Videos.
    private var automaticTitle: String {
        let route = manager.categoryRoute(
            filename: filename,
            matchName: isStream ? CategoryRouting.streamMatchName(for: filename) : nil,
            hosts: hosts,
            folderIsExplicit: false
        )
        let target = (route?.category.folder ?? defaultFolder).standardizedFileURL
        return "Automatic (\(FileManager.default.displayName(atPath: target.path)))"
    }

    private var standardFolders: [URL] {
        let fm = FileManager.default
        let candidates = [defaultFolder]
            + fm.urls(for: .downloadsDirectory, in: .userDomainMask)
            + fm.urls(for: .desktopDirectory, in: .userDomainMask)
        return candidates.map(\.standardizedFileURL).reduce(into: []) { result, url in
            if !result.contains(url) { result.append(url) }
        }
    }

    /// Recently used folders, plus one just picked through Other... so the
    /// menu can show it as selected.
    private var recentChoices: [URL] {
        let standard = standardFolders
        var folders = recent
        if let folder, !folders.contains(folder.standardizedFileURL) {
            folders.insert(folder.standardizedFileURL, at: 0)
        }
        return folders.filter { !standard.contains($0) }
    }

    private func chooseOther() {
        // The review window never activates Convoy, but an open panel needs
        // the app active to be reliably in front. The person has just
        // clicked in this app, which is when macOS honours the request.
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
        }
    }
}
