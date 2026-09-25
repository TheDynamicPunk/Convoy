import SwiftUI
import DownloadEngine

/// One presentation of the Add Downloads sheet. `url` is the link to pre-fill
/// (from the browser extension's YouTube latch) or nil for a blank sheet.
///
/// The `id` is fresh per instance on purpose: `.sheet(item:)` treats a new id as
/// a new presentation, so a second latch click while the sheet is open rebuilds
/// it with the new URL rather than reusing the old view — and reusing it is
/// exactly what silently dropped the URL before, since SwiftUI only honours a
/// `@State` initial value when that storage is first created.
struct AddDownloadsIntent: Identifiable {
    let id = UUID()
    let url: String?
}

/// Every modal ContentView can show, unified behind a single .sheet(item:)
/// modifier. SwiftUI only reliably supports one active sheet per view —
/// stacking several independent .sheet() modifiers on the same view risks
/// one silently not appearing when two become "active" around the same
/// time, since SwiftUI doesn't guarantee which one wins. That's not just a
/// style nit here: .duplicateConflict represents a download that's
/// genuinely suspended on a continuation waiting specifically for that
/// dialog to be answered (see DownloadManager.resolveLateIdentity)
/// — if the dialog can't render, that download hangs forever with no way
/// to unstick it. Ordered here by priority, most urgent first: a blocked
/// download always wins over a flow the person deliberately opened
/// themselves, per ContentView.activeSheet below.
enum ActiveSheet: Identifiable {
    case duplicateConflict(DuplicateDownloadConflict)
    case confirmDelete(DeleteRequest)
    case addDownloads(AddDownloadsIntent)
    case pasteURLs
    case browserSetup

