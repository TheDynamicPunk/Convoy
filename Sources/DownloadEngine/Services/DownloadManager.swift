import Foundation
import Combine
import OSLog

@MainActor
public final class DownloadManager: ObservableObject {
    public static let shared = DownloadManager()

    private let logger = Logger(subsystem: "Convoy", category: "DownloadManager")

    @Published public private(set) var tasks: [DownloadTask] = []
    @Published public private(set) var completedTasks: [DownloadTask] = []
    @Published public private(set) var activeCount: Int = 0
    @Published public private(set) var totalSpeed: Int64 = 0
    /// Orphaned temp-folder leftovers, in bytes. Measured at launch, when the
    /// Storage settings appear, and after a clear.
    @Published public internal(set) var orphanedTemporaryBytes: Int64 = 0
    /// Whether the launch measurement was over the notice threshold. Decided
    /// once; later measurements can hide the notice but never raise it.
    @Published public private(set) var temporaryStorageNoticeDueAtLaunch = false
    
    private let settings = AppSettings.shared
    /// Read live from settings rather than captured once at init — a
    /// change to the concurrent-download limit should apply immediately,
    /// not require relaunching the app. See the settings.objectWillChange
    /// subscription in init() below for how newly-available capacity
    /// actually gets *used* once the limit rises, since nothing else would
    /// notice on its own until some unrelated download happens to finish.
    private var maxConcurrent: Int { settings.maxConcurrentDownloads }
    /// Public read-only mirror of the above, for UI that needs to explain
    /// *why* a task is queued (see DownloadRowView's .waiting state)
    /// without reaching into AppSettings directly and duplicating
    /// knowledge of where this number actually comes from.
    public var maxConcurrentDownloads: Int { maxConcurrent }
    private var activeTasks: Set<UUID> = []
    private var statusObservers: [UUID: AnyCancellable] = [:]
    private var settingsObserver: AnyCancellable?
    
    /// The conflict currently shown in the sheet. Nil when no conflict is
    /// pending. Managed exclusively by enqueueConflict / resolveConflict.
    ///
    /// Posts .downloadConflictNeedsAttention whenever a *new* conflict
    /// becomes the one on screen — both the first time (queue was empty)
    /// and every time resolveConflict advances to the next queued one.
    /// DownloadEngine has no AppKit dependency to bring a window forward
    /// itself, so this is the same notification-based hand-off
    /// .concurrencyLimitReached already uses to reach the app layer;
    /// Convoy's ContentView is what actually calls
    /// MainWindowTracker, gated by AppSettings.alwaysFocusForRequiredInput.
    @Published public private(set) var pendingConflict: DuplicateDownloadConflict? {
        didSet {
            guard let pendingConflict, pendingConflict.id != oldValue?.id else { return }
            NotificationCenter.default.post(name: .downloadConflictNeedsAttention, object: nil)
        }
    }
    /// Queue of unresolved conflicts — at most one sheet is shown at a time.
    /// Subsequent conflicts pile up here and are shown in arrival order once
    /// the user resolves the front one.
    private var conflictQueue: [DuplicateDownloadConflict] = []

    /// Suspended callers of resolveLateIdentity, one per pending conflict,
    /// keyed by the conflict's own id. resolveConflict resumes the matching
    /// entry the instant the person answers the sheet — that's the only
    /// thing that still needs to happen synchronously; everything else
    /// (cancelling the loser, reclaiming a name) now runs on the resumed
    /// side, right where the full context already lives. See
    /// resolveLateIdentity.
    private var conflictWaiters: [UUID: CheckedContinuation<ConflictResolution, Never>] = [:]

    private let listLock = DownloadListLock(beside: DownloadManager.persistenceURL)
    /// Set when the list on disk couldn't be read and couldn't be moved aside
    /// either — the one case where saving would destroy it.
    private var listIsUnreadable = false
    /// False when another running copy owns the list; this one then never
    /// reads or writes it.
    public var ownsDownloadList: Bool { !listLock.isHeldElsewhere }

