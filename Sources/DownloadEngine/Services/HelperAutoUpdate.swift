import Foundation
import Network
import os

/// Brings installed helpers into line with the list the app shipped with.
///
/// With no feed, a new helper version arrives inside an app update: Sparkle
/// installs Convoy 1.1, whose bundled list names a newer yt-dlp, while the
/// yt-dlp actually on disk is still the old one. Nothing else reconciles
/// those, so without this the user has the fix and isn't running it.
///
/// Three things keep it from being rude:
///
/// 1. It only ever acts for someone who already installed helpers. Keeping
///    them current maintains a choice already made; making it for the first
///    time stays a button.
/// 2. It does nothing on a metered or Low Data Mode connection. yt-dlp alone
///    is over 50 MB and it is the helper that changes most often.
/// 3. It costs nothing on a normal launch. The bundled list's `sequence` is
///    compared against the last one reconciled, so the real (process-spawning)
///    version checks only run after an update that actually changed the list.
@MainActor
public final class HelperAutoUpdate: ObservableObject {
    public static let shared = HelperAutoUpdate()

    public enum State: Equatable, Sendable {
        case idle
        /// Fetching newer helpers right now.
        case updating
        /// Newer helpers are listed but were not fetched, and why.
        case waiting(Reason)
    }

    public enum Reason: Equatable, Sendable {
        /// The person turned automatic helper updates off.
        case turnedOff
        /// Personal hotspot, cellular, or Low Data Mode.
        case meteredConnection
        /// It was tried and failed; it will be retried on the next launch.
        case failed
    }

    @Published public private(set) var state: State = .idle

    private static let lastSequenceKey = "helperAutoUpdateLastSequence"
    private static let logger = Logger(subsystem: "Convoy", category: "HelperAutoUpdate")

    private init() {}

    /// Safe to call on every launch; returns immediately in the common case.
    public func runAtLaunch() {
        Task { await reconcile() }
    }

    func reconcile() async {
        guard let manifest = try? await HelperManifestStore.shared.manifest() else { return }

        let defaults = UserDefaults.standard
        let lastReconciled = defaults.object(forKey: Self.lastSequenceKey) as? Int

        // The cheap path, taken on all but a handful of launches.
        guard lastReconciled != manifest.sequence else { return }

        // Never installed helpers: nothing to maintain. Recorded so this
        // doesn't re-evaluate on every launch until the list changes again.
        guard await YouTubeHelperInstaller.shared.currentStatus().ytdlpInstalled else {
            defaults.set(manifest.sequence, forKey: Self.lastSequenceKey)
            return
        }

        guard AppSettings.shared.keepHelpersUpToDate else {
            state = .waiting(.turnedOff)
            return
        }

        if await Self.connectionIsMetered() {
            Self.logger.notice("helpers are out of date; waiting for a connection that isn't metered")
            state = .waiting(.meteredConnection)
            return
        }

        state = .updating
        do {
            let result = try await YouTubeHelperInstaller.shared.installOrUpdate { _ in }
            defaults.set(manifest.sequence, forKey: Self.lastSequenceKey)
            state = .idle
            Self.logger.notice("""
            brought helpers up to list \(manifest.sequence, privacy: .public): \
            updated \(result.updated.joined(separator: ", "), privacy: .public)
            """)
        } catch {
            // Deliberately not recording the sequence, so the next launch
            // tries again.
            state = .waiting(.failed)
            Self.logger.error("could not update helpers: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// True for a personal hotspot or cellular link (`isExpensive`) and for
    /// Low Data Mode (`isConstrained`).
    ///
    /// Treats "no answer" as metered: the only cost of being wrong that way is
    /// updating on the next launch instead, whereas being wrong the other way
    /// spends someone's data allowance without asking.
    private static func connectionIsMetered() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "io.github.thedynamicpunk.convoy.pathcheck")
            let settled = OSAllocatedUnfairLock(initialState: false)

            @Sendable func finish(_ metered: Bool) {
                let alreadyDone = settled.withLock { done -> Bool in
                    defer { done = true }
                    return done
                }
                guard !alreadyDone else { return }
                monitor.cancel()
                continuation.resume(returning: metered)
            }

            monitor.pathUpdateHandler = { path in
                finish(path.isExpensive || path.isConstrained)
            }
            monitor.start(queue: queue)
            // NWPathMonitor reports the current path almost immediately; this
            // only covers it never reporting at all.
            queue.asyncAfter(deadline: .now() + 3) { finish(true) }
        }
    }
}