    var id: String {
        switch self {
        case .duplicateConflict(let conflict): return "conflict-\(conflict.id)"
        case .confirmDelete(let request): return "delete-\(request.id)"
        case .addDownloads(let intent): return "add-\(intent.id)"
        case .pasteURLs: return "paste"
        case .browserSetup: return "browser-setup"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @ObservedObject private var browserSetup = BrowserSetupModel.shared
    @State private var selectedCategory: DownloadCategory = .all
    @State private var searchText = ""
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    /// Set only when the sidebar was hidden for lack of room, so widening the
    /// window brings it back without overriding someone who hid it by hand.
    @State private var sidebarHiddenForWidth = false
    @State private var selectedTaskIDs: Set<DownloadTask.ID> = []
    /// The last row explicitly clicked/checkbox-toggled (not via a
    /// shift-click range) — the fixed reference point Shift-click extends
    /// a range from, matching Finder/Mail: repeated shift-clicks all
    /// extend from this same anchor, not from wherever the previous
    /// shift-click landed.
    @State private var selectionAnchorID: DownloadTask.ID?
    /// The row keyboard arrows move relative to — independent of
    /// selectionAnchorID (the fixed shift-range start point). A mouse click
    /// or checkbox toggle also moves this, via handleSelection, so an
    /// arrow key right after a click continues from where you clicked
    /// rather than some stale prior position.
    @State private var focusedTaskID: DownloadTask.ID?
    @State private var showingPasteURLs = false
    // Drives the Add Downloads sheet, carrying the URL to pre-fill (nil for a
    // blank "+ New Download").
    //
    // Deliberately one piece of state rather than a Bool plus a separate
    // `pendingDownloadURL`. `.sheet(item:)` hands the whole value to its
    // content closure as a parameter, so there's no ordering between
    // separately-set fields for a race to land between — see
    // AddDownloadsIntent's doc comment above for the same reasoning applied
    // to why its `id` is fresh per instance.
    @State private var addDownloadsIntent: AddDownloadsIntent?
    /// The delete awaiting confirmation. Every delete entry point — row
    /// context menu, Delete key, header buttons, menu bar — sets this and
    /// nothing else; DeleteConfirmationSheet owns the decision and the call
    /// to the manager from there on.
    @State private var pendingDelete: DeleteRequest?
    @State private var toastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    
    // Assigns each task a fixed position the first time it's seen, and
    // never changes that position again for the lifetime of this view —
    // status changes (pause/resume/complete) no longer reorder the list at
    // all, even with animation. Position is only settled once (createdAt at
    // first appearance), so a download stays exactly where you first saw it
    // regardless of what happens to it afterward, which is what actually
    // keeps it trackable — an animated reorder is still a reorder.
    @State private var pinnedOrder: [DownloadTask.ID: Date] = [:]

    /// Whether the downloads list has keyboard focus, as reported by
    /// ListKeyResponder, which owns it. Drives the rows' selection colour.
    @State private var isListFocused = false

    var filteredTasks: [DownloadTask] {
        var tasks = downloadManager.tasks + downloadManager.completedTasks
        
        if !searchText.isEmpty {
            tasks = tasks.filter { $0.filename.localizedCaseInsensitiveContains(searchText) }
        }
        
        switch selectedCategory {
        case .all: break
        case .downloading:
            tasks = tasks.filter { $0.status == .downloading }
        case .completed:
            tasks = tasks.filter { $0.status == .completed }
        case .paused:
            tasks = tasks.filter { $0.status == .paused }
        case .failed:
            tasks = tasks.filter {
                if case .failed = $0.status { return true }
                return false
            }
        }
        
        return tasks.sorted { lhs, rhs in
            let lhsOrder = pinnedOrder[lhs.id] ?? lhs.createdAt
            let rhsOrder = pinnedOrder[rhs.id] ?? rhs.createdAt
            return lhsOrder > rhsOrder
        }
    }
    
    /// Whether the list is in "selection mode" — derived from having at
    /// least one row selected, rather than a separate flag to keep in sync.
    /// While true, DownloadRowView makes its whole row (not just the
    /// checkbox) clickable for selection; deselecting the last row exits
    /// selection mode the same way it entered, with no separate "done"
    /// action needed.
    private var isSelectionModeActive: Bool { !selectedTaskIDs.isEmpty }

    /// Shared by the checkbox and (once in selection mode) a click anywhere
    /// on a row. Shift-click range-selects from `selectionAnchorID`,
    /// replacing the current selection with exactly that range (Finder/Mail
    /// convention). Anything else — a plain click, Command-click, or the
    /// checkbox itself (always calls this with both flags false) — just
    /// toggles the one row, additively. Deliberately not "plain click
    /// replaces the whole selection" Finder-icon-grid behavior: this list's
    /// main use is building up a batch for a bulk action (mostly delete),
    /// where a stray unmodified click silently collapsing a careful
    /// multi-selection is a worse failure than plain click and
    /// Command-click simply being equivalent here.
    private func handleSelection(of task: DownloadTask, shiftHeld: Bool, commandHeld: Bool) {
        if shiftHeld, let anchor = selectionAnchorID,
           let anchorIndex = filteredTasks.firstIndex(where: { $0.id == anchor }),
           let clickedIndex = filteredTasks.firstIndex(where: { $0.id == task.id }) {
            let range = anchorIndex < clickedIndex ? anchorIndex...clickedIndex : clickedIndex...anchorIndex
            selectedTaskIDs = Set(range.map { filteredTasks[$0].id })
            // Anchor deliberately NOT updated here — see its doc comment.
            focusedTaskID = task.id
            return
        }

        if selectedTaskIDs.contains(task.id) {
            selectedTaskIDs.remove(task.id)
        } else {
            selectedTaskIDs.insert(task.id)
        }
        selectionAnchorID = task.id
        focusedTaskID = task.id
    }

    /// Handles ↑/↓ arrow key navigation in the list, with optional Shift to
    /// extend the range selection (macOS Finder/Mail convention):
    ///
    /// - **Plain arrow**: moves `focusedTaskID` one step and replaces the
    ///   entire selection with just that row (standard single-move nav).
    ///   Also resets `selectionAnchorID` to the new position so a
    ///   subsequent Shift+arrow extends from here, not some stale click.
    ///
    /// - **Shift+arrow**: moves `focusedTaskID` one step and extends the
    ///   range from the fixed `selectionAnchorID` to the new position,
    ///   matching how Shift+arrow works in Finder/Mail/Tables. The anchor
    ///   never moves during Shift-navigation — only plain moves reset it.
    private func handleArrowKey(direction: Int, shiftHeld: Bool) {
        guard !filteredTasks.isEmpty else { return }

        // Determine the row we're navigating *from*.
        let currentIndex: Int
        if let fid = focusedTaskID,
           let idx = filteredTasks.firstIndex(where: { $0.id == fid }) {
            currentIndex = idx
        } else {
            // Nothing focused yet — plain down starts at 0, plain up starts
            // at the last row; Shift-arrows do the same (no anchor, so they
            // behave like a plain move on first press).
            currentIndex = direction > 0 ? -1 : filteredTasks.count
        }

        let nextIndex = max(0, min(filteredTasks.count - 1, currentIndex + direction))
        let nextTask = filteredTasks[nextIndex]

        focusedTaskID = nextTask.id

        if shiftHeld, let anchor = selectionAnchorID,
           let anchorIndex = filteredTasks.firstIndex(where: { $0.id == anchor }) {
            // Extend the range from the fixed anchor to the new cursor row.
            let lo = min(anchorIndex, nextIndex)
            let hi = max(anchorIndex, nextIndex)
            selectedTaskIDs = Set((lo...hi).map { filteredTasks[$0].id })
        } else {
            // Plain move: select only the destination row and reset anchor.
            selectedTaskIDs = [nextTask.id]
            selectionAnchorID = nextTask.id
        }
    }

    private func selectAllVisible() {
        selectedTaskIDs = Set(filteredTasks.map(\.id))
        selectionAnchorID = filteredTasks.last?.id
        focusedTaskID = filteredTasks.last?.id
    }

    private func clearSelection() {
        selectedTaskIDs.removeAll()
        selectionAnchorID = nil
        focusedTaskID = nil
    }

    private func updatePinnedOrder() {
        for task in downloadManager.tasks + downloadManager.completedTasks where pinnedOrder[task.id] == nil {
            pinnedOrder[task.id] = task.createdAt
        }
    }

    /// The single source of truth ActiveSheet's own doc comment describes.
    /// A blocked download (.duplicateConflict) always wins over
    /// addDownloadsIntent/showingPasteURLs, which the person opened
    /// voluntarily and can afford to lose — if a conflict arrives while
    /// Add Downloads happens to be open, that sheet's content
    /// swaps to the more urgent one rather than the urgent one silently not
    /// showing. AddDownloadsView loses its in-progress form state in that
    /// case; a jarring but rare interruption is a better trade than a
    /// download hanging forever with nothing on screen explaining why.
    private var activeSheet: ActiveSheet? {
        if let conflict = downloadManager.pendingConflict { return .duplicateConflict(conflict) }
        if let request = pendingDelete { return .confirmDelete(request) }
        if let intent = addDownloadsIntent { return .addDownloads(intent) }
        if showingPasteURLs { return .pasteURLs }
        if browserSetup.isShowingFirstRunSheet { return .browserSetup }
        return nil
    }

    /// The one way a delete gets started. Raising a request instead of
    /// deleting on the spot is what makes the Delete key, the header buttons
    /// and the menu bar behave identically — previously only the row context
    /// menu asked anything at all.
    ///
    /// When every targeted task is trivially deletable (nothing on disk to
    /// discard, no finished file to decide the fate of), the confirmation
    /// sheet would have nothing to say beyond "deleted" — so this skips it
    /// and deletes immediately instead of prompting for a decision with no
    /// real content.
    private func requestDelete(_ taskIDs: Set<DownloadTask.ID>) {
        guard !taskIDs.isEmpty else { return }
        let all = downloadManager.tasks + downloadManager.completedTasks
        let plan = DeletionPlan(tasks: all.filter { taskIDs.contains($0.id) })
        if plan.isTriviallyDeletable {
            Task {
                let outcome = await downloadManager.delete(taskIDs: taskIDs, moveFilesToTrash: false)
                handleDeletion(outcome)
            }
            return
        }
        pendingDelete = DeleteRequest(
            taskIDs: taskIDs,
            preCheckTrash: NSEvent.modifierFlags.contains(.shift)
        )
    }

    /// Selection is cleared on the way out, not when the request is raised —
    /// cancelling the confirmation has to leave the person's careful
    /// multi-selection exactly as they built it.
    private func handleDeletion(_ outcome: DeletionOutcome) {
        selectedTaskIDs.removeAll()
        selectionAnchorID = nil
        focusedTaskID = nil
        if outcome.trashFailureCount > 0 {
            let files = outcome.trashFailureCount == 1 ? "1 file" : "\(outcome.trashFailureCount) files"
            showToast("Removed \(outcome.removedCount) from the list — \(files) couldn't be moved to the Trash.")
        } else if outcome.trashedCount > 0 {
            // Worth saying out loud: files leaving the disk is the one
            // outcome here with no other visible trace, and naming the Trash
            // is also how the person knows it's recoverable.
            let files = outcome.trashedCount == 1 ? "1 file" : "\(outcome.trashedCount) files"
            showToast("Removed \(outcome.removedCount) from the list — \(files) moved to the Trash.")
        }
    }
    
    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            sidebar
        } detail: {
            detailView
        }
        // SwiftUI holds the window at the sidebar plus list minimums, so
        // AppKit's own collapse-on-resize never gets a chance. Hiding the
        // sidebar just above that width lets the window keep shrinking.
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.sidebarCollapseWidth } action: { isNarrow in
            if isNarrow, sidebarVisibility != .detailOnly {
                sidebarHiddenForWidth = true
                withAnimation { sidebarVisibility = .detailOnly }
            } else if !isNarrow, sidebarHiddenForWidth {
                sidebarHiddenForWidth = false
                withAnimation { sidebarVisibility = .all }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: { addDownloadsIntent = AddDownloadsIntent(url: nil) }) {
                    Label("New Download", systemImage: "plus")
                }
                .help("Add a new download")
            }
        }
        // The single consolidated sheet presentation — see ActiveSheet's doc
        // comment for why this replaces four separate .sheet() modifiers.
        //
        // The set closure only needs to clear the two voluntarily-opened
        // cases: pendingConflict is never cleared here, matching the no-op
        // Binding setter this replaces — dismissal for it only ever happens
        // through resolveConflict, which is what
        // interactiveDismissDisabled() inside that view enforces. addDownloadsIntent/showingPasteURLs, by
        // contrast, dismiss normally (no interactiveDismissDisabled), so
        // SwiftUI calling this setter with nil for those is a real
        // dismissal that needs to actually clear the backing state.
        .sheet(item: Binding(
            get: { activeSheet },
            set: { newValue in
                if newValue == nil {
                    addDownloadsIntent = nil
                    showingPasteURLs = false
                    pendingDelete = nil
                }
            }
        )) { sheet in
            switch sheet {
            case .duplicateConflict(let conflict):
                DuplicateDownloadSheet(conflict: conflict)
                    .environmentObject(downloadManager)
                    .environmentObject(downloadManager)
            case .confirmDelete(let request):
                DeleteConfirmationSheet(request: request, onComplete: handleDeletion)
                    .environmentObject(downloadManager)
            case .addDownloads(let intent):
                AddDownloadsView(initialURL: intent.url)
                    .environmentObject(downloadManager)
            case .pasteURLs:
                AddDownloadsView()
                    .environmentObject(downloadManager)
            case .browserSetup:
                BrowserSetupSheet()
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search downloads")
        // The menu bar's "New Download..." (⌘N) and "Paste URLs..." (⌘⇧V)
        // commands (see ConvoyApp.swift) post these notifications
        // rather than driving @State directly — SwiftUI's App-level Commands
        // and this view live in different parts of the view tree, so a
        // notification is the standard bridge between them.
        .onReceive(NotificationCenter.default.publisher(for: .newDownload)) { _ in
            addDownloadsIntent = AddDownloadsIntent(url: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pasteURLs)) { _ in
            showingPasteURLs = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .deleteAllCompleted)) { _ in
            requestDelete(Set(downloadManager.completedTasks.map(\.id)))
        }
        // The browser extension's YouTube download button (via
        // NativeMessagingHost -> convoy://add?url=... -> onOpenURL in
        // ConvoyApp.swift) lands here. Reuses the same sheet/state as
        // the toolbar's "+ New Download" button, just pre-populated —
        // AddDownloadsView's own init parses and kicks off the yt-dlp
        // format fetch immediately, so the picker is already loading by the
        // time the sheet animates in.
        .onReceive(NotificationCenter.default.publisher(for: .openYouTubeDownload)) { note in
            guard let url = note.userInfo?["url"] as? String else { return }
            appLogger.info("ContentView.onReceive openYouTubeDownload \(url)")
            // Consume the parked copy too, so the .onAppear drain below can't
            // then open a second, duplicate sheet for the same hand-off.
            _ = PendingOpenIntent.shared.takeYouTubeURL()
            presentYouTubeDownload(url)
        }
        // Cold-launch companion to the notification above. When the latch
        // launches a closed app, the URL can arrive before the subscription
        // above exists — see PendingOpenIntent. Draining on appear covers that
        // ordering; whichever path wins, the other finds nothing left to do.
        .onAppear {
            if let parked = PendingOpenIntent.shared.takeYouTubeURL() {
                appLogger.info("ContentView.onAppear drained parked \(parked)")
                presentYouTubeDownload(parked)
            }
        }
        // Fired by DownloadManager when Start/Resume/Resume All gets
        // blocked purely by the concurrency limit — explains why the click
        // didn't visibly do anything, and how to change it. Deliberately
        // steps, not a button that opens Settings itself.
        .onReceive(NotificationCenter.default.publisher(for: .concurrencyLimitReached)) { _ in
            showToast("Limit reached (\(downloadManager.maxConcurrentDownloads) at a time) — raise it in Settings → Downloads.")
        }
        // A filename conflict just became the one shown in the sheet above
        // — it's stuck waiting on a decision and, unlike a silent capture,
        // can sit unseen behind other windows indefinitely if nothing
        // brings the app forward for it. Gated by alwaysFocusForRequiredInput
        // specifically, not bringWindowToFrontOnCapture — see AppSettings.
        .onReceive(NotificationCenter.default.publisher(for: .downloadConflictNeedsAttention)) { _ in
            if AppSettings.shared.alwaysFocusForRequiredInput {
                MainWindowTracker.shared.showMainWindow()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            BottomBannerStack(toastMessage: toastMessage, onDismissToast: dismissToast)
                .padding(.bottom, 16)
                .padding(.trailing, 16)
                .zIndex(1)
        }
    }
    
    /// Coalesces rapid-fire triggers (e.g. "Resume All" hitting the limit
    /// for several tasks back to back) into one banner with a reset timer,
    /// rather than stacking or replaying several in quick succession.
    private func showToast(_ message: String) {
        toastDismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            toastMessage = message
        }
        toastDismissTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                toastMessage = nil
            }
        }
    }
    
    private func dismissToast() {
        toastDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = nil
        }
    }

    private var hasActiveDownloads: Bool {
        downloadManager.tasks.contains { task in
            task.status == .downloading || task.status == .starting
            || task.status == .validating || task.status == .refreshingLink
        }
    }

    private var hasResumableDownloads: Bool {
        downloadManager.tasks.contains { task in
            task.status == .waiting || task.status == .paused
        }
    }
    
    private var sidebar: some View {
        List(selection: $selectedCategory) {
            ForEach(DownloadCategory.allCases) { category in
                HStack {
                    Label {
                        Text(category.displayName)
                    } icon: {
                        SidebarIcon(systemName: category.icon)
                    }
                    .fontWeight(selectedCategory == category ? .semibold : .regular)
                    
                    Spacer(minLength: 8)
                    
                    let count = badgeCount(for: category)
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .contentShape(Rectangle())
                .tag(category)
            }
        }
        .navigationTitle("Downloads")
        .listStyle(.sidebar)
        // On macOS 27 a click on a row selects it without focusing the list
        // (FB24855120); only empty space does. The click does it here.
        .background(ClickMonitor { clicked in
            guard let table = sequence(first: clicked, next: \.superview).first(where: { $0 is NSTableView }),
                  table.window?.firstResponder !== table
            else { return }
            table.window?.makeFirstResponder(table)
        })
        // A category is a new set of rows, as a new folder is in Finder: the
        // old selection goes, so Delete can't act on rows no longer shown.
        .onChange(of: selectedCategory) { clearSelection() }
        .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
    }
    
    private var detailView: some View {
        Group {
            if filteredTasks.isEmpty {
                emptyState
            } else {
                listWithHeader
            }
        }
        // With the sidebar's minimum, this sets the window's smallest size;
        // hiding the sidebar lets it go narrower still.
        .frame(minWidth: 460, minHeight: 400)
    }

    /// The header is a bar over the list rather than stacked above it, so the
    /// list runs up under the toolbar the way the system expects; otherwise
    /// full screen draws an opaque band behind the toolbar.
    private var listWithHeader: some View {
        downloadsList.safeAreaInset(edge: .top, spacing: 0) {
            downloadsHeader.background(.bar)
        }
    }

    /// Extracted from `detailView` so the Swift type-checker doesn't time
    /// out on the combined stack + modifier chain in one expression.
    ///
    /// A lazy stack, not `List`: the rows draw their own selection, hover and
    /// menus, so `List` added only separators and insets — and its
    /// NSTableView bridge could latch a newly inserted row at the table's
    /// default 24pt height until the next scroll (still so on macOS 27).
    /// Laid out by SwiftUI, a row is always as tall as its content.
    private var downloadsList: some View {
        let tasks = filteredTasks
        return ScrollViewReader { proxy in
            ScrollView {
                downloadRows(tasks)
            }
            // Focus follows the click, as in Mail: a click anywhere in the
            // list gives it focus, and the keys and Edit menu act on it.
            .background(ListKeyResponder(
                canSelectAll: !tasks.isEmpty,
                canDelete: !selectedTaskIDs.isEmpty,
                // With nothing selected, ↓ selects the first row and ↑ the
                // last (handleArrowKey), as in Finder.
                onArrow: { direction, extend in
                    handleArrowKey(direction: direction, shiftHeld: extend)
                    // Minimum scroll that shows the row, as Finder does.
                    if let focusedTaskID { proxy.scrollTo(focusedTaskID) }
                },
                onEscape: clearSelection,
                onDelete: { requestDelete(selectedTaskIDs) },
                onSelectAll: selectAllVisible,
                onFocusChange: { focused in
                    if isListFocused != focused { isListFocused = focused }
                }
            ))
        }
        // No background of its own: the list sits on the same pane as the
        // header above it. A controlBackgroundColor fill here matched in light
        // mode but drew a darker block under the header in dark mode.
        .onAppear { updatePinnedOrder() }
        // Catches new downloads added while this view is already on screen
        // (onAppear alone only covers the initial appearance).
        .onChange(of: downloadManager.tasks.count) { updatePinnedOrder() }
        .onChange(of: downloadManager.completedTasks.count) { updatePinnedOrder() }
    }

    private func downloadRows(_ tasks: [DownloadTask]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(tasks) { task in
                DownloadRowView(
                    task: task,
                    isSelected: selectedTaskIDs.contains(task.id),
                    isEmphasized: isListFocused,
                    isSelectionModeActive: isSelectionModeActive,
                    onSelect: { (shiftHeld: Bool, commandHeld: Bool) in
                        handleSelection(of: task, shiftHeld: shiftHeld, commandHeld: commandHeld)
                    },
                    onRequestDelete: { requestDelete([task.id]) }
                )
                .environmentObject(downloadManager)
                .padding(Self.rowInsets)
                // Over the row's bottom edge rather than stacked after it,
                // so rows keep the same pitch; inset to the title, and
                // none after the last row, as the plain List drew them.
                .overlay(alignment: .bottom) {
                    if task.id != tasks.last?.id {
                        Divider().padding(.leading, Self.rowInsets.leading + DownloadRowView.textLeading)
                    }
                }
                // What List gave assistive tech for free: each download is
                // one item, not a run of loose text and buttons.
                .accessibilityElement(children: .contain)
                .accessibilityLabel(task.filename)
                .id(task.id)
            }
        }
    }

    /// Measured from the plain List this replaced on macOS 27 (8 leading, 9
    /// trailing, 4 above and below each row), rounded to even sides.
    /// Above the sidebar and list minimums combined (170 + 460).
    private static let sidebarCollapseWidth: CGFloat = 720

    private static let rowInsets = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)

    private var downloadsHeader: some View {
        HStack {
            Text(downloadsHeaderTitle)
                .font(.title3.weight(.semibold))
                .fixedSize()

            Spacer()

            // Titled buttons while they fit, icons with their help text when
            // the window is too narrow.
            ViewThatFits(in: .horizontal) {
                headerActions.labelStyle(.titleAndIcon)
                headerActions.labelStyle(.iconOnly)
            }
        }
        .frame(height: 32)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var headerActions: some View {
        HStack {
            if !selectedTaskIDs.isEmpty {
                Button(action: { requestDelete(selectedTaskIDs) }) {
                    Label("Delete Selected (\(selectedTaskIDs.count))", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help("Delete the selected downloads")

                Button(action: clearSelection) {
                    Label("Clear Selection", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .help("Clear the selection")
            } else if selectedCategory == .completed, !downloadManager.completedTasks.isEmpty {
                // "Delete", not "Clear", in both category buttons: the
                // underlying operation is identical to the row's Delete, and
                // a gentler verb for the same destruction was its own kind of
                // lie — especially for failed downloads, whose partial bytes
                // a retry would otherwise have resumed from.
                Button(action: { requestDelete(Set(downloadManager.completedTasks.map(\.id))) }) {
                    Label("Delete All Completed", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help("Delete all completed downloads")
            } else if selectedCategory == .failed, !downloadManager.failedTasks.isEmpty {
                Button(action: { requestDelete(Set(downloadManager.failedTasks.map(\.id))) }) {
                    Label("Delete All Failed", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help("Delete all failed downloads")
            } else if hasActiveDownloads {
                Button(action: { Task { await downloadManager.pauseAll() } }) {
                    Label("Pause All", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
                .help("Pause all active downloads")
            } else if hasResumableDownloads {
                Button(action: { Task { await downloadManager.resumeAll() } }) {
                    Label("Resume All", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .help("Resume queued and paused downloads")
            }
        }
    }

    private var downloadsHeaderTitle: String {
        selectedCategory == .all ? "All Downloads" : selectedCategory.displayName
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: selectedCategory.icon)
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            
            Text(selectedCategory.emptyTitle)
                .font(.title2)
                .fontWeight(.medium)
            
            Text(selectedCategory.emptyMessage)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            if selectedCategory == .all {
                Button("Start New Download") {
                    addDownloadsIntent = AddDownloadsIntent(url: nil)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    /// Opens the Add Downloads sheet pre-filled with a YouTube watch URL.
    /// A single assignment — `.sheet(item:)` delivers the URL to the sheet's
    /// content closure as a parameter, so unlike the previous Bool + separate
    /// URL state there's no write-ordering hazard, and no need to close and
    /// reopen the sheet to force a fresh view identity.
    private func presentYouTubeDownload(_ url: String) {
        appLogger.info("presentYouTubeDownload setting intent for \(url)")
        addDownloadsIntent = AddDownloadsIntent(url: url)
    }

    private func badgeCount(for category: DownloadCategory) -> Int {
        let tasks = downloadManager.tasks
        let completed = downloadManager.completedTasks
        switch category {
        case .all: return tasks.count + completed.count
        case .downloading: return tasks.filter { $0.status == .downloading }.count
        case .completed: return completed.count
        case .paused: return tasks.filter { $0.status == .paused }.count
        case .failed: return tasks.filter {
            if case .failed = $0.status { return true }
            return false
        }.count
        }
    }
}

/// A small, self-dismissing banner for explaining a blocked action —
/// deliberately not a system notification (stays in-app, doesn't need
/// Notification Center permission) and not an inline row detail (this is a
/// one-off "here's why that click didn't work" moment, not a persistent
/// state worth taking up space in every row indefinitely).
private struct ToastBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        BannerCard(systemImage: "exclamationmark.circle.fill", iconColor: .orange, onDismiss: onDismiss) {
            Text(message)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }
}

/// Layout shared by the bottom-trailing banners, so they cannot drift apart.
private struct BannerCard<Content: View>: View {
    let systemImage: String
    let iconColor: Color
    let onDismiss: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(iconColor)

            content

            Spacer(minLength: 6)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
    }
}

/// The bottom-trailing banners, stacked so they can never overlap.
///
/// Its own view rather than an inline overlay: ContentView's body was already
/// at the type-checker's limit, and this keeps the storage notice's settings
/// observation out of it.
private struct BottomBannerStack: View {
    let toastMessage: String?
    let onDismissToast: () -> Void

    @EnvironmentObject private var downloadManager: DownloadManager
    @ObservedObject private var settings = AppSettings.shared
    /// Session-only: the notice returns on the next launch while the files
    /// are still there, so nothing about this is worth persisting.
    @State private var storageNoticeDismissed = false
    @ObservedObject private var helperAutoUpdate = HelperAutoUpdate.shared
    /// Same reasoning: still stale next launch, still worth saying once.
    @State private var helperNoticeDismissed = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if case .waiting(let reason) = helperAutoUpdate.state, !helperNoticeDismissed {
                StaleHelpersBanner(reason: reason) { helperNoticeDismissed = true }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if showStorageNotice {
                TemporaryStorageBanner(bytes: downloadManager.orphanedTemporaryBytes) {
                    storageNoticeDismissed = true
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if let toastMessage {
                ToastBanner(message: toastMessage, onDismiss: onDismissToast)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var showStorageNotice: Bool {
        guard !storageNoticeDismissed else { return false }
        return TemporaryStorageNotice.stillShows(
            dueAtLaunch: downloadManager.temporaryStorageNoticeDueAtLaunch,
            orphanedBytes: downloadManager.orphanedTemporaryBytes,
            thresholdBytes: TemporaryStorageNotice.bytes(
                fromGB: settings.temporaryFilesNoticeThresholdGB
            )
        )
    }
}

/// Says that a Convoy update brought newer YouTube helpers that aren't
/// installed yet.
///
/// Only ever shown when they were not fetched automatically — turned off, or
/// a metered connection. When they update by themselves nothing is said,
/// because nothing needs doing.
private struct StaleHelpersBanner: View {
    let reason: HelperAutoUpdate.Reason
    let onDismiss: () -> Void

    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsSelectedSection") private var selectedSectionName = "general"

    var body: some View {
        BannerCard(systemImage: "arrow.down.circle", iconColor: .secondary, onDismiss: onDismiss) {
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open YouTube Settings") {
                    selectedSectionName = "youtube"
                    openSettings()
                    onDismiss()
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
            }
        }
    }

    private var message: String {
        switch reason {
        case .turnedOff:
            "This update includes newer YouTube helpers. Reinstall them to stay current."
        case .meteredConnection:
            "Newer YouTube helpers are waiting for a connection that isn't metered."
        case .failed:
            "Couldn't update the YouTube helpers. Convoy will try again next time it opens."
        }
    }
}

/// Says that leftovers from a crashed run are taking up disk, and opens the
/// control that clears them.
///
/// Persistent rather than self-dismissing, unlike `ToastBanner`: this is a
/// standing condition, not a reaction to a click. When it may appear is
/// `TemporaryStorageNotice`'s call.
private struct TemporaryStorageBanner: View {
    let bytes: Int64
    let onDismiss: () -> Void

    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsSelectedSection") private var selectedSectionName = "general"

    var body: some View {
        BannerCard(systemImage: "internaldrive", iconColor: .secondary, onDismiss: onDismiss) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(formatted) of temporary files can be cleared.")
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open Storage Settings") {
                    selectedSectionName = "advanced"
                    openSettings()
                    onDismiss()
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
            }
        }
    }

    private var formatted: String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

/// A sidebar icon in an explicit color instead of the sidebar's own tint.
/// On macOS 27 the tinted icons drop out for frames in Mission Control and
/// at launch with a half-point sidebar width; a plain color draws in both.
/// Follows the tint's states: white on an emphasized selection, grey in an
/// inactive window.
private struct SidebarIcon: View {
    let systemName: String
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Image(systemName: systemName)
            .foregroundStyle(color)
    }

    private var color: Color {
        if prominence == .increased { return .white }
        return appearsActive ? .accentColor : .secondary
    }
}

enum DownloadCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case downloading = "Downloading"
    case completed = "Completed"
    case paused = "Paused"
    case failed = "Failed"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .all: return "tray.full"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle"
        case .paused: return "pause.circle"
        case .failed: return "exclamationmark.circle"
        }
    }
    
    var displayName: String { rawValue }
    
    var emptyTitle: String {
        switch self {
        case .all: return "No Downloads Yet"
        case .downloading: return "Nothing Downloading"
        case .completed: return "No Completed Downloads"
        case .paused: return "No Paused Downloads"
        case .failed: return "No Failed Downloads"
        }
    }
    
    var emptyMessage: String {
        switch self {
        case .all: return "Click the + button or press ⌘N to add your first download"
        case .downloading: return "Downloads in progress will appear here"
        case .completed: return "Completed downloads will be listed here"
        case .paused: return "Paused downloads can be resumed from here"
        case .failed: return "Failed downloads will appear here for retry"
        }
    }
}