    private init() {
        if ownsDownloadList {
            loadPersistedTasks()
            Task { await measureTemporaryStorageAtLaunch() }
        } else {
            logger.notice("another process owns the download list; not loading it")
        }

        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            // Synchronous, unlike the Task below: downloadManager's own
            // objectWillChange is just a "something changed, re-render"
            // signal for SwiftUI — it doesn't read any value itself, so
            // there's no stale-value risk in firing it immediately. Needed
            // because maxConcurrentDownloads is a plain computed property.
            // not @Published, so nothing would otherwise tell views like
            // DownloadRowView's "Queued — all N slots in use" text to
            // re-read it after a Settings change that doesn't happen to
            // also start or stop a download (which would trigger a
            // re-render incidentally via activeCount).
            self?.objectWillChange.send()
            
            // Deferred via Task rather than run synchronously here:
            // objectWillChange fires just *before* the underlying
            // @AppStorage value actually updates, so reading
            // settings.maxConcurrentDownloads directly in this closure
            // would still see the OLD value. The Task hop (same pattern as
            // the speed timer below) runs after the synchronous property
            // write completes. Fires on every settings change, not just
            // this one field — harmless since startAllWaitingWithinCapacity()
            // is a no-op when there's nothing waiting or no spare capacity,
            // and AppStorage doesn't expose a per-property publisher to
            // filter this to just maxConcurrentDownloads more precisely.
            Task { @MainActor in
                self?.startAllWaitingWithinCapacity()
            }
        }
    }
    
    /// skipConflictCheck suppresses the filename-match check — used internally
    /// for retry and conflict-resolution paths where the caller has already
    /// verified or cleared the conflict, so we don't loop back into the sheet.
    public func addDownload(url: URL, destination: URL? = nil, filenameSource: FilenameSource? = nil, segmentCount: Int? = nil, customHeaders: [String: String] = [:], referrerURL: URL? = nil, skipConflictCheck: Bool = false) async throws -> DownloadTask {
        let source = filenameSource ?? (destination == nil ? .originalURL : .userProvided)
        var dest = normalizedDestination(destination, fallbackURL: url)
        // Captured before any deduplication touches dest — this, not
        // dest.lastPathComponent, is what every future request compares
        // against. See DownloadTask.originalName's doc comment.
        let originalName = dest.lastPathComponent
        let segments = segmentCount ?? settings.defaultSegmentCount
        let startsAutomatically = settings.autoStartDownloads

        // Conflict check: if another task (active or completed) already
        // looks like the same download — same source URL, or the same
        // original name — show the resolution sheet instead of silently
        // proceeding. skipConflictCheck lets internal callers (retry,
        // resolveConflict) bypass this.
        if !skipConflictCheck, let existing = existingTask(matchingURL: url, originalName: originalName) {
            // Based on the EXISTING task's own name, not the incoming
            // request's — the incoming side may have resolved a worse name
            // for this particular request (e.g. a title-attribution miss on
            // a repeat capture) even though it's genuinely the same video.
            // "Save as X (1)" should read as "another copy of the download
            // you can already see," not introduce a second, unrelated-looking
            // name for what the person clearly recognizes as a duplicate.
            let altName = deduplicatedDestination(for: existing.destinationURL).lastPathComponent
            enqueueConflict(DuplicateDownloadConflict(
                incomingURL: url,
                incomingHeaders: customHeaders,
                incomingReferrer: referrerURL,
                incomingDestination: dest,
                incomingFilenameSource: source,
                existingTask: existing,
                suggestedAlternativeName: altName,
                resolvingTaskID: nil
            ))
            throw DownloadConflictError()
        }
        // Nothing in the app's own list claims this — still worth checking
        // against a stray file already sitting on disk (e.g. from a task no
        // longer tracked) so this doesn't silently overwrite it.
        dest = deduplicatedDestination(for: dest)
        
        let task = DownloadTask(
            url: url,
            destinationURL: dest,
            originalName: originalName,
            segmentCount: segments,
            // If automatic starting is off, this is deliberately paused:
            // "Waiting" is reserved for an automatic download queued behind
            // the concurrency limit.
            initialStatus: startsAutomatically ? .waiting : .paused,
            customHeaders: customHeaders,
            referrerURL: referrerURL,
            // destination was non-nil → caller named the file explicitly
            // (extension popup, YouTube format chooser, manual paste). The
            // streaming probe's Content-Disposition then must NOT rewrite
            // userProvidedDestinationName, mirroring Chrome's refusal to
            // override a name the user typed. defaultDestination (URL path)
            // is the false branch, so Content-Disposition does win there.
            filenameSource: source
        )
        task.markDestinationMissingIfNeeded()
        
        observeStatus(of: task)
        tasks.append(task)
        savePersistedTasks()
        
        if startsAutomatically, task.status == .waiting {
            Task { try? await startDownload(task) }
        }
        
        return task
    }
    
    public func addDownloads(urls: [URL], destination: URL? = nil) async throws {
        for url in urls {
            // try? so a conflict on one URL (which throws DownloadConflictError
            // and queues a sheet) doesn't abort the rest of the batch.
            _ = try? await addDownload(url: url, destination: destination)
        }
    }

    /// Adds a YouTube download that yt-dlp performs end to end — fetching the
    /// chosen format, pulling an audio track and muxing when the format is
    /// video-only, and writing one finished file.
    ///
    /// One task, not two — yt-dlp does its own merging internally, so there's
    /// no separate audio-track task for this app to track or pair up. See
    /// YouTubeDownloader for why YouTube can't go through the probe/segment
    /// engine at all any more.
    ///
    /// `formatID` is what yt-dlp is asked for: the format id the user picked,
    /// or for an audio-only pick on a dubbed video, a language selector (see
    /// `YouTubeResolver.audioSelector`). `mergeAudio` is the audio track to
    /// pair with a video-only pick, or nil for a format that already carries
    /// sound.
    ///
    /// The selector is comma-joined ("137,140"), not plus-joined ("137+140").
    /// A plus tells yt-dlp to merge, and yt-dlp merges with ffmpeg; a comma
    /// asks for two separate files, which `YouTubeDownloader` then merges
    /// through AVFoundation. That one character is why this app ships no
    /// ffmpeg at all.
    ///
    /// `videoBytes`/`audioBytes` are the sizes the resolver already reported.
    /// Seeding the task's total with their sum is what lets a two-file
    /// download show one continuous percentage — see `TwoFileProgress`.
    public func addYouTubeDownload(
        pageURL: URL,
        formatID: String,
        mergeAudio: MergeAudio?,
        videoBytes: Int64?,
        destination: URL,
        filenameSource: FilenameSource = .extractorMetadata,
        skipConflictCheck: Bool = false
    ) async throws -> DownloadTask {
        let startsAutomatically = settings.autoStartDownloads
        let selector = mergeAudio.map { "\(formatID),\($0.selector)" } ?? formatID

        // Captured before any deduplication touches the destination, exactly
        // as addDownload and addStreamDownload do. A YouTube name is known and
        // final the moment a quality is picked — title plus quality token —
        // so, like a stream's, it never needs a later mid-flight recheck.
        let originalName = destination.lastPathComponent

        // Conflict check — the same duplicate detection as the other two add
        // paths, which this one skipped entirely until now. Without it,
        // downloading a video you already had did not ask: MediaMuxer clears
        // its output path before exporting, so the finished file was replaced
        // with no prompt and no "(1)".
        if !skipConflictCheck,
           let existing = existingTask(
               matchingURL: pageURL, originalName: originalName, youTubeFormatSelector: selector
           ) {
            // Based on the existing task's own name rather than this
            // request's — see addDownload/addStreamDownload for why.
            let altName = deduplicatedDestination(for: existing.destinationURL).lastPathComponent
            enqueueConflict(DuplicateDownloadConflict(
                incomingURL: pageURL,
                incomingHeaders: [:],
                incomingReferrer: pageURL,
                incomingDestination: destination,
                incomingFilenameSource: filenameSource,
                existingTask: existing,
                suggestedAlternativeName: altName,
                resolvingTaskID: nil,
                incomingYouTubeInfo: .init(
                    formatID: formatID, mergeAudio: mergeAudio, videoBytes: videoBytes
                )
            ))
            throw DownloadConflictError()
        }
        let dest = deduplicatedDestination(for: destination)
        // Only when both halves are known: a partial sum would be worse than
        // no estimate, since the total would still have to grow later.
        let expectedTotal: Int64 = {
            guard let mergeAudio else { return videoBytes ?? 0 }
            guard let videoBytes, let audioBytes = mergeAudio.filesizeBytes else { return 0 }
            return videoBytes + audioBytes
        }()

        let task = DownloadTask(
            url: pageURL,
            destinationURL: dest,
            originalName: originalName,
            segmentCount: 1,
            initialStatus: startsAutomatically ? .waiting : .paused,
            totalBytes: expectedTotal,
            referrerURL: pageURL,
            filenameSource: filenameSource
        )
        task.configureYouTubeDownload(formatSelector: selector, pageURL: pageURL)
        task.markDestinationMissingIfNeeded()

        observeStatus(of: task)
        tasks.append(task)
        savePersistedTasks()

        if startsAutomatically {
            Task { try? await startDownload(task) }
        }
        return task
    }

    /// Adds a native HLS or DASH stream download.
    ///
    /// Unlike `addDownload` (which treats the URL as a plain file for the
    /// byte-range engine), this routes through `StreamDownloader`, which
    /// fetches the manifest, parses segments, downloads them in parallel,
    /// decrypts if needed, and assembles the final file.
    ///
    /// - streamType: `"hls"` for HLS variant playlists (`.m3u8`) or
    ///   `"dash"` for DASH manifests (`.mpd`).
    /// - representationId / bandwidth: DASH Representation selection hints
    ///   sent by the browser extension alongside the manifest URL.
    @discardableResult
    public func addStreamDownload(
        url: URL,
        streamType: String,
        destination: URL? = nil,
        filenameSource: FilenameSource? = nil,
        customHeaders: [String: String] = [:],
        referrerURL: URL? = nil,
        representationId: String? = nil,
        bandwidth: Int? = nil,
        preferredAudioLanguage: String? = nil,
        hlsAudioTracks: [HLSAudioCandidate]? = nil,
        skipConflictCheck: Bool = false
    ) async throws -> DownloadTask {
        let source = filenameSource ?? (destination == nil ? .originalURL : .userProvided)
        var dest = normalizedDestination(destination, fallbackURL: url)
        // Captured before any deduplication touches dest. For a stream this
        // is available and correct instantly (the browser extension's
        // resolved title) — unlike the byte-range engine's extension, a
        // stream's identity never needs a later mid-flight recheck.
        let originalName = dest.lastPathComponent
        let startsAutomatically = settings.autoStartDownloads
        let audioLanguage = preferredAudioLanguage ?? settings.preferredAudioLanguage.nilIfEmpty

        // Conflict check — same duplicate-detection as addDownload.
        if !skipConflictCheck, let existing = existingTask(matchingURL: url, originalName: originalName) {
            // See addDownload's matching comment — base the suggestion on
            // the existing task's own name, not this request's potentially
            // worse one (e.g. a title-attribution miss on a repeat capture
            // of the same stream).
            let altName = deduplicatedDestination(for: existing.destinationURL).lastPathComponent
            enqueueConflict(DuplicateDownloadConflict(
                incomingURL: url,
                incomingHeaders: customHeaders,
                incomingReferrer: referrerURL,
                incomingDestination: dest,
                incomingFilenameSource: source,
                existingTask: existing,
                suggestedAlternativeName: altName,
                resolvingTaskID: nil,
                incomingStreamInfo: .init(
                    streamType: streamType,
                    representationId: representationId,
                    bandwidth: bandwidth,
                    preferredAudioLanguage: audioLanguage,
                    hlsAudioTracks: hlsAudioTracks
                )
            ))
            throw DownloadConflictError()
        }
        dest = deduplicatedDestination(for: dest)

        let task = DownloadTask(
            url: url,
            destinationURL: dest,
            originalName: originalName,
            // segmentCount controls concurrent segment connections in
            // StreamDownloader — same user-visible setting, same semantics.
            segmentCount: settings.defaultSegmentCount,
            initialStatus: startsAutomatically ? .waiting : .paused,
            customHeaders: customHeaders,
            referrerURL: referrerURL,
            filenameSource: source
        )
        task.configureStreamDownload(
            streamURL: url,
            streamType: streamType,
            customHeaders: customHeaders,
            representationId: representationId,
            bandwidth: bandwidth,
            preferredAudioLanguage: audioLanguage,
            hlsAudioTracks: hlsAudioTracks
        )
        task.markDestinationMissingIfNeeded()

        observeStatus(of: task)
        tasks.append(task)
        savePersistedTasks()

        if startsAutomatically, task.status == .waiting {
            Task { try? await startDownload(task) }
        }
        return task
    }

    public func startDownload(_ task: DownloadTask) async throws {
        // Do this before considering capacity. A missing folder is a blocked
        // state, not a queued download, even when every slot is in use.
        guard !task.markDestinationMissingIfNeeded() else { return }

        guard activeCount < maxConcurrent else {
            notifyBlockedByCapacity()
            return
        }
        
        activeTasks.insert(task.id)
        activeCount += 1
        
        do {
            try await task.start()

            // Some start conditions are reported through task status rather
            // than by throwing. Anything that ends not actively downloading
            // (blocked, failed, expired, or paused while starting) must hand
            // its slot back here — otherwise a dead task holds a concurrency
            // slot forever and later downloads queue up behind nothing. The
            // .destinationMissing case was the original instance of this;
            // .failed/.urlExpired/.cancelled reached here too (a 403-retry
            // budget running out returns normally, as does an expired
            // non-YouTube link) and used to leak their slot. releaseActiveSlot
            // is set-guarded, so releasing a slot something else already
            // freed (e.g. a user-pause racing the start) is a safe no-op.
            switch task.status {
            case .destinationMissing, .failed, .urlExpired, .cancelled, .paused:
                releaseActiveSlot(for: task)
                startNextQueued()
            default:
                break
            }
        } catch {
            releaseActiveSlot(for: task)
            startNextQueued()
            throw error
        }
    }
    
    public func pauseDownload(_ task: DownloadTask) async {
        await task.pause()
        releaseActiveSlot(for: task)
        startNextQueued()
    }
    
    public func resumeDownload(_ task: DownloadTask) async throws {
        guard !task.markDestinationMissingIfNeeded() else { return }

        guard activeCount < maxConcurrent else {
            // Every slot's in use — don't just silently leave this task
            // .paused with no path back to running. Flip it to .waiting so
            // it auto-starts the moment a slot frees, same as a task that
            // hit the limit naturally.
            task.markWaitingForCapacity()
            notifyBlockedByCapacity()
            return
        }
        
        activeTasks.insert(task.id)
        activeCount += 1

        do {
            try await task.resume()
            // Same reasoning as startDownload's post-start release — see the
            // comment there. resume() delegates to start(), which can land
            // the task in a non-running terminal/blocked state without
            // throwing (expired YouTube retry budget, urlExpired flip, etc.).
            switch task.status {
            case .destinationMissing, .failed, .urlExpired, .cancelled, .paused:
                releaseActiveSlot(for: task)
                startNextQueued()
            default:
                break
            }
        } catch {
            releaseActiveSlot(for: task)
            startNextQueued()
            throw error
        }
    }
    
    public func cancelDownload(_ task: DownloadTask) async {
        await task.cancel()
        releaseActiveSlot(for: task)
        removeTask(task)
        startNextQueued()
    }
    
    /// The single path every user-initiated delete goes through — one row, a
    /// multi-selection, or a whole category — so no entry point can quietly
    /// grow its own cleanup rules again.
    ///
    /// `moveFilesToTrash` only ever applies to a `.completed` task's finished
    /// file. An unfinished task's temp segments go regardless: they aren't
    /// user-visible files, and nothing can resume from a task that no longer
    /// exists in the list.
    public func delete(taskIDs: Set<DownloadTask.ID>, moveFilesToTrash: Bool) async -> DeletionOutcome {
        let targets = (tasks + completedTasks).filter { taskIDs.contains($0.id) }
        var trashed = 0
        var trashFailures = 0

        for task in targets {
            if task.status != .completed {
                await task.cancel()
                releaseActiveSlot(for: task)
            } else if moveFilesToTrash,
                      FileManager.default.fileExists(atPath: task.destinationURL.path) {
                // A file that vanished between the confirmation and here is
                // neither trashed nor a failure — there's nothing left to act
                // on and nothing worth reporting.
                if trashFile(at: task.destinationURL) { trashed += 1 } else { trashFailures += 1 }
            }

            tasks.removeAll { $0.id == task.id }
            completedTasks.removeAll { $0.id == task.id }
            statusObservers[task.id]?.cancel()
            statusObservers.removeValue(forKey: task.id)
            task.cleanupTempFiles()
        }

        savePersistedTasks()
        startNextQueued()
        return DeletionOutcome(
            removedCount: targets.count,
            trashedCount: trashed,
            trashFailureCount: trashFailures
        )
    }

    /// Trash, never unlink. A mistaken "also delete the file" stays
    /// recoverable from the Trash, which is what lets the confirmation offer
    /// it as a plain checkbox instead of a second scarier dialog.
    ///
    /// Failure is expected and survivable: this app is sandboxed, so a
    /// download saved outside ~/Downloads can legitimately be unreachable on
    /// a later launch once its user-selected folder access is gone.
    private func trashFile(at url: URL) -> Bool {
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            return true
        } catch {
            return false
        }
    }

    /// Called by IPCServer before creating a new download task.
    ///
    /// Matches an incoming fresh URL against an existing `.urlExpired` task
    /// using two independent strategies, tried in order:
    ///
    ///   1. **Same original page/host** — the expired task's own `url`
    ///      (what the user originally gave us — e.g. a "download the app"
    ///      redirector page) shares a host with the fresh URL. This is the
    ///      primary signal now, not filename: redirector-style download
    ///      links (a "latest release" endpoint with no extension in its
    ///      path) never carry a stable filename in the URL itself —
    ///      that only gets resolved into destinationURL AFTER a successful
    ///      fetch, via Content-Disposition or the final redirect target. A
    ///      second, fresh attempt at the same redirector produces a
    ///      differently-shaped URL with no reliable shared filename at all,
    ///      which is exactly why the previous filename-only matching
    ///      silently failed here — it never matched, so the expired task
    ///      just sat there forever while a brand new duplicate task got
    ///      created instead.
    ///   2. **Exact filename** — kept as a secondary/fallback signal for
    ///      sites that do produce a stable filename in the URL itself.
    ///
    /// Either way, an exact Content-Length match against task.totalBytes is
    /// still mandatory before actually relinking — host/filename alone is
    /// a candidate filter, not sufficient on its own to trust splicing a
    /// fresh URL onto existing partial bytes on disk (see the size-check
    /// comment below for why an absent Content-Length must fail closed).
    ///
    /// If matched: calls task.relinkURL() then auto-resumes.
    /// Returns true so the caller skips addDownload() for this URL.
    public func matchFreshURL(_ url: URL, headers: [String: String]) async -> Bool {
        let expiredTasks = tasks.filter { t in
            if case .urlExpired = t.status { return true }
            return false
        }
        guard !expiredTasks.isEmpty else { return false }
        
        let incomingHost = url.host?.lowercased()
        let incomingFilename = url.lastPathComponent
        
        let candidate = expiredTasks.first(where: { t in
            if let incomingHost, let taskHost = t.url.host?.lowercased(), incomingHost == taskHost {
                return true
            }
            if !incomingFilename.isEmpty, t.destinationURL.lastPathComponent == incomingFilename {
                return true
            }
            return false
        })
        
        guard let task = candidate else { return false }
        
        // Size match is mandatory, not merely checked-if-present. Without a
        // known, matching size we cannot safely trust this is the same file
        // — silently relinking on host/filename alone risks splicing an
        // expired task's existing partial bytes onto an entirely different
        // file.
        guard task.totalBytes > 0 else { return false }
        guard let clStr = headers["Content-Length"] ?? headers["content-length"],
              let contentLength = Int64(clStr) else {
            return false
        }
        guard contentLength == task.totalBytes else { return false }
        
        task.relinkURL(url, headers: headers)
        Task { try? await resumeDownload(task) }
        return true
    }
    
    public func removeTask(_ task: DownloadTask) {
        tasks.removeAll { $0.id == task.id }
        completedTasks.removeAll { $0.id == task.id }
        statusObservers[task.id]?.cancel()
        statusObservers.removeValue(forKey: task.id)
        // Covers the case cancelDownload's own cleanup doesn't: a task
        // removed straight from the list without ever going through
        // cancel() first — a single row's Delete on a .failed or
        // .destinationMissing task (DownloadRowView.deleteTask routes those
        // here directly). See DownloadTask.cleanupTempFiles.
        task.cleanupTempFiles()
        savePersistedTasks()
    }
    
    /// Watches a task's status so the manager can react to completion —
    /// this is the only place a *successful* finish is observed, since
    /// `task.start()` returns normally in that case (no thrown error for
    /// the callers in startDownload/resumeDownload to catch).
    private func observeStatus(of task: DownloadTask) {
        let cancellable = task.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.objectWillChange.send()
                if status == .completed {
                    self.handleCompletion(of: task)
                }
            }
        statusObservers[task.id] = cancellable
    }
    
    private func handleCompletion(of task: DownloadTask) {
        if activeTasks.remove(task.id) != nil {
            activeCount = max(0, activeCount - 1)
        }
        tasks.removeAll { $0.id == task.id }
        if !completedTasks.contains(where: { $0.id == task.id }) {
            completedTasks.append(task)
        }
        savePersistedTasks()
        NotificationCenter.default.post(name: .downloadCompleted, object: task)
        startNextQueued()
    }
    
    /// Every failed task, for the "Delete All Failed" command and the header
    /// button that offers it — one predicate rather than the same `if case`
    /// inlined at each call site.
    public var failedTasks: [DownloadTask] {
        tasks.filter { task in
            if case .failed = task.status { return true }
            return false
        }
    }

    /// Retries a failed download.
    ///
    /// Resumes the same task in place — same id, same on-disk segment temp
    /// files — rather than building a replacement task and deleting this
    /// one (the old behavior). That mattered because a segment's temp file
    /// is named after its task's id: swapping in a new task meant the new
    /// segments couldn't find the old partial bytes, so every retry
    /// silently restarted from byte 0 (e.g. after a network drop) and
    /// orphaned the old temp files on disk.
    ///
    /// `fromScratch: true` is for a download the user believes is genuinely
    /// corrupt or broken — discards whatever partial data is on disk first,
    /// so the retry can't inherit whatever caused the original failure.
    public func retryFailed(_ task: DownloadTask, fromScratch: Bool = false) async throws {
        guard case .failed = task.status else { return }
        if fromScratch {
            task.discardProgressForFreshRestart()
        }
        task.clearFailureForRetry()
        try await resumeDownload(task)
    }
    
    public func pauseAll() async {
        for id in activeTasks {
            if let task = tasks.first(where: { $0.id == id }) {
                await task.pause()
            }
        }
        activeTasks.removeAll()
        activeCount = 0
        
        // Also stop anything merely queued behind the concurrency limit,
        // not just what's actively transferring. A .waiting task was never
        // in activeTasks (it never acquired a slot), so the loop above
        // skips it entirely — left alone, it would just sit there and
        // auto-start the moment a slot happened to free, quietly ignoring
        // "Pause All". DownloadTask.pause() now accepts .waiting as a valid
        // source state for exactly this.
        for task in tasks where task.status == .waiting || task.status == .downloading || task.status == .starting {
            await task.pause()
        }
    }
    
    public func resumeAll() async {
        // Delegates to the existing, already-correct single-task methods
        // rather than reimplementing the active-count bookkeeping here —
        // that reimplementation is exactly how an earlier bug happened: it
        // called task.resume() unconditionally for both .paused AND
        // .waiting tasks, but DownloadTask.resume() silently no-ops for
        // anything that isn't .paused.
        //
        // Critical detail: each call is wrapped in its own detached Task{}
        // rather than awaited directly in the loop. DownloadTask.resume()/
        // start() don't return until the ENTIRE file finishes downloading
        // (they await the full segment TaskGroup) — so a plain
        // `for task in tasks { try await resumeDownload(task) }` would
        // block on task 1's complete download before even ATTEMPTING task
        // 2, making "Resume All" effectively sequential (one full download
        // at a time) regardless of maxConcurrentDownloads. Matches the same
        // detached-Task pattern addDownload() already correctly uses for
        // this exact reason. The maxConcurrent guard inside
        // resumeDownload/startDownload still applies safely even when all
        // of these fire back to back, since DownloadManager is @MainActor
        // — the check-and-increment can't race.
        let pausedTasks = tasks.filter { $0.status == .paused }
        for task in pausedTasks {
            Task { try? await self.resumeDownload(task) }
        }
        
        startAllWaitingWithinCapacity()
    }
    
    /// Starts every currently-.waiting task, up to whatever capacity is
    /// actually available right now (the guard inside startDownload caps
    /// it correctly, same serialization argument as resumeAll() above).
    ///
    /// Deliberately scoped to .waiting only, never .paused: a task sitting
    /// at .waiting is there purely because it hit the concurrency limit,
    /// while .paused always reflects a deliberate user action (clicking
    /// Pause). Waking up a user-paused download just because capacity
    /// opened up elsewhere — e.g. from raising the limit in Settings —
    /// would be a surprising, unwanted side effect; only resumeAll() (an
    /// explicit user action, and only that) should ever touch .paused
    /// tasks. Shared by resumeAll() and the settings.objectWillChange
    /// observer in init() — both are really "there might be new capacity,
    /// try to use it" moments.
    private func startAllWaitingWithinCapacity() {
        let waitingTasks = tasks.filter { $0.status == .waiting }
        for task in waitingTasks {
            Task { try? await self.startDownload(task) }
        }
    }
    
    public func setSpeedLimit(_ bytesPerSecond: Int64) {
        // Apply to all active tasks
    }
    
    private func startNextQueued() {
        guard activeCount < maxConcurrent else { return }
        
        if let nextTask = tasks.first(where: { 
            $0.status == .waiting && !activeTasks.contains($0.id) 
        }) {
            Task {
                try? await startDownload(nextTask)
            }
        }
    }

    /// Removes a task's concurrency reservation exactly once. Several
    /// lifecycle paths can converge here (completion, cancellation, pause,
    /// or a non-throwing blocked start), so decrementing activeCount without
    /// checking the set first could make the count negative or free capacity
    /// that another task is already using.
    private func releaseActiveSlot(for task: DownloadTask) {
        guard activeTasks.remove(task.id) != nil else { return }
        activeCount = max(0, activeCount - 1)
    }
    
    /// Posted whenever an *explicit* user action (Start, Resume, Resume All)
    /// gets blocked purely by the concurrency limit — not for a task that
    /// was already sitting queued and stays queued (see
    /// startAllWaitingWithinCapacity, which never calls this). The task
    /// itself still ends up at .waiting either way; this is only about
    /// giving the person who just clicked something a reason their click
    /// didn't visibly do anything, since "it silently queued" isn't
    /// obvious from a click alone. UI (ContentView) turns this into a toast
    /// explaining the limit and how to raise it — deliberately not an
    /// in-place "open Settings for you" action, just the steps.
    private func notifyBlockedByCapacity() {
        NotificationCenter.default.post(name: .concurrencyLimitReached, object: nil)
    }
    
    // MARK: - Conflict detection & resolution

    /// Single source of truth for "is this the same download as something
    /// we already have." Checked against URL first (the strongest signal
    /// — an HLS variant playlist or a direct file link genuinely differs
    /// per source), then against originalName (see DownloadTask.originalName's
    /// doc comment for why that has to be the name compared, not the
    /// current, possibly-already-suffixed destinationURL).
    ///
    /// Deliberately doesn't try to distinguish "genuinely the same content"
    /// from "coincidentally the same name/URL but actually different" the
    /// way the old looksLikeSameDownload size-tolerance heuristic did — any
    /// match now surfaces the conflict dialog and lets the person decide,
    /// including via "Save as separate" if it turns out to genuinely be a
    /// different thing. Simpler, and more transparent than guessing on
    /// their behalf; the cost is an occasional dialog for two unrelated
    /// downloads that happen to share a generic fallback title.
    ///
    /// `excluding` skips a given task's own id — needed by
    /// resolveLateIdentity, which calls this on a task that's already in
    /// `tasks` and must not match against itself.
    /// - youTubeFormatSelector: the yt-dlp selector the incoming request would
    ///   download with, or nil for anything that isn't a YouTube request.
    ///   Needed because YouTube is the one source where a single URL
    ///   legitimately produces many different files: the watch page is the
    ///   task's `url` for every quality of the same video, so matching on URL
    ///   alone would call 4K a duplicate of the 1080p already in the list, and
    ///   offer to "resume" a download that is a different file entirely. Two
    ///   YouTube requests are the same download only when they would produce
    ///   the same bytes, which is page URL *and* selector. `nil == nil` for
    ///   every other kind of download, so nothing else changes behaviour.
    private func existingTask(matchingURL url: URL, originalName: String, youTubeFormatSelector: String? = nil, excluding excludedTaskID: UUID? = nil) -> DownloadTask? {
        let incoming = DownloadIdentity(
            url: url, name: originalName, youTubeFormatSelector: youTubeFormatSelector
        )
        return (tasks + completedTasks).first { task in
            guard task.id != excludedTaskID else { return false }
            // A completed task whose file is gone from disk (moved/deleted
            // outside the app — the row shows "Moved or deleted") has
            // nothing left to protect from being overwritten, so it
            // shouldn't block a fresh download of the same thing. Scoped to
            // .completed only: every other status's destination file may
            // simply not exist YET (segments still assembling, or genuinely
            // in flight), and treating that as "gone" would silently let a
            // real duplicate through — the exact silent-heuristic mistake
            // this whole dedup rework replaced. See originalName's doc
            // comment / the handoff on always-show-the-conflict-dialog.
            if task.status == .completed,
               !FileManager.default.fileExists(atPath: task.destinationURL.path) {
                return false
            }
            return task.identity.isSameDownload(as: incoming)
        }
    }

    private func enqueueConflict(_ conflict: DuplicateDownloadConflict) {
        conflictQueue.append(conflict)
        if pendingConflict == nil {
            pendingConflict = conflictQueue.first
        }
    }

    /// Executes the user's chosen resolution and advances the conflict queue.
    /// Called from DuplicateDownloadSheet via the shared DownloadManager.
    public func resolveConflict(_ conflict: DuplicateDownloadConflict, resolution: ConflictResolution) async {
        // Dequeue first so the sheet dismisses immediately on tap.
        conflictQueue.removeAll { $0.id == conflict.id }
        pendingConflict = conflictQueue.first

        // resolvingTaskID set means this conflict came from
        // resolveLateIdentity, not from a brand-new, not-yet-created
        // request. The caller that raised it —
        // DownloadTask.updateDestinationFilenameIfNeeded, for the one
        // remaining case identity wasn't knowable up front — is suspended
        // right now inside resolveLateIdentity, waiting on exactly this
        // answer — all this needs to do is hand it over. Resuming there
        // (rather than acting on tasks/existing here, the way this used to
        // work) is what makes every button meaningful even when the
        // in-flight task has been sitting fully stopped this whole time:
        // there's no more guessing whether it's still in `tasks`, already
        // `completed`, or gone — the suspended call has the real task
        // reference in hand.
        if conflict.resolvingTaskID != nil {
            if let continuation = conflictWaiters.removeValue(forKey: conflict.id) {
                continuation.resume(returning: resolution)
            }
            return
        }

        switch resolution {
        case .resumeExisting:
            let existing = conflict.existingTask
            switch existing.status {
            case .downloading, .starting, .validating, .refreshingLink, .waiting:
                // Already running or queued — nothing to do; just don't add
                // a duplicate (which is what dismissing the sheet achieves).
                break
            case .urlExpired:
                // relinkURL only accepts .urlExpired — updates _effectiveURL
                // and resets status to .paused so resumeDownload can fire.
                existing.relinkURL(conflict.incomingURL, headers: conflict.incomingHeaders)
                Task { try? await self.resumeDownload(existing) }
            case .paused, .destinationMissing:
                // A restored task comes back .paused, so this is the branch a
                // re-capture lands in once the app has been closed and
                // reopened — and the stored headers may have outlived the
                // browser session they came from. The identity match already
                // established this is the same URL, so unlike the .urlExpired
                // case above there is nothing to relink, only credentials to
                // refresh before resuming.
                existing.applyFreshHeaders(conflict.incomingHeaders)
                Task { try? await self.resumeDownload(existing) }
            case .failed:
                // Failed tasks can't simply be resumed — create a fresh task
                // at the incoming URL, then remove the stale failed one.
                await cancelDownload(existing)
                Task {
                    _ = try? await self.recreateIncoming(conflict)
                }
            default:
                break
            }

        case .restart:
            // Remove the existing task (however active it is), then add fresh.
            switch conflict.existingTask.status {
            case .downloading, .waiting, .starting, .validating,
                 .refreshingLink, .paused, .urlExpired, .destinationMissing:
                await cancelDownload(conflict.existingTask)
            default:
                removeTask(conflict.existingTask)
            }
            Task {
                _ = try? await self.recreateIncoming(conflict, destination: conflict.incomingDestination)
            }

        case .addSeparate:
            // Based on the existing task's own name, not
            // conflict.incomingDestination's — same reasoning as the
            // suggestedAlternativeName computed when this conflict was
            // raised (see addDownload/addStreamDownload/resolveLateIdentity):
            // the incoming side may have resolved a worse name for this
            // particular request even though it's the same video, and this
            // is what actually names the saved file, not just a label shown
            // in the sheet — it must match what "Save as X (1)" promised.
            let newDest = deduplicatedDestination(for: conflict.existingTask.destinationURL)
            Task {
                _ = try? await self.recreateIncoming(conflict, destination: newDest)
            }

        case .skip:
            break // discard the incoming request
        }
    }

    /// Recreates the incoming side of a conflict as a real task, routing to
    /// the correct engine based on conflict.incomingStreamInfo —
    /// addStreamDownload for a native HLS/DASH request, addDownload
    /// otherwise. See DuplicateDownloadConflict.incomingStreamInfo's doc
    /// comment for why this branch has to exist at all: guessing addDownload
    /// unconditionally (as every call site above used to) silently fetched a
    /// stream's raw manifest TEXT as if it were the video file itself,
    /// producing a tiny, extensionless file instead — confirmed happening in
    /// practice.
    @discardableResult
    private func recreateIncoming(_ conflict: DuplicateDownloadConflict, destination: URL? = nil) async throws -> DownloadTask {
        let dest = destination ?? conflict.incomingDestination
        if let info = conflict.incomingYouTubeInfo {
            return try await addYouTubeDownload(
                pageURL: conflict.incomingURL,
                formatID: info.formatID,
                mergeAudio: info.mergeAudio,
                videoBytes: info.videoBytes,
                destination: dest,
                filenameSource: conflict.incomingFilenameSource,
                skipConflictCheck: true
            )
        }
        if let info = conflict.incomingStreamInfo {
            return try await addStreamDownload(
                url: conflict.incomingURL,
                streamType: info.streamType,
                destination: dest,
                filenameSource: conflict.incomingFilenameSource,
                customHeaders: conflict.incomingHeaders,
                referrerURL: conflict.incomingReferrer,
                representationId: info.representationId,
                bandwidth: info.bandwidth,
                preferredAudioLanguage: info.preferredAudioLanguage,
                hlsAudioTracks: info.hlsAudioTracks,
                skipConflictCheck: true
            )
        }
        return try await addDownload(
            url: conflict.incomingURL,
            destination: dest,
            filenameSource: conflict.incomingFilenameSource,
            customHeaders: conflict.incomingHeaders,
            referrerURL: conflict.incomingReferrer,
            skipConflictCheck: true
        )
    }

    /// Called by DownloadTask.updateDestinationFilenameIfNeeded in the one
    /// remaining case identity wasn't knowable at request time: a
    /// redirector-style URL with nothing usable in its own path, whose real
    /// name only arrives later via Content-Disposition. Every other
    /// download — a real filename already in the URL, or a stream's title,
    /// both known instantly — has this fully resolved before the task even
    /// exists, via existingTask in addDownload/addStreamDownload, and never
    /// reaches this function at all.
    ///
    /// A genuine conflict actually stops the task —
    /// task.markAwaitingConflictResolution() cancels its in-flight network
    /// work before this suspends — and suspends until the person answers,
    /// rather than applying a safe auto-suffix and letting it race to
    /// completion in the background.
    func resolveLateIdentity(for task: DownloadTask, resolvedName: String) async -> LateIdentityOutcome {
        guard let existing = existingTask(
            matchingURL: task.url,
            originalName: resolvedName,
            excluding: task.id
        ) else {
            return .noConflict
        }

        // Genuine conflict — actually stop the task's own network work (if
        // any is still running) right now, before the sheet even renders,
        // and reflect that honestly in its status. See
        // DownloadTask.markAwaitingConflictResolution.
        task.markAwaitingConflictResolution()

        let folder = task.destinationURL.deletingLastPathComponent()
        let candidateURL = folder.appendingPathComponent(resolvedName)
        // Suggest based on the existing task's own name, not this task's
        // just-resolved one — same reasoning as addDownload/addStreamDownload.
        let deduped = deduplicatedDestination(for: existing.destinationURL, excluding: task.id)
        let conflict = DuplicateDownloadConflict(
            incomingURL: task.url,
            incomingHeaders: task.customHeaders,
            incomingReferrer: task.referrerURL,
            incomingDestination: candidateURL,
            incomingFilenameSource: task.filenameSource,
            existingTask: existing,
            suggestedAlternativeName: deduped.lastPathComponent,
            resolvingTaskID: task.id
        )

        let resolution: ConflictResolution = await withCheckedContinuation { continuation in
            conflictWaiters[conflict.id] = continuation
            enqueueConflict(conflict)
        }

        // A row action (pause/cancel) taken while the sheet is open discards
        // the sheet and resumes this waiter with .skip (discardPendingConflict)
        // — the person's real intent ("stop this download") already took effect,
        // so a discarded sheet must not tear anything else down. Only an answer
        // typed into the sheet itself can find the task still parked here; that
        // distinction is what the status check encodes.
        switch resolution {
        case .resumeExisting, .skip:
            if task.status == .awaitingDuplicateResolution {
                await cancelDownload(task)
            }
            return .discard
        case .restart:
            task.markConflictResolved()
            switch existing.status {
            case .downloading, .waiting, .starting, .validating,
                 .refreshingLink, .paused, .urlExpired, .destinationMissing,
                 .awaitingDuplicateResolution:
                await cancelDownload(existing)
            default:
                removeTask(existing)
            }
            savePersistedTasks()
            return .resolved(candidateURL)
        case .addSeparate:
            task.markConflictResolved()
            return .resolved(deduped)
        }
    }

    /// Called by DownloadTask.pause()/cancel() when the user acts directly
    /// on a task that's currently sitting at .awaitingDuplicateResolution —
    /// the sheet asking about it is no longer meaningful once the person has
    /// already acted on the row a different way. Discards it as a "skip"
    /// outcome (don't proceed) rather than leaving its continuation
    /// suspended forever, which would otherwise leak both the continuation
    /// and the Task it's suspending.
    func discardPendingConflict(forResolvingTaskID taskID: UUID) {
        guard let index = conflictQueue.firstIndex(where: { $0.resolvingTaskID == taskID }) else { return }
        let conflict = conflictQueue.remove(at: index)
        if pendingConflict?.id == conflict.id {
            pendingConflict = conflictQueue.first
        }
        if let continuation = conflictWaiters.removeValue(forKey: conflict.id) {
            continuation.resume(returning: .skip)
        }
    }

    /// Walks file.zip → file (1).zip → file (2).zip … until it finds a name
    /// not already claimed by any existing task and not present on disk.
    ///
    /// `excluding` should be passed whenever the caller is a task computing
    /// a *new* name for itself (e.g. DownloadTask.updateDestinationFilenameIfNeeded
    /// once Content-Disposition/URL resolution confirms the real filename).
    /// That task is already present in `tasks`
    /// under its old placeholder name at this point — without excluding it, a
    /// brand-new, never-downloaded-before file whose confirmed name happens to
    /// match the placeholder it was already created with (common: any URL
    /// whose path already ends in the real filename) reads as "claimed" by
    /// itself, and gets bumped to "file (1).ext" for no real reason. Callers
    /// proposing a name for a genuinely different, not-yet-created task (e.g.
    /// resolveConflict's .addSeparate) should leave this nil.
    internal func deduplicatedDestination(for url: URL, excluding excludedTaskID: UUID? = nil) -> URL {
        let allTasks = (tasks + completedTasks).filter { $0.id != excludedTaskID }
        var counter  = 0
        while true {
            // Shared with the claim made at the moment of writing, so the name
            // the duplicate sheet promises is the name that lands on disk.
            let candidate = DownloadDestination.candidate(for: url, suffix: counter)
            // Standardized once, not inside the predicate. `/a/b/../c/x.zip`
            // and `/a/c/x.zip` name the same file but are different strings,
            // so the comparison has to be against tidied paths — and tidying
            // is not cheap (measured at ~0.66µs, more than a fileExists
            // syscall). Inside the closure this recomputed one unchanging
            // value once per task in the list, which was the dominant cost of
            // this function: ~670µs against 500 downloads, halved by this line.
            let target = candidate.standardized
            // Same exemption as existingTask: a completed task whose file
            // is gone from disk isn't actually claiming this name — only
            // `onDisk` (checked independently below) should be able to veto
            // a candidate once the task itself no longer occupies it.
            let claimed   = allTasks.contains {
                $0.destinationURL.standardized == target
                && !($0.status == .completed && !FileManager.default.fileExists(atPath: $0.destinationURL.path))
            }
            let onDisk    = FileManager.default.fileExists(atPath: candidate.path)
            if !claimed && !onDisk { return candidate }
            counter += 1
        }
    }

    // MARK: - Destination

    private func defaultDestination(for url: URL) -> URL {
        let baseURL = URL(fileURLWithPath: settings.downloadDirectory, isDirectory: true)
        let filename = FilenameResolver.provisionalFilename(for: url)
        return baseURL.appendingPathComponent(filename)
    }

    private func normalizedDestination(_ destination: URL?, fallbackURL: URL) -> URL {
        guard let destination else { return defaultDestination(for: fallbackURL) }
        let folder = destination.deletingLastPathComponent()
        let filename = FilenameResolver.sanitize(destination.lastPathComponent)
            ?? FilenameResolver.provisionalFilename(for: fallbackURL)
        return folder.appendingPathComponent(filename)
    }
    
    private func loadPersistedTasks() {
        guard let data = try? Data(contentsOf: Self.persistenceURL) else { return }

        let snapshots: [PersistedDownloadTask]
        do {
            snapshots = try JSONDecoder().decode([PersistedDownloadTask].self, from: data)
        } catch {
            keepUnreadableList(error)
            return
        }

        for snap in snapshots {
            let priority = DownloadPriority(rawValue: snap.priorityRaw) ?? .normal
            let dest = URL(fileURLWithPath: snap.destinationPath)
            
            switch snap.kind {
            case .active:
                // Segments always empty after relaunch — status forced to
                // .paused so nothing auto-fires network calls on launch.
                // task.resume() rebuilds segments fresh; each finds its own
                // partial bytes on disk via the stable id.
                let task = DownloadTask(
                    id: snap.id, url: snap.url, destinationURL: dest,
                    originalName: snap.originalName,
                    priority: priority, segmentCount: snap.segmentCount,
                    initialStatus: .paused, totalBytes: snap.totalBytes,
                    downloadedBytes: snap.downloadedBytes,
                    etag: snap.etag, lastModified: snap.lastModified,
                    lastValidatedAt: snap.lastValidatedAt,
                    referrerURL: snap.referrerURL,
                    forwardedURL: snap.forwardedURL,
                    filenameSource: snap.filenameSource ?? .originalURL,
                    createdAt: snap.createdAt ?? Date()
                )
                if let selector = snap.ytFormatSelector, let page = snap.ytPageURL {
                    task.configureYouTubeDownload(formatSelector: selector, pageURL: page)
                }
                if let sURL = snap.streamURL, let sType = snap.streamType {
                    task.configureStreamDownload(
                        streamURL: sURL, streamType: sType,
                        customHeaders: snap.streamRequestHeaders ?? [:],
                        representationId: snap.streamRepresentationId,
                        bandwidth: snap.streamBandwidth,
                        preferredAudioLanguage: snap.streamPreferredAudioLanguage,
                        hlsAudioTracks: snap.streamHLSAudioTracks,
                        completedSegments: snap.streamCompletedSegments,
                        totalSegments: snap.streamTotalSegments
                    )
                }
                observeStatus(of: task)
                tasks.append(task)

            case .completed:
                // Always restore, even if file's gone missing — user decides
                // via the click-time "File Not Found" prompt, not us silently.
                let task = DownloadTask(
                    id: snap.id, url: snap.url, destinationURL: dest,
                    originalName: snap.originalName,
                    priority: priority, segmentCount: snap.segmentCount,
                    initialStatus: .completed, totalBytes: snap.totalBytes,
                    downloadedBytes: snap.downloadedBytes,
                    filenameSource: snap.filenameSource ?? .originalURL,
                    createdAt: snap.createdAt ?? Date()
                )
                completedTasks.append(task)
            case .urlExpired:
                let task = DownloadTask(
                    id: snap.id, url: snap.url, destinationURL: dest,
                    originalName: snap.originalName,
                    priority: priority, segmentCount: snap.segmentCount,
                    initialStatus: .urlExpired(referrerURL: snap.referrerURL),
                    totalBytes: snap.totalBytes, downloadedBytes: snap.downloadedBytes,
                    etag: snap.etag, lastModified: snap.lastModified,
                    referrerURL: snap.referrerURL,
                    forwardedURL: snap.forwardedURL,
                    filenameSource: snap.filenameSource ?? .originalURL,
                    createdAt: snap.createdAt ?? Date()
                )
                observeStatus(of: task)
                tasks.append(task)
            }
        }
    }
    
    // MARK: - Temporary storage

    /// Feeds only the launch notice. The files a crash strands appear after
    /// any earlier measurement, so this cannot be a remembered figure.
    private func measureTemporaryStorageAtLaunch() async {
        await refreshOrphanedTemporaryBytes()
        let threshold = TemporaryStorageNotice.bytes(fromGB: settings.temporaryFilesNoticeThresholdGB)
        if TemporaryStorageNotice.shouldShow(orphanedBytes: orphanedTemporaryBytes, thresholdBytes: threshold) {
            temporaryStorageNoticeDueAtLaunch = true
        }
    }

    /// Deletes every orphaned leftover and returns the bytes actually freed.
    ///
    /// Finds them again here rather than taking a report from the caller: a
    /// report the UI has been holding may be minutes old, and a download
    /// started since then now claims files it called unreachable.
    @discardableResult
    public func clearOrphanedTemporaryFiles() async -> Int64 {
        let knownTaskIDs = Set(tasks.map(\.id)).union(completedTasks.map(\.id))
        let freed = await Task.detached(priority: .utility) {
            TemporaryStorage.remove(TemporaryStorage.report(knownTaskIDs: knownTaskIDs).orphaned)
        }.value
        await refreshOrphanedTemporaryBytes()
        return freed
    }

    /// Measures orphaned leftovers so the UI can offer to clear them.
    ///
    /// Measures only. Nothing here deletes: a run that crashed leaves
    /// directories no row claims, and they stay until someone clears them.
    ///
    /// Called at launch, when the Storage settings appear, and after a clear.
    public func refreshOrphanedTemporaryBytes() async {
        let knownTaskIDs = Set(tasks.map(\.id)).union(completedTasks.map(\.id))
        let report = await Task.detached(priority: .utility) {
            TemporaryStorage.report(knownTaskIDs: knownTaskIDs)
        }.value
        // Only when it actually moved. @Published fires on every set, and the
        // main window observes this object, so re-checking an unchanged size
        // would re-render the whole download list for nothing.
        guard report.totalBytes != orphanedTemporaryBytes else { return }
        orphanedTemporaryBytes = report.totalBytes
    }

    /// Called on every add/remove/complete, and once more on app quit (see
    /// `saveBeforeTermination`) to catch progress since the last explicit
    /// state change.
    /// A list this build can't decode is moved aside rather than replaced by
    /// the empty one this session would otherwise save over it.
    private func keepUnreadableList(_ error: Error) {
        do {
            let kept = try UnreadableDownloadList.setAside(Self.persistenceURL)
            logger.error("could not read the download list (\(error, privacy: .private)); kept it as \(kept.lastPathComponent, privacy: .public)")
        } catch {
            listIsUnreadable = true
            logger.error("could not read the download list or move it aside; not saving over it this session")
        }
    }

    private func savePersistedTasks() {
        guard ownsDownloadList, !listIsUnreadable else { return }
        let active = tasks.compactMap { task -> PersistedDownloadTask? in
            switch task.status {
            case .cancelled:
                return nil // transient, not worth restoring
            // .failed falls through to `default` below and is persisted as
            // .active (restored as .paused, like any other interrupted
            // task) — NOT excluded the way it used to be. A failed task can
            // carry real partial-download progress on disk now that retry
            // resumes in place rather than always restarting from scratch
            // (see DownloadManager.retryFailed); dropping it here meant that
            // progress, and the task itself, silently vanished from the list
            // on the next launch with no way to get it back.
            case .urlExpired:
                return PersistedDownloadTask(
                    id: task.id, url: task.url, destinationPath: task.destinationURL.path,
                    originalName: task.originalName, createdAt: task.createdAt,
                    priorityRaw: task.priority.rawValue, segmentCount: task.segmentCount,
                    kind: .urlExpired, totalBytes: task.totalBytes, downloadedBytes: task.downloadedBytes,
                    etag: task.etag, lastModified: task.lastModified,
                    lastValidatedAt: task.lastValidatedAt,
                    referrerURL: task.referrerURL,
                    forwardedURL: task.forwardedURL,
                    ytFormatSelector: task.ytFormatSelector, ytPageURL: task.ytPageURL,
                    streamURL: task.streamURL, streamType: task.streamType,
                    streamRepresentationId: task.streamRepresentationId,
                    streamBandwidth: task.streamBandwidth,
                    streamPreferredAudioLanguage: task.streamPreferredAudioLanguage,
                    streamHLSAudioTracks: task.streamHLSAudioTracks,
                    streamCompletedSegments: task.segmentProgress?.completed,
                    streamTotalSegments: task.segmentProgress?.total,
                    filenameSource: task.filenameSource,
                    streamRequestHeaders: task.streamURL == nil
                        ? nil : persistableStreamHeaders(task.customHeaders)
                )
            default:
                return PersistedDownloadTask(
                    id: task.id, url: task.url, destinationPath: task.destinationURL.path,
                    originalName: task.originalName, createdAt: task.createdAt,
                    priorityRaw: task.priority.rawValue, segmentCount: task.segmentCount,
                    kind: .active, totalBytes: task.totalBytes, downloadedBytes: task.downloadedBytes,
                    etag: task.etag, lastModified: task.lastModified,
                    lastValidatedAt: task.lastValidatedAt,
                    referrerURL: task.referrerURL,
                    forwardedURL: task.forwardedURL,
                    ytFormatSelector: task.ytFormatSelector, ytPageURL: task.ytPageURL,
                    streamURL: task.streamURL, streamType: task.streamType,
                    streamRepresentationId: task.streamRepresentationId,
                    streamBandwidth: task.streamBandwidth,
                    streamPreferredAudioLanguage: task.streamPreferredAudioLanguage,
                    streamHLSAudioTracks: task.streamHLSAudioTracks,
                    streamCompletedSegments: task.segmentProgress?.completed,
                    streamTotalSegments: task.segmentProgress?.total,
                    filenameSource: task.filenameSource,
                    streamRequestHeaders: task.streamURL == nil
                        ? nil : persistableStreamHeaders(task.customHeaders)
                )
            }
        }
        let completed = completedTasks.map { task in
            PersistedDownloadTask(
                id: task.id, url: task.url, destinationPath: task.destinationURL.path,
                originalName: task.originalName, createdAt: task.createdAt,
                priorityRaw: task.priority.rawValue, segmentCount: task.segmentCount,
                kind: .completed, totalBytes: task.totalBytes, downloadedBytes: task.downloadedBytes,
                etag: task.etag, lastModified: task.lastModified,
                lastValidatedAt: nil,
                referrerURL: nil,
                forwardedURL: nil,
                ytFormatSelector: nil, ytPageURL: nil,
                streamURL: nil, streamType: nil,
                streamRepresentationId: nil, streamBandwidth: nil,
                streamPreferredAudioLanguage: nil,
                streamHLSAudioTracks: nil,
                streamCompletedSegments: nil, streamTotalSegments: nil,
                filenameSource: task.filenameSource,
                streamRequestHeaders: nil
            )
        }
        
        guard let data = try? JSONEncoder().encode(active + completed) else { return }
        try? data.write(to: Self.persistenceURL, options: Data.WritingOptions.atomic)
    }

    
    /// Public hook for the app's termination path — catches in-progress byte
    /// counts that wouldn't otherwise get saved until the next status change.
    public func saveBeforeTermination() {
        savePersistedTasks()
    }
    
    private static let persistenceURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Convoy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("downloads.json")
    }()
}

