import SwiftUI
import DownloadEngine

struct DownloadRowView: View {
    @ObservedObject var task: DownloadTask
    @EnvironmentObject var downloadManager: DownloadManager
    @ObservedObject private var settings = AppSettings.shared
    var isSelected: Bool
    /// False while focus is outside the list: the selection then draws
    /// grey, as in Finder, since keys won't act on it.
    var isEmphasized: Bool = true
    /// True once at least one row anywhere in the list is selected — see
    /// ContentView.isSelectionModeActive. While true, clicking anywhere on
    /// this row (not just the checkbox) toggles its selection; while false,
    /// only the checkbox does, so an ordinary click on a row still does
    /// nothing surprising when nothing's selected yet.
    var isSelectionModeActive: Bool = false
    /// Called for both the checkbox and (in selection mode) a click
    /// anywhere on the row, carrying whether Shift/Command were held so the
    /// caller can implement range-select / additive-toggle. The checkbox
    /// itself ignores this and always does a plain toggle — see its own
    /// action below.
    var onSelect: (_ shiftHeld: Bool, _ commandHeld: Bool) -> Void
    /// Raises this row's Delete for confirmation. The row deliberately can't
    /// delete anything itself — ContentView owns the one confirmation sheet
    /// every entry point shares.
    var onRequestDelete: () -> Void
    @State private var isHovering = false
    @State private var fileMissing = false
    @State private var showingTorrentFiles = false
    @State private var isPieceMapExpanded = false
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The row's horizontal layout, named so the list can inset its separator
    /// to the title without restating these numbers.
    static let horizontalPadding: CGFloat = 14
    static let iconSize: CGFloat = 40
    static let iconSpacing: CGFloat = 14
    /// Left gutter reserved on every row for the torrent disclosure chevron,
    /// so icons stay in one column whether or not a row can expand.
    static let disclosureGutter: CGFloat = 12
    /// Where the title starts, from the row's leading edge.
    static var textLeading: CGFloat { horizontalPadding + disclosureGutter + iconSize + iconSpacing }

