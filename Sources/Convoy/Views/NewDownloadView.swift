import SwiftUI
import UniformTypeIdentifiers
import DownloadEngine
import os

/// Shared by the views involved in the extension → app YouTube hand-off, so
/// the whole path can be followed with:
///   log stream --predicate 'subsystem == "Convoy"' --level info
private let logger = Logger(subsystem: "Convoy", category: "AddDownloads")

/// Carries the measured height of the sheet's scrollable content up to the
/// frame that sizes the window.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum FolderChoice: Hashable {
    case folder(URL)
    case other
}

/// The last few folders downloads were saved to, newest first. Kept in
/// UserDefaults like the other settings; folders that no longer exist drop
/// out when read.
private enum RecentDownloadFolders {
    private static let key = "recentDownloadFolders"
    private static let limit = 3

    static func load() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    static func record(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        let paths = [path] + load().map(\.path).filter { $0 != path }
        UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: key)
    }
}

struct AddDownloadsView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var inputText = ""
    @State private var destination: URL?
    @State private var isChoosingFolder = false
    @State private var recentFolders = RecentDownloadFolders.load()
    @FocusState private var isURLFieldFocused: Bool
    @State private var segmentCount = 8
    @State private var isLoading = false
    @State private var errorMessage = ""
    
    // Parsed URLs state
    @State private var validURLs: [URL] = []

    /// Height the scrollable content reports it wants, and the fixed chrome
    /// (header + two dividers + footer) added on top of it.
    /// Seeded near the common case so the sheet opens at roughly the right
    /// size and settles, rather than springing up from the minimum on every
    /// presentation.
    @State private var measuredContentHeight: CGFloat = 330
    @State private var hasMeasuredContent = false
    /// Header (22 + 44 + 18) + footer (24 + ~22 + 24) + two dividers.
    private let chromeHeight: CGFloat = 156
    
    // YouTube quality picker state (for single YouTube URL)
    @State private var youtubeTitle: String?
    @State private var youtubeDuration: Double?
    @State private var youtubeThumbnailURL: URL?
    @State private var youtubeOptions: [YouTubeFormatOption] = []
    /// The last resolve, for its merge-audio lookup and audio tracks.
    @State private var youtubeInfo: YouTubeVideoInfo?
    @State private var selectedFormatID: String?
    /// Only meaningful on a video with dubbed audio; nil otherwise.
    @State private var selectedAudioLanguage: String?
    @State private var isFetchingFormats = false
    @State private var formatsFetchError: String?

    /// The URL to pre-fill when opened via the browser extension's YouTube
    /// download button (convoy://add?url=..., see ContentView's
    /// .openYouTubeDownload handler) rather than the toolbar's blank
    /// "+ New Download".
    ///
    /// Held as a plain `let` and applied in `.onAppear` — deliberately NOT via
    /// `_inputText = State(initialValue:)`. SwiftUI only honours a `@State`
    /// initial value the first time that storage is created for a given view
    /// identity; a sheet presented a second time at the same position can reuse
    /// the existing storage, in which case the initial value is silently
    /// discarded and the field comes up empty. Assigning in `.onAppear` is an
    /// ordinary mutation, so it always takes effect.
    private let initialURL: String?

    init(initialURL: String? = nil) {
        self.initialURL = initialURL
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: sectionGap) {
                    urlInputSection

                    if isSingleYouTubeURL {
                        youtubeQualitySection
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity
                            ))
                    }

                    optionsSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                // Measure what the content actually wants, so the sheet can be
                // that tall instead of a hardcoded guess.
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider()

            footerView
        }
        // Height follows the content rather than two hardcoded values.
        //
        // It was `isSingleYouTubeURL ? 540 : 480`, which meant pasting a
        // YouTube link made the whole window jump 60pt with no animation, and
        // every other state was padded out to fit the tallest one. Measuring
        // instead means each state gets the room it needs and no more, and the
        // change between them can be animated.
        //
        // Capped so a long paste of many URLs scrolls rather than growing a
        // sheet taller than the screen.
        .frame(width: 520)
        .frame(height: min(max(measuredContentHeight + chromeHeight, 360), 700))
        .onPreferenceChange(ContentHeightKey.self) { height in
            // The first measurement sizes the sheet as it opens; animating it
            // made the contents drift into place. Later changes still animate.
            guard hasMeasuredContent else {
                measuredContentHeight = height
                hasMeasuredContent = true
                return
            }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                measuredContentHeight = height
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isSingleYouTubeURL)
        .onAppear {
            logger.info("AddDownloadsView appeared, initialURL=\(self.initialURL ?? "nil")")
            if let initialURL, !initialURL.isEmpty, inputText != initialURL {
                // Pre-filled presentation (extension hand-off). Assign and
                // parse so the yt-dlp format fetch is already in flight by the
                // time the sheet finishes animating in.
                inputText = initialURL
                parseInputText(initialURL)
            } else if !inputText.isEmpty && validURLs.isEmpty {
                // Text survived from a previous presentation but was never
                // parsed — the TextField's own .onChange covers every keystroke
                // after this, so this only has to cover the first appearance.
                parseInputText(inputText)
            }
        }
    }
    
    private var isSingleYouTubeURL: Bool {
        guard validURLs.count == 1, let first = validURLs.first else { return false }
        let host = first.host?.lowercased() ?? ""
        return host.contains("youtube.com") || host == "youtu.be"
    }
    
    /// Matches DuplicateDownloadSheet's header: a tinted rounded-rect chip
    /// rather than a bare glyph, and the same explicit type scale. That sheet
    /// was already the most finished surface in the app; this one was the only
    /// one not speaking its language, which is most of why it read as rough.
    private var headerView: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    // Reacts the moment a link is recognised, so the sheet
                    // acknowledges the paste before anything else can.
                    .symbolEffect(.bounce, value: validURLs.count)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Add Downloads")
                    .font(.system(size: 14, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.18), value: headerSubtitle)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    /// Section headers, one definition. `.headline` is ~13pt bold, which sat
    /// heavier than anything else in the app; this is the quieter label macOS
    /// uses above grouped controls.
    // MARK: - Layout vocabulary
    //
    // One spacing scale and one container, used by every section. Previously
    // each section invented its own -- internal spacings of 8, 10, 8 and 16,
    // a 200pt slider floating in a 500pt row, and one section in a heavy grey
    // box while its neighbours had no container at all. The result read as
    // unevenly spaced because it was.

    /// Between a section's header and its content.
    private let labelGap: CGFloat = 7
    /// Between one section and the next.
    private let sectionGap: CGFloat = 18

    /// The grouped container every section's content sits in, so related rows
    /// read as one object and unrelated ones are clearly separate.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        )
    }

    /// Inset so it stops short of the card's rounded corners, the way
    /// macOS's own grouped lists do.
    private var rowDivider: some View {
        Divider().padding(.leading, 12)
    }

    /// Contextual explanation inside a card. Same row rhythm as the rest, no
    /// nested background -- the card already provides one.
    private func noteRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 14)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
    
    private func inlineWarning(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(.system(size: 11))
        }
        .foregroundStyle(.red)
    }

    private var headerSubtitle: String {
        if validURLs.count <= 1 {
            return "Enter a URL or paste multiple links"
        } else {
            return "\(validURLs.count) valid download links detected"
        }
    }
    
    private var urlInputSection: some View {
        VStack(alignment: .leading, spacing: labelGap) {
            HStack {
                sectionHeader("URL(s)", systemImage: "link")
                Spacer()
                // The system's paste control: macOS knows the person asked
                // for the clipboard, so reading it raises no privacy prompt.
                PasteButton(payloadType: String.self) { strings in
                    guard let string = strings.first else { return }
                    inputText = string
                }
                .controlSize(.small)
            }

            card {
                // Verbatim: a string literal here is read as Markdown, which
                // turned an example URL into a blue link.
                TextField(
                    text: $inputText,
                    prompt: Text(verbatim: "Paste or type links, one per line"),
                    axis: .vertical
                ) {
                    Text("URLs")
                }
                .textFieldStyle(.plain)
                // Monospaced only once there are links to read.
                .font(.system(size: 12, design: inputText.isEmpty ? .default : .monospaced))
                .lineLimit(2...5)
                .focused($isURLFieldFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .onChange(of: inputText) { _, newValue in
                    parseInputText(newValue)
                }

                if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    rowDivider
                    linkStatusRow
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .opacity(isURLFieldFocused ? 1 : 0)
            )
            .animation(.easeOut(duration: 0.15), value: isURLFieldFocused)

            if !errorMessage.isEmpty {
                inlineWarning(errorMessage)
            }
        }
    }

    private var linkStatusRow: some View {
        HStack(spacing: 6) {
            if validURLs.isEmpty {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Text("No valid links yet")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(validURLs.count == 1 ? "1 link" : "\(validURLs.count) links")
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .animation(.easeOut(duration: 0.15), value: validURLs.count)
    }
    
    private var youtubeQualitySection: some View {
        VStack(alignment: .leading, spacing: labelGap) {
            sectionHeader("Video", systemImage: "play.rectangle")

            card {
                // Present in every state, so resolving -> ready fills in
                // rather than swapping one layout for a differently shaped one
                // and shoving everything below it.
                videoPreviewRow

                rowDivider

                if isFetchingFormats {
                    resolvingRow
                } else if let formatsFetchError {
                    noteRow(icon: "exclamationmark.triangle.fill", tint: .red, text: formatsFetchError)
                } else {
                    // One grid so both popups start at the same x: the label
                    // column sizes itself to the longer label.
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                        GridRow {
                            pickerLabel("Video quality")
                            qualityPicker.padding(.trailing, 12).padding(.vertical, 9)
                        }
                        if showsAudioLanguagePicker {
                            rowDivider.gridCellUnsizedAxes(.horizontal)
                            GridRow {
                                pickerLabel("Audio language")
                                audioLanguagePicker.padding(.trailing, 12).padding(.vertical, 9)
                            }
                        }
                    }
                    if let note = selectedFormatNote {
                        rowDivider
                        noteRow(icon: note.icon, tint: note.tint, text: note.text)
                    }
                }
            }
        }
    }

    /// The explanation attached to the current pick, if it needs one.
    ///
    /// Pulled out of the view so the section reads as a list of rows rather
    /// than nested conditionals, and so "is there a note" can be asked before
    /// deciding whether to draw a divider above it.
    private var selectedFormatNote: (icon: String, tint: Color, text: String)? {
        guard let selected = youtubeOptions.first(where: { $0.id == selectedFormatID }),
              selected.hasVideo, !selected.hasAudio else { return nil }
        // Only the no-audio case. With the client pinned there is no combined
        // format, so the "merged automatically" arm would fire on every video
        // pick and restate the section header above it.
        guard !selected.audioMergeAvailable else { return nil }
        return ("speaker.slash", .orange,
                "Video-only — no audio track available to merge in.")
    }

    /// Deliberately a Picker, and deliberately not stretched.
    ///
    /// A menu-style Picker on macOS sizes itself to its widest content, so it
    /// cannot be made to span the row -- it leaves some space against the
    /// card's right edge. That was tried as a Menu with a button style, which
    /// does stretch, and it looked considerably worse: a centred capsule
    /// rather than a native popup. The trailing space is the better trade.
    private var qualityPicker: some View {
        Picker(selection: $selectedFormatID) {
            // Grouped with inert (untagged, disabled) header rows and
            // Dividers — on macOS a menu-style Picker builds a real
            // NSMenu, and any child without a matching tag renders as
            // a plain, non-interactive item, so this reads exactly
            // like the sectioned menus macOS's own System Settings
            // uses (e.g. "Default web browser") rather than one long
            // undifferentiated list.
            if !combinedQualityOptions.isEmpty {
                Text("Video + Audio (single file)").disabled(true)
                ForEach(combinedQualityOptions) { option in
                    qualityRow(option).tag(Optional(option.id))
                }
            }
            if !videoOnlyQualityOptions.isEmpty {
                if !combinedQualityOptions.isEmpty { Divider() }
                Text("Video (audio merged automatically)").disabled(true)
                ForEach(videoOnlyQualityOptions) { option in
                    qualityRow(option).tag(Optional(option.id))
                }
            }
            if !audioOnlyQualityOptions.isEmpty {
                if !combinedQualityOptions.isEmpty || !videoOnlyQualityOptions.isEmpty { Divider() }
                Text("Audio Only").disabled(true)
                ForEach(audioOnlyQualityOptions) { option in
                    qualityRow(option).tag(Optional(option.id))
                }
            }
        } label: {
            Text("Video quality")
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if selectedFormatID == nil { selectedFormatID = YouTubeResolver.defaultFormatID(from: youtubeOptions) }
        }
    }

    /// Which language a dubbed video is saved in. Only for a pick whose sound
    /// comes from a separate audio track — video-only (merged) or audio-only.
    private var audioLanguagePicker: some View {
        Picker("Audio language", selection: $selectedAudioLanguage) {
            ForEach(audioTracks) { track in
                Text(track.isOriginal ? "\(track.name) — original" : track.name)
                    .tag(Optional(track.language))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The label beside a popup in the Video card. The popup keeps its own
    /// label too, hidden, so VoiceOver still names it.
    private func pickerLabel(_ title: String) -> some View {
        Text(title)
            .padding(.leading, 12)
            .padding(.vertical, 9)
    }

    private var audioTracks: [YouTubeAudioTrack] { youtubeInfo?.audioTracks ?? [] }

    private var showsAudioLanguagePicker: Bool {
        guard audioTracks.count > 1,
              let selected = youtubeOptions.first(where: { $0.id == selectedFormatID }) else { return false }
        return selected.hasVideo ? (!selected.hasAudio && selected.audioMergeAvailable) : selected.hasAudio
    }

    /// Thumbnail, title and duration for the video being resolved.
    ///
    /// Resolving takes roughly two seconds of YouTube round-trips, which is
    /// network-bound and not going away. Showing what is being resolved turns
    /// that from a blank wait into a recognisable video, and doubles as the
    /// confirmation that the right link was pasted.
    private var videoPreviewRow: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
                if let youtubeThumbnailURL {
                    // Plain image fetch, no cookies or headers -- this is the
                    // public thumbnail, not part of the authenticated path.
                    AsyncImage(url: youtubeThumbnailURL) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 72, height: 41)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(youtubeTitle ?? "Resolving video…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(youtubeTitle == nil ? .secondary : .primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = previewSubtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .animation(.easeOut(duration: 0.2), value: youtubeTitle)
        .animation(.easeOut(duration: 0.2), value: youtubeThumbnailURL)
    }

    private var resolvingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking available qualities…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    /// Duration and, once a quality is picked, its size -- so the preview
    /// answers "what am I about to download" without reading the menu.
    private var previewSubtitle: String? {
        let size = youtubeOptions.first { $0.id == selectedFormatID }?.filesizeBytes
        switch (durationText, size) {
        case let (.some(duration), .some(bytes)): return "\(duration) · \(formatBytes(bytes))"
        case let (.some(duration), .none): return duration
        case let (.none, .some(bytes)): return formatBytes(bytes)
        default: return nil
        }
    }

    /// h:mm:ss, dropping the hours component when there isn't one.
    private var durationText: String? {
        guard let youtubeDuration, youtubeDuration > 0 else { return nil }
        let total = Int(youtubeDuration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    private var combinedQualityOptions: [YouTubeFormatOption] {
        youtubeOptions.filter { $0.hasVideo && $0.hasAudio }
    }
    private var videoOnlyQualityOptions: [YouTubeFormatOption] {
        youtubeOptions.filter { $0.hasVideo && !$0.hasAudio }
    }
    private var audioOnlyQualityOptions: [YouTubeFormatOption] {
        youtubeOptions.filter { !$0.hasVideo && $0.hasAudio }
    }
    
    /// A single quality row: SF Symbol keyed to the stream type (matches the
    /// section it's grouped under), plus a plain-string title. Deliberately
    /// not a composite HStack/Spacer layout — a menu-style Picker on macOS
    /// builds real NSMenuItems under the hood, which render a Label's icon
    /// + text but can't host arbitrary custom layouts, so the size is folded
    /// into the title string (the same "Title (detail)" convention macOS's
    /// own menus use, e.g. Safari's "Reopen Last Closed Tab (⇧⌘T)") rather
    /// than attempted as a right-aligned column.
    private func qualityRow(_ option: YouTubeFormatOption) -> some View {
        let icon: String = {
            if option.hasVideo && option.hasAudio { return "play.rectangle.fill" }
            if option.hasVideo { return "rectangle.badge.plus" }
            return "waveform"
        }()
        // The resolver appends "(+ audio)" to the label text for non-SwiftUI
        // consumers (the browser-extension popup); it's redundant here since
        // the row already sits under the "audio merged automatically"
        // section header, so trim it for a cleaner native menu row.
        let title = option.label.replacingOccurrences(of: " (+ audio)", with: "")
        let sizeSuffix = option.filesizeBytes.map { " — \(formatBytes($0))" } ?? ""
        return Label(title + sizeSuffix, systemImage: icon)
    }
    
    /// The folder from Settings, which is where the download manager saves
    /// when nothing is chosen here.
    private var defaultFolder: URL {
        URL(fileURLWithPath: AppSettings.shared.downloadDirectory, isDirectory: true)
    }
    private var resolvedDestination: URL {
        (destination ?? defaultFolder).standardizedFileURL
    }
    private var destinationPath: String {
        resolvedDestination.path(percentEncoded: false)
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// Where the file goes, and the segment count when it can apply (yt-dlp
    /// does its own fetching for YouTube, so there it's just the folder).
    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: labelGap) {
            sectionHeader("Options", systemImage: "slider.horizontal.3")

            card {
                HStack(spacing: 12) {
                    Text("Save to")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    folderPicker
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 40)

                if !isSingleYouTubeURL {
                    rowDivider
                    segmentsRow
                }
            }
            .animation(.easeOut(duration: 0.15), value: segmentCount)
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            destination = folder
        }
    }

    /// Safari's and the Screenshot tool's pattern: the usual folders, the
    /// last few used, then Other… for anything else.
    private var folderPicker: some View {
        Picker("Save to", selection: Binding<FolderChoice>(
            get: { .folder(resolvedDestination) },
            set: { choice in
                switch choice {
                case .folder(let folder): destination = folder
                case .other:
                    // After the menu's fade-out: opened any sooner, the
                    // picker froze the half-faded menu on screen behind it.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        isChoosingFolder = true
                    }
                }
            }
        )) {
            ForEach(standardFolders, id: \.self) { folderRow($0) }
            let recent = recentFolderChoices
            if !recent.isEmpty {
                Divider()
                Text("Recent").disabled(true)
                ForEach(recent, id: \.self) { folderRow($0) }
            }
            Divider()
            Text("Other…").tag(FolderChoice.other)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help(destinationPath)
    }

    private func folderRow(_ folder: URL) -> some View {
        Label(FileManager.default.displayName(atPath: folder.path), systemImage: "folder")
            .tag(FolderChoice.folder(folder))
    }

    /// The Settings default, then Downloads and Desktop when they differ.
    private var standardFolders: [URL] {
        let fm = FileManager.default
        let candidates = [defaultFolder]
            + fm.urls(for: .downloadsDirectory, in: .userDomainMask)
            + fm.urls(for: .desktopDirectory, in: .userDomainMask)
        return candidates.map(\.standardizedFileURL).reduce(into: []) { result, folder in
            if !result.contains(folder) { result.append(folder) }
        }
    }

    /// Recently used folders, plus the one just picked through Other… so
    /// the menu can show it as selected.
    private var recentFolderChoices: [URL] {
        let standard = standardFolders
        var folders = recentFolders
        if let destination, !folders.contains(destination.standardizedFileURL) {
            folders.insert(destination.standardizedFileURL, at: 0)
        }
        return folders.filter { !standard.contains($0) }
    }

    private var segmentsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Parallel segments")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(segmentCount)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            // Full width rather than a 200pt control floating in a
            // 500pt row.
            Slider(
                value: Binding(
                    get: { Double(segmentCount) },
                    set: { segmentCount = Int($0) }
                ),
                in: 1...16,
                step: 1
            )
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private var footerView: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.escape)
            
            Spacer()
            
            Button(action: startDownloads) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(startButtonTitle)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(validURLs.isEmpty || isLoading)
            .keyboardShortcut(.return)
        }
        .padding(24)
    }
    
    private var startButtonTitle: String {
        if validURLs.count > 1 {
            return "Start \(validURLs.count) Downloads"
        } else {
            return "Start Download"
        }
    }
    
    private func parseInputText(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline)
        let parsed = lines.compactMap { line -> URL? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "ftp"].contains(scheme),
                  url.host != nil else { return nil }
            return url
        }
        
        validURLs = parsed
        errorMessage = ""
        
        if isSingleYouTubeURL, let singleURL = validURLs.first {
            Task { await fetchYouTubeFormats(for: singleURL) }
        } else {
            youtubeOptions = []
            youtubeInfo = nil
            selectedFormatID = nil
            selectedAudioLanguage = nil
            formatsFetchError = nil
            youtubeTitle = nil
            youtubeDuration = nil
            youtubeThumbnailURL = nil
        }
    }
    
    private func fetchYouTubeFormats(for parsedURL: URL) async {
        isFetchingFormats = true
        formatsFetchError = nil
        do {
            let info = try await YouTubeResolver.shared.listFormats(url: parsedURL)
            await MainActor.run {
                youtubeTitle = info.title
                youtubeDuration = info.durationSeconds
                youtubeThumbnailURL = info.thumbnailURL
                youtubeOptions = info.options
                youtubeInfo = info
                selectedFormatID = YouTubeResolver.defaultFormatID(from: info.options)
                selectedAudioLanguage = YouTubeResolver.defaultAudioLanguage(
                    in: info.audioTracks, preferred: AppSettings.shared.preferredAudioLanguage
                )
                isFetchingFormats = false
            }
        } catch {
            await MainActor.run {
                // Including helpersNotInstalled, which names the fix itself --
                // this used to override that case here because the error said
                // to run a repo script, which a user doesn't have.
                formatsFetchError = error.localizedDescription
                isFetchingFormats = false
            }
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var size = Double(bytes)
        var unit = 0
        while size >= 1024 && unit < units.count - 1 { size /= 1024; unit += 1 }
        return String(format: "%.1f %@", size, units[unit])
    }
    
    /// The short quality name to put in the saved filename — "1080p60",
    /// "360p", "Audio". The resolver's full `label` carries decoration meant
    /// for the picker menu ("1080p60 · mp4 (+ audio)"), which would land in the
    /// filename as `Title (1080p60 · mp4 (+ audio)).mp4`. Every label shape the
    /// resolver builds puts the quality first and separates with " · ", so the
    /// leading component is exactly the part worth keeping.
    private func qualityToken(for option: YouTubeFormatOption) -> String {
        let leading = option.label.components(separatedBy: " · ").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !leading.isEmpty { return leading }
        // Nothing usable in the label — fall back to the structured height.
        return option.height.map { "\($0)p" } ?? option.id
    }

    private func sanitizeFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return name.components(separatedBy: invalidChars).joined(separator: "-")
    }
    
    /// Runs `add`, treating a `DownloadConflictError` as success.
    ///
    /// Every add path throws it to mean "this became a question for the
    /// duplicate sheet rather than a task". Letting it reach the catch below
    /// would leave this sheet open showing a raw Swift error string behind the
    /// very sheet that is asking about it.
    private func addingIgnoringConflicts(_ add: () async throws -> Void) async throws {
        do {
            try await add()
        } catch is DownloadConflictError {
            return
        }
    }

    private func startDownloads() {
        guard !validURLs.isEmpty else { return }
        isLoading = true
        errorMessage = ""
        
        let segments = segmentCount
        if let destination, !standardFolders.contains(destination.standardizedFileURL) {
            RecentDownloadFolders.record(destination)
        }
        
        Task {
            do {
                if isSingleYouTubeURL, let watchPageURL = validURLs.first, let chosen = youtubeOptions.first(where: { $0.id == selectedFormatID }) {
                    let title = youtubeTitle ?? "video"
                    // A video-only pick needs an audio track added and muxed.
                    // MediaMuxer does that through AVFoundation once yt-dlp has
                    // written both files (yt-dlp merged it itself, with ffmpeg,
                    // until the helper set was slimmed), and it writes MP4 — so
                    // the saved file must carry the .mp4 extension in that case
                    // regardless of the video stream's own container. A combined
                    // or audio-only pick keeps its native extension, since
                    // nothing is merged.
                    let needsMerge = chosen.hasVideo && !chosen.hasAudio
                    let ext = needsMerge ? "mp4" : chosen.ext
                    let language = showsAudioLanguagePicker ? selectedAudioLanguage : nil
                    // A dub is named in the file, so two languages of one
                    // video don't come out as "Title (1080p)" and "… (1)".
                    let dub = audioTracks.first { $0.language == language && !$0.isOriginal }
                    let token = qualityToken(for: chosen) + (dub.map { ", \($0.name)" } ?? "")
                    let filename = sanitizeFilename("\(title) (\(token)).\(ext)")
                    let dest = (destination ?? URL(fileURLWithPath: AppSettings.shared.downloadDirectory))
                        .appendingPathComponent(filename)
                    // yt-dlp performs the whole download — see YouTubeDownloader
                    // for why the byte-range engine can't fetch what YouTube
                    // currently serves.
                    // A DownloadConflictError here means the request was
                    // handed to the duplicate sheet, which is a normal
                    // outcome and not something to report as a failure — this
                    // sheet gets out of the way and lets that one ask.
                    try await addingIgnoringConflicts {
                        _ = try await downloadManager.addYouTubeDownload(
                            pageURL: watchPageURL,
                            formatID: chosen.hasVideo
                                ? chosen.id
                                : YouTubeResolver.audioSelector(formatID: chosen.id, language: language),
                            // Only for a video-only pick. The resolver chose
                            // this track rather than leaving it to yt-dlp's
                            // `bestaudio` — see MergeAudio.
                            mergeAudio: needsMerge ? youtubeInfo?.mergeAudio(language: language) : nil,
                            videoBytes: chosen.filesizeBytes,
                            destination: dest,
                            filenameSource: .extractorMetadata
                        )
                    }
                } else {
                    for url in validURLs {
                        let dest = destination?.appendingPathComponent(url.lastPathComponent)
                        // Per URL, so one duplicate in a pasted batch queues
                        // its question and the rest of the batch still gets
                        // added. Conflicts are presented one at a time.
                        try await addingIgnoringConflicts {
                            _ = try await downloadManager.addDownload(
                                url: url,
                                destination: dest,
                                filenameSource: .originalURL,
                                segmentCount: segments
                            )
                        }
                    }
                }
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

// Backward compatibility aliases
typealias NewDownloadView = AddDownloadsView
typealias PasteURLsView = AddDownloadsView