private struct PersistedDownloadTask: Codable {
    enum Kind: String, Codable { case active, completed, urlExpired }
    let id: UUID
    let url: URL
    let destinationPath: String
    /// Required, deliberately no migration/fallback for tasks saved before
    /// this field existed — see DownloadTask.originalName's doc comment for
    /// why this replaced comparing against the mutable destination filename.
    /// A pre-existing downloads.json simply won't decode; the whole list
    /// then starts empty on first launch with a build that has this field,
    /// rather than silently guessing at a name for entries that never
    /// recorded one.
    let originalName: String
    /// When this task was originally created — not when it was last saved.
    /// Optional only for backward-compatible decoding of snapshots written
    /// before this field existed; a missing value falls back to "now" at
    /// load time (loses its stable position once, same as before this field
    /// existed, but never decodes-fails outright).
    let createdAt: Date?
    let priorityRaw: Int
    let segmentCount: Int
    let kind: Kind
    let totalBytes: Int64
    let downloadedBytes: Int64
    /// HTTP validators for detecting file changes on resume
    let etag: String?
    let lastModified: String?
    /// When we last ran the HEAD validation check. The 24h skip window is
    /// measured from this, not from when you paused.
    let lastValidatedAt: Date?
    /// Page URL that triggered the download — used by the Re-link flow.
    let referrerURL: URL?
    /// See DownloadTask.forwardedURL. Absent in older snapshots.
    let forwardedURL: URL?
    /// yt-dlp-driven download linkage (see DownloadTask's "yt-dlp-driven
    /// download" section) — nil for every task that uses the probe/segment
    /// engine. Persisted so a relaunch resumes the YouTube download through
    /// yt-dlp instead of silently falling back to byte-range fetching a watch
    /// page URL.
    let ytFormatSelector: String?
    let ytPageURL: URL?
    /// Native stream download linkage (HLS/DASH via StreamDownloader).
    /// Persisted so a relaunch can resume the stream download without going
    /// back through the byte-range engine.
    let streamURL: URL?
    let streamType: String?
    let streamRepresentationId: String?
    let streamBandwidth: Int?
    let streamPreferredAudioLanguage: String?
    let streamHLSAudioTracks: [HLSAudioCandidate]?
    /// Last known segment counts for a native stream download, which has no
    /// byte total to rebuild a bar from. Optional: absent for other task types
    /// and for snapshots written before this field existed.
    let streamCompletedSegments: Int?
    let streamTotalSegments: Int?
    /// Optional for backward-compatible decoding of task snapshots written
    /// before filename provenance was introduced.
    let filenameSource: FilenameSource?
    /// The subset of a native stream's captured request headers that is safe
    /// to keep in plaintext — see persistableStreamHeaders. Nil for every
    /// other task type, and for snapshots written before this field existed
    /// (which is also every snapshot written while these lived in the
    /// Keychain instead).
    let streamRequestHeaders: [String: String]?
}