    init(task: DownloadTask, isSelected: Bool = false, isEmphasized: Bool = true, isSelectionModeActive: Bool = false, onSelect: @escaping (Bool, Bool) -> Void = { _, _ in }, onRequestDelete: @escaping () -> Void = {}) {
        self.task = task
        self.isSelected = isSelected
        self.isEmphasized = isEmphasized
        self.isSelectionModeActive = isSelectionModeActive
        self.onSelect = onSelect
        self.onRequestDelete = onRequestDelete
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Self.iconSpacing) {
                fileKindIcon

                VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(task.filename)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(fileMissing ? .secondary : .primary)
                    
                    // The name gives way first when the row narrows.
                    statusPill
                        .fixedSize()

                    if let categoryName = routedCategoryName {
                        Text("→ \(categoryName)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .help(task.destinationURL.deletingLastPathComponent().path)
                    }
                    
                    Spacer(minLength: 8)
                    
                    if task.status == .downloading || task.status == .waiting || task.status == .validating {
                        Text("\(Int(task.progress * 100))%")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                
                // One bar for every state that has one, not one per branch
                // below: a bar that keeps its identity across states can
                // animate between them (see SegmentBar).
                if !fileMissing && task.status.showsProgressBar {
                    progressBar
                }

                if fileMissing {
                    metric(icon: "questionmark.folder", text: "Moved or deleted")
                } else if task.status == .waiting {
                    HStack(spacing: 10) {
                        metric(icon: "internaldrive", text: sizeMetricText)
                        Text("|")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text("Queued — waiting for a free slot")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else if task.status == .downloading
                       || task.status == .starting || task.status == .validating
                       || task.status == .refreshingLink {
                    // Drops the least useful details as the row narrows,
                    // instead of truncating all of them.
                    ViewThatFits(in: .horizontal) {
                        activeMetrics(showsTimeLeft: true, showsParts: true)
                        activeMetrics(showsTimeLeft: true, showsParts: false)
                        activeMetrics(showsTimeLeft: false, showsParts: false)
                    }
                } else if task.status == .completed {
                    HStack(spacing: 14) {
                        completedTimeMetric(task.endTime)
                        metric(icon: "internaldrive", text: ByteFormat.size(task.totalBytes, digits: .fixed))
                        if task.isSeeding {
                            seedingChip
                        }
                    }
                } else if case .failed(let error) = task.status {
                    // Was .lineLimit(1) — YouTube's specific error messages
                    // (see DownloadError.youtubeQualityCurrentlyBlocked) run
                    // 300+ chars and carry the actual actionable explanation,
                    // not just "Download failed" — clipping them to one line
                    // hid exactly the part worth reading. Wraps up to 4 lines
                    // now; .help() covers the rare message even that doesn't
                    // fully fit, via hover tooltip.
                    Text(error?.localizedDescription ?? "Download failed")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(error?.localizedDescription ?? "Download failed")
                } else if task.status == .paused {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 10) {
                            metric(icon: "internaldrive", text: sizeMetricText)
                            if let parts = partsMetric {
                                metric(icon: parts.icon, text: parts.text)
                            }
                        }
                        if let message = task.activityMessage {
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if case .urlExpired = task.status {
                    HStack(spacing: 14) {
                        metric(icon: "internaldrive", text: sizeMetricText)
                        Text("|")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text("Link expired — tap Re-link to continue")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else if case .destinationMissing = task.status {
                    HStack(spacing: 14) {
                        metric(icon: "internaldrive", text: sizeMetricText)
                        Text("|")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text("Original folder can't be found — choose a new one to continue")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else if task.status == .awaitingDuplicateResolution {
                    // Deliberately no progressBar here — unlike paused/
                    // urlExpired/destinationMissing, this state means the
                    // transfer is genuinely stopped (see
                    // DownloadTask.markAwaitingConflictResolution), not
                    // merely idle with real progress to show off. Showing a
                    // static bar next to "waiting on you" would read as
                    // contradictory — progress implies motion.
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text("A duplicate was found — nothing more is downloading until you decide")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                if let notice = task.categoryNotice {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text(notice)
                            .font(.system(size: 11))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            actionButtons
        }
            .padding(.vertical, 12)
            .padding(.leading, Self.horizontalPadding + Self.disclosureGutter)
            .padding(.trailing, Self.horizontalPadding)
            .overlay(alignment: .leading) {
                disclosureToggle
            }

            if task.isTorrent && isPieceMapExpanded && !fileMissing {
                Divider()
                    .padding(.horizontal, Self.horizontalPadding)
                torrentDetailsDrawer
                    .padding(.horizontal, Self.horizontalPadding)
                    .padding(.vertical, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    isSelected
                        ? (isEmphasized && appearsActive ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.12))
                        : (isHovering || (task.isTorrent && isPieceMapExpanded)) ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5) : Color.clear
                )
        )
        .opacity(fileMissing ? 0.55 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionModeActive {
                let flags = NSEvent.modifierFlags
                onSelect(flags.contains(.shift), flags.contains(.command))
            } else if canExpandTorrent {
                toggleTorrentDetails()
            }
        }
        .onHover { isHovering = $0 }
        .onAppear { refreshFileState() }
        .contextMenu { contextMenuItems }
        .sheet(isPresented: $showingTorrentFiles) {
            TorrentFilesSheet(task: task)
        }
    }
    
    // MARK: - File state
    
    /// One-shot check, not a background watcher — matches "only act when
    /// interacted with". Runs when the row appears (covers app launch and
    /// scrolling a row into view) so a moved/deleted file shows greyed out
    /// immediately, Chrome-downloads-style, without needing a click first.
    private func refreshFileState() {
        guard task.status == .completed else { return }
        fileMissing = !FileManager.default.fileExists(atPath: task.destinationURL.path)
    }
    
    // MARK: - Actions helper

    private func revealInFinder() {
        refreshFileState()
        guard !fileMissing else { return }
        task.showInFinder()
    }
    
    private func openFile() {
        refreshFileState()
        guard !fileMissing else { return }
        task.openFile()
    }
    
    /// Lets the user pick a new folder for a task whose original
    /// destination went missing (see DownloadStatus.destinationMissing),
    /// then resumes it there. NSOpenPanel lives here rather than on
    /// DownloadTask/DownloadManager since it's pure AppKit UI, not engine
    /// state — same split as DownloadSettingsView.selectDirectory.
    private func chooseNewFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        task.relocateDestinationFolder(to: folder)
        Task { try? await downloadManager.resumeDownload(task) }
    }
    
    // MARK: - Icon
    
    @ViewBuilder
    private var fileKindIcon: some View {
        let iconTint: Color = fileMissing ? .gray : (task.isTorrent ? TorrentStyle.tint : task.fileKind.tint)
        let iconSymbol: String = fileMissing
            ? "questionmark.folder"
            : (task.isTorrent ? TorrentStyle.symbol : task.fileKind.symbol)
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(iconTint.opacity(0.15))
                .frame(width: Self.iconSize, height: Self.iconSize)
            
            Image(systemName: iconSymbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(iconTint)
        }
        .overlay(alignment: .topLeading) {
            if isHovering || isSelected || isSelectionModeActive {
                Button(action: { onSelect(false, false) }) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(isSelected ? "Deselect" : "Select")
                .offset(x: -4, y: -4)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .overlay(alignment: .bottomTrailing) {
            if !fileMissing {
                Image(systemName: statusIconName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(task.status.color))
                    .offset(x: 4, y: 4)
            }
        }

    }
    
    // MARK: - Status

    /// The name of the category that routed this download, if one did.
    /// Falls back to the folder's name when the category was removed later,
    /// so the row still says where its file went.
    private var routedCategoryName: String? {
        guard let categoryID = task.categoryID else { return nil }
        if let match = settings.downloadCategories.first(where: { $0.id == categoryID }) {
            return match.name
        }
        let folderName = task.destinationURL.deletingLastPathComponent().lastPathComponent
        return folderName.isEmpty ? nil : folderName
    }

    private var statusPill: some View {
        Group {
            if fileMissing {
                Text("Moved")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.gray)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.13), in: Capsule())
            } else if task.status != .completed {
                Text(task.status.label)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(task.status.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(task.status.color.opacity(0.13), in: Capsule())
            }
        }
    }
    
    private var statusIconName: String {
        switch task.status {
        case .waiting: return "clock.fill"
        case .starting, .refreshingLink: return "arrow.down"
        case .validating: return "magnifyingglass"
        case .downloading: return "arrow.down"
        case .paused: return "pause.fill"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        case .cancelled: return "xmark"
        case .urlExpired: return "link.slash"
        case .destinationMissing: return "questionmark.folder"
        case .awaitingDuplicateResolution: return "exclamationmark.circle.fill"
        }
    }
    
    // MARK: - Progress bar
    
    /// A stream cannot know its finished size, so it reports only what has
    /// arrived. Everything else knows its total and keeps the familiar pair.
    /// Uses `.fixed` digits so the text never changes length while it updates.
    private var sizeMetricText: String {
        task.hasUnknownTotalSize
            ? ByteFormat.size(task.downloadedBytes, digits: .fixed)
            : "\(ByteFormat.size(task.downloadedBytes, digits: .fixed)) / \(ByteFormat.size(task.totalBytes, digits: .fixed))"
    }

    /// The segment count the percentage is computed from. Doubles as the
    /// answer to why there is no total size beside it.
    private var partsMetric: (icon: String, text: String)? {
        guard task.hasUnknownTotalSize, let parts = task.segmentProgress else { return nil }
        return ("square.grid.3x3", "\(parts.completed) of \(parts.total) parts")
    }

    private var canExpandTorrent: Bool {
        task.isTorrent && !fileMissing && !isSelectionModeActive
    }

    /// The single place the torrent details drawer opens and closes: the row
    /// tap, the progress bar tap, the chevron and the context menu all call it.
    /// Callers keep their own guards.
    private func toggleTorrentDetails() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            isPieceMapExpanded.toggle()
        }
    }

    /// Disclosure chevron, centred in the row's whole leading inset (edge
    /// padding + gutter) so it sits evenly between the card edge and the icon.
    /// Only torrent rows draw one; the gutter itself is reserved on every row
    /// (see `disclosureGutter`).
    @ViewBuilder
    private var disclosureToggle: some View {
        if canExpandTorrent {
            Button(action: toggleTorrentDetails) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHovering || isPieceMapExpanded ? .primary : .secondary)
                    .rotationEffect(.degrees(isPieceMapExpanded ? 90 : 0))
                    .frame(width: Self.horizontalPadding + Self.disclosureGutter, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isPieceMapExpanded ? "Hide details" : "Show details")
            .accessibilityLabel(isPieceMapExpanded ? "Hide details" : "Show details")
        }
    }

    private var progressBar: some View {
        SegmentBar(map: task.isTorrent ? nil : task.segmentMap, progress: task.progress, color: task.status.color,
                   split: showsParts ? 1 : 0)
            .frame(height: 7)
            // No `.animation(value: task.progress)`: progress changes on every
            // network chunk, so the tween never ends and this Canvas redraws
            // every display frame while a download runs.
            .animation(reduceMotion ? nil : .smooth(duration: 0.55), value: showsParts)
            .contentShape(Rectangle())
            .onTapGesture {
                guard canExpandTorrent else { return }
                toggleTorrentDetails()
            }
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue(progressAccessibilityValue)
    }

    /// Parts only while they're being fetched: a stopped download's gaps say
    /// nothing a single bar doesn't, and the join puts them back together.
    /// Torrents use a clean solid bar in the row and show the 2D piece map in
    /// the expandable drawer.
    private var showsParts: Bool {
        !task.isTorrent && task.status == .downloading && !task.isMerging && task.segmentMap != nil
    }

    private var progressAccessibilityValue: String {
        let percent = "\(Int(task.progress * 100)) percent"
        if let parts = task.segmentProgress {
            return "\(percent), \(parts.completed) of \(parts.total) parts"
        }
        if showsParts, let map = task.segmentMap, map.layout == .lanes {
            return "\(percent), \(map.activeCount) of \(map.spans.count) connections active"
        }
        return percent
    }
    
    // MARK: - Metrics
    
    private func metric(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11.5).monospacedDigit())
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    private func activeMetrics(showsTimeLeft: Bool, showsParts: Bool) -> some View {
        HStack(spacing: 10) {
            metric(icon: "internaldrive", text: sizeMetricText)
            metric(icon: "gauge.with.dots.needle.67percent", text: ByteFormat.speed(task.speed, digits: .fixed))
            if task.isTorrent {
                metric(icon: "arrow.up", text: ByteFormat.speed(task.uploadSpeed, digits: .fixed))
            }
            if showsTimeLeft, task.estimatedTimeRemaining > 0 {
                metric(icon: "clock", text: formatTime(task.estimatedTimeRemaining) + " left")
            }
            if showsParts, let parts = partsMetric {
                metric(icon: parts.icon, text: parts.text)
            }

            if let message = task.activityMessage {
                Text("|")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                ProgressView()
                    .controlSize(.mini)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
    
    /// Expandable inspector drawer inside a torrent row card.
    private var torrentDetailsDrawer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !task.torrentPieces.isEmpty {
                TorrentPieceGridView(pieces: task.torrentPieces, color: task.status.color)
            } else {
                Text("Piece map will appear once the download starts.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 16) {
                drawerStat("Downloaded", value: ByteFormat.size(task.downloadedBytes, digits: .fixed))
                drawerStat("Uploaded", value: ByteFormat.size(task.uploadedBytes, digits: .fixed))
                drawerStat("Ratio", value: ByteFormat.ratio(task.seedRatio))
                drawerStat("Swarm", value: "\(task.connectedSeeds) seeds · \(task.connectedPeers) peers")

                Spacer(minLength: 8)

                let visibleFiles = task.torrentFiles.filter { !$0.isHiddenPadding }
                if !visibleFiles.isEmpty && task.status != .completed {
                    let included = visibleFiles.filter(\.isIncluded).count
                    let total = visibleFiles.count
                    Button {
                        showingTorrentFiles = true
                    } label: {
                        Label(total > 1 ? "Files (\(included)/\(total))" : "Files", systemImage: "checklist")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if task.isSeeding {
                    Button("Stop Seeding") {
                        Task { await task.stopSeeding() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.leading, Self.disclosureGutter + Self.iconSize + Self.iconSpacing)
    }

    private func drawerStat(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var seedingChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
            Text("Seeding · \(ByteFormat.speed(task.uploadSpeed, digits: .fixed)) · ratio \(ByteFormat.ratio(task.seedRatio))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Stop") {
                Task { await task.stopSeeding() }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.accentColor)
        }
    }

    /// Deliberately not SwiftUI's native `Text(date, style: .relative)` —
    /// that ticks every second, which reads as more jittery than the bug it
    /// was meant to fix. Instead this buckets into coarse, human intervals
    /// ("Just now", "5 min ago", "2 hr ago") on a `TimelineView` that only
    /// re-evaluates once a minute, on its own schedule — fully decoupled
    /// from hover or any other redraw of this row.
    private func completedTimeMetric(_ date: Date?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 10))
            if let date {
                TimelineView(.periodic(from: date, by: 60)) { _ in
                    Text("Completed \(coarseRelativeText(date))")
                }
            } else {
                Text("Completed")
            }
        }
        .font(.system(size: 11.5).monospacedDigit())
        .foregroundStyle(.secondary)
    }
    
    private func coarseRelativeText(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 {
            let unit = minutes == 1 ? "minute" : "minutes"
            return "\(minutes) \(unit) ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            let unit = hours == 1 ? "hour" : "hours"
            return "\(hours) \(unit) ago"
        }
        let days = hours / 24
        if days < 7 {
            let unit = days == 1 ? "day" : "days"
            return "\(days) \(unit) ago"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
    
    // MARK: - Row buttons (non-destructive only)
    
    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 6) {
            if fileMissing {
                // Nothing to pause/open/retry on a file that isn't there —
                // right-click still offers Delete.
            } else if task.status == .downloading || task.status == .starting || task.status == .validating
                   || task.status == .refreshingLink {
                RowIconButton(icon: "pause.fill", tint: .primary) {
                    Task { await downloadManager.pauseDownload(task) }
                }
                .help("Pause download")
            } else if task.status == .waiting {
                RowIconButton(icon: "play.fill", tint: .blue) {
                    Task { try? await downloadManager.startDownload(task) }
                }
                .help("Start this download now")
            } else if task.status == .paused {
                RowIconButton(icon: "play.fill", tint: .blue) {
                    Task { try? await downloadManager.resumeDownload(task) }
                }
                .help("Resume download")
            } else if task.status == .completed {
                RowIconButton(icon: "folder", tint: .primary) {
                    revealInFinder()
                }
                .help("Show in Finder")
                RowIconButton(icon: "arrow.up.forward.app", tint: .primary) {
                    openFile()
                }
                .help("Open file")
            } else if case .failed = task.status {
                RowIconButton(icon: "arrow.clockwise", tint: .blue) {
                    Task { try? await downloadManager.retryFailed(task) }
                }
                .help("Retry download")
            } else if case .urlExpired = task.status {
                // Re-link: opens the source page (if one was captured) and the
                // re-link window, which waits for the download to be captured
                // again and checks it is the same file (RelinkCoordinator).
                // Enabled without a source page too: the person can find the
                // download themselves and capture it from wherever it is.
                RowIconButton(icon: "link.badge.plus", tint: .orange) {
                    RelinkCoordinator.shared.begin(for: task)
                }
                .help(task.referrerURL == nil
                      ? "Re-link: capture this download again in your browser to get a fresh link"
                      : "Re-link: open the source page and capture the download again")
            } else if case .destinationMissing = task.status {
                RowIconButton(icon: "folder.badge.plus", tint: .orange) {
                    chooseNewFolder()
                }
                .help("Original folder can't be found — choose a new one")
            }
            // Deliberately no delete/cancel button here — right-click for that.
            // Keeps a stray click from nuking a download by accident.
        }
    }
    
    // MARK: - Context menu
    
    @ViewBuilder
    private var contextMenuItems: some View {
        if fileMissing {
            Text("File not found at saved location")
        } else if task.status == .downloading || task.status == .starting || task.status == .validating || task.status == .refreshingLink {
            Button("Pause") {
                Task { await downloadManager.pauseDownload(task) }
            }
        } else if task.status == .waiting {
            Button("Start") {
                Task { try? await downloadManager.startDownload(task) }
            }
        } else if task.status == .paused {
            Button("Resume") {
                Task { try? await downloadManager.resumeDownload(task) }
            }
        } else if case .failed = task.status {
            // Plain "Retry" (resume in place) is deliberately not repeated
            // here — the row's own icon button already covers it. This menu
            // only needs to surface the option that button can't reach: a
            // full restart for a download the user believes is genuinely
            // corrupt/broken, which discards partial data on disk instead of
            // continuing from it.
            Button("Restart from Beginning") {
                Task { try? await downloadManager.retryFailed(task, fromScratch: true) }
            }
        } else if case .urlExpired = task.status {
            Button("Re-link…") { RelinkCoordinator.shared.begin(for: task) }
        } else if case .destinationMissing = task.status {
            Button("Choose New Folder…") { chooseNewFolder() }
            Button("Recreate Original Folder") {
                task.recreateOriginalDestinationFolder()
                Task { try? await downloadManager.resumeDownload(task) }
            }
        }
        
        if task.isTorrent && !fileMissing {
            Button(isPieceMapExpanded ? "Hide Details" : "Show Details") {
                toggleTorrentDetails()
            }
        }

        if task.isTorrent && !task.torrentFiles.isEmpty && task.status != .completed {
            Button("Choose Files…") { showingTorrentFiles = true }
        }

        if task.isSeeding {
            Button("Stop Seeding") {
                Task { await task.stopSeeding() }
            }
        }

        if task.status == .completed && !fileMissing {
            Button("Show in Finder") { revealInFinder() }
            Button("Open") { openFile() }
        }
        
        if !fileMissing {
            Button("Copy URL") { task.copyURL() }
            if task.status == .completed {
                Button("Copy File Path") { task.copyFilePath() }
            }
        }
        
        Divider()
        
        Button("Delete…", role: .destructive) {
            onRequestDelete()
        }
    }
    
    // MARK: - Formatting
    
    // Sizes and speeds come from ByteFormat (DownloadEngine), shared with every
    // other screen, so a figure reads the same wherever it appears.
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// A larger, properly-hoverable circular icon button for row actions —
/// replaces the old `.borderless` glyph buttons, which had a hit target
/// barely bigger than the SF Symbol itself.
private struct RowIconButton: View {
    let icon: String
    let tint: Color
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isHovering ? Color(nsColor: .quaternaryLabelColor).opacity(0.5) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}