/// Headers that may be written to downloads.json: only what a resumed
/// stream needs in order to still look like the browser that captured it.
/// An allow-list rather than a block list, so a header this code has never
/// seen — a custom auth token arriving through the yt-dlp explicitHeaders
/// path, say — cannot reach a plaintext file merely by not being listed.
///
/// Cookie-gated streams consequently cannot resume themselves after a
/// relaunch. Re-capturing from the browser and picking "resume existing" in
/// the duplicate sheet refreshes them instead (DownloadTask.applyFreshHeaders),
/// which is also the only path that gets a *current* cookie rather than
/// whichever one happened to be stored when the download started.
private func persistableStreamHeaders(_ headers: [String: String]) -> [String: String] {
    // Everything the browser sends to make the request look like the page it
    // came from, and nothing that authenticates it. Accept/Sec-Fetch-* are
    // here because yt-dlp's per-format http_headers travel this path too
    // (see the extension's explicitHeaders) and some CDNs do read them;
    // dropping them would change what a resumed stream sends. Accept-Encoding
    // is deliberately absent — URLSession negotiates its own.
    let allowed: Set<String> = [
        "user-agent", "referer", "origin", "accept", "accept-language",
        "sec-fetch-mode", "sec-fetch-site", "sec-fetch-dest",
    ]
    return headers.filter { allowed.contains($0.key.lowercased()) }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Conflict types

/// A filename conflict detected between an incoming download request and
/// an existing task. Enqueued by addDownload when skipConflictCheck is false
/// and existingTask returns a match. The UI presents one at a time via
/// DuplicateDownloadSheet; calling resolveConflict(_:resolution:) dismisses
/// it and advances the queue.
public struct DuplicateDownloadConflict: Identifiable {
    public let id: UUID = UUID()
    /// The URL the user or extension just tried to download.
    public let incomingURL: URL
    /// Headers that came with the incoming request.
    public let incomingHeaders: [String: String]
    /// Referrer URL from the incoming request, if any.
    public let incomingReferrer: URL?
    /// The destination the incoming URL would have been saved to.
    public let incomingDestination: URL
    /// Provenance of the incoming name, preserved if a conflict action
    /// recreates the task so a page-title suggestion does not become locked.
    public let incomingFilenameSource: FilenameSource
    /// The existing task whose filename clashes with the incoming download.
    public let existingTask: DownloadTask
    /// Pre-computed deduplicated filename (e.g. "file (1).zip") so the sheet
    /// can display the "Add as new" label without re-running path logic.
    public let suggestedAlternativeName: String
    /// Non-nil only for a conflict raised by resolveLateIdentity (an
    /// already-downloading task whose *resolved* name, discovered mid-flight
    /// via Content-Disposition, turned out to collide with another task) —
    /// nil for the ordinary case of a brand-new incoming request caught by
    /// existingTask before any task exists. resolveConflict uses this
    /// to route the four resolutions at an already-running task instead of at a
    /// not-yet-created one: there's no separate "incoming" task to add or
    /// discard, just this task's OWN name to keep, hand off, or cancel.
    public let resolvingTaskID: UUID?
    /// Non-nil when the incoming request is a native HLS/DASH stream download
    /// rather than a plain byte-range file. Every field addStreamDownload
    /// needs beyond what's already captured above (url, destination, headers,
    /// referrer, filenameSource). Without this, resolveConflict's .restart and
    /// .addSeparate cases — and .resumeExisting's .failed sub-case — had no
    /// way to know which engine to recreate the download with, and always
    /// guessed addDownload (the byte-range engine): for a stream URL (an
    /// .m3u8 playlist, say), that fetches the raw manifest TEXT as if it were
    /// the file itself and saves it under a name with no extension (streams
    /// never get one until assembly determines the real container format) —
    /// confirmed happening in practice: choosing "Save as separate" on a
    /// stream conflict produced a tiny, extensionless file instead of the
    /// actual video.
    public let incomingStreamInfo: StreamInfo?
    /// Non-nil when the incoming request is a YouTube download. Same purpose
    /// as `incomingStreamInfo`: `recreateIncoming` cannot know which engine to
    /// rebuild the request with from url/destination alone, and a YouTube
    /// request rebuilt as a plain byte-range download would fetch the watch
    /// page's HTML instead of the video.
    public let incomingYouTubeInfo: YouTubeInfo?

    public init(
        incomingURL: URL,
        incomingHeaders: [String: String],
        incomingReferrer: URL?,
        incomingDestination: URL,
        incomingFilenameSource: FilenameSource,
        existingTask: DownloadTask,
        suggestedAlternativeName: String,
        resolvingTaskID: UUID?,
        incomingStreamInfo: StreamInfo? = nil,
        incomingYouTubeInfo: YouTubeInfo? = nil
    ) {
        self.incomingURL = incomingURL
        self.incomingHeaders = incomingHeaders
        self.incomingReferrer = incomingReferrer
        self.incomingDestination = incomingDestination
        self.incomingFilenameSource = incomingFilenameSource
        self.existingTask = existingTask
        self.suggestedAlternativeName = suggestedAlternativeName
        self.resolvingTaskID = resolvingTaskID
        self.incomingStreamInfo = incomingStreamInfo
        self.incomingYouTubeInfo = incomingYouTubeInfo
    }

    public struct YouTubeInfo {
        public let formatID: String
        public let mergeAudio: MergeAudio?
        public let videoBytes: Int64?

        public init(formatID: String, mergeAudio: MergeAudio?, videoBytes: Int64?) {
            self.formatID = formatID
            self.mergeAudio = mergeAudio
            self.videoBytes = videoBytes
        }
    }

    public struct StreamInfo {
        public let streamType: String
        public let representationId: String?
        public let bandwidth: Int?
        public let preferredAudioLanguage: String?
        public let hlsAudioTracks: [HLSAudioCandidate]?

        public init(streamType: String, representationId: String? = nil, bandwidth: Int? = nil, preferredAudioLanguage: String? = nil, hlsAudioTracks: [HLSAudioCandidate]? = nil) {
            self.streamType = streamType
            self.representationId = representationId
            self.bandwidth = bandwidth
            self.preferredAudioLanguage = preferredAudioLanguage
            self.hlsAudioTracks = hlsAudioTracks
        }
    }
}

/// What to do when a download is started for a URL already in the list.
public enum ConflictResolution {
    /// Continue the existing task (resuming if needed), discard the incoming.
    case resumeExisting
    /// Cancel/remove the existing task, start fresh with the incoming URL.
    case restart
    /// Add the incoming download with a deduplicated filename suffix.
    case addSeparate
    /// Discard the incoming request entirely; leave existing untouched.
    case skip
}

/// Result of DownloadManager.resolveLateIdentity — the one remaining
/// mid-flight identity check, for a redirector-style URL that had nothing
/// knowable at request time. See DownloadTask.originalName's doc comment.
public enum LateIdentityOutcome {
    /// Nothing else claims this URL or name — proceed exactly as before,
    /// no dialog, nothing blocked.
    case noConflict
    /// The person answered the conflict dialog with a real outcome to keep
    /// going with — either "replace existing" (the plain candidate name,
    /// now free) or "save as separate" (a deduplicated alternate name).
    case resolved(URL)
    /// The person chose not to proceed — this task has already been torn
    /// down (cancelDownload) by the time this is returned.
    case discard
}

/// Thrown internally by addDownload when a conflict is detected and queued.
/// Callers that use try? silently drop this — resolution happens through the
/// DuplicateDownloadSheet UI, not through error handling.
/// Thrown by the `add…` functions when the request was handed to the
/// duplicate sheet instead of becoming a task. Not a failure: the request is
/// alive, waiting on a person's answer, so a caller that presents errors must
/// tell this apart from a real one rather than showing it.
public struct DownloadConflictError: Error {}

public extension Notification.Name {
    static let downloadCompleted = Notification.Name("downloadCompleted")
    static let concurrencyLimitReached = Notification.Name("concurrencyLimitReached")
    /// Posted whenever pendingConflict becomes a new (different) conflict —
    /// see its doc comment above. The app layer uses this to bring the
    /// window forward for the duplicate-conflict sheet, gated by
    /// AppSettings.alwaysFocusForRequiredInput.
    static let downloadConflictNeedsAttention = Notification.Name("downloadConflictNeedsAttention")
}
