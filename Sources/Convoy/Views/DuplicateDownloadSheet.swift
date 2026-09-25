import SwiftUI
import DownloadEngine

/// Presented by ContentView (via .sheet(item: downloadManager.conflictBinding))
/// whenever DownloadManager detects that an incoming download would land on
/// the same filename in the same folder as an existing task.
///
/// Interactive dismissal is disabled - the user must pick one of the four
/// resolution paths. This matches macOS own "Replace or Keep Both?" pattern
/// (Finder duplicate-file dialog) so the mental model is familiar.
struct DuplicateDownloadSheet: View {
    @EnvironmentObject var downloadManager: DownloadManager
    let conflict: DuplicateDownloadConflict
    /// ObservedObject wrapper so the card updates live if the task status
    /// or progress changes while the sheet is open.
    @ObservedObject private var existing: DownloadTask

    init(conflict: DuplicateDownloadConflict) {
        self.conflict = conflict
        self._existing = ObservedObject(wrappedValue: conflict.existingTask)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            details
            Divider()
            actions
        }
        .frame(width: 420)
        .interactiveDismissDisabled()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Already in your list")
                    .font(.system(size: 14, weight: .semibold))
                Text(existing.filename)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Current download")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                existingTaskCard
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(conflict.resolvingTaskID != nil ? "Waiting on your decision" : "New request")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Text(conflict.incomingURL.absoluteString)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var existingTaskCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(existingStatusText)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(existingStatusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(existingStatusColor.opacity(0.12), in: Capsule())

                Spacer()

                if existing.totalBytes > 0 {
                    Text(formatBytes(existing.downloadedBytes) + " / " + formatBytes(existing.totalBytes))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if showsProgressBar {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                        Capsule()
                            .fill(existingStatusColor.opacity(0.75))
                            .frame(width: max(4, geo.size.width * existing.progress))
                            .animation(.easeOut(duration: 0.25), value: existing.progress)
                    }
                }
                .frame(height: 5)
            }

            Text(existing.url.absoluteString)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 8) {
            // Hidden only when there is genuinely nothing to resume
            // (completed or cancelled tasks) — in that case the closest
            // equivalent default is promoted below instead, so there's
            // always exactly one visually prominent choice, never zero.
            if showResumeExisting {
                Button(action: { resolve(.resumeExisting) }) {
                    Label(resumeExistingLabel, systemImage: resumeExistingIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.blue)
                // interactiveDismissDisabled() below means Return/Escape
                // otherwise do nothing at all — not an improvement over
                // binding them, just a quieter way of leaving someone with
                // no keyboard path through a dialog they can't click away
                // from. This is also the visually "prominent" button, so
                // Return matches what it already looks like the default.
                .keyboardShortcut(.defaultAction)
            } else {
                // Nothing to resume — the existing file already finished (or
                // its task was cancelled), so the sensible default here is
                // "I already have this, don't need the new one," which is
                // what .skip means. Given the same visual treatment
                // resumeExisting gets above, so there's still one clear
                // default rather than three equally-weighted buttons. The
                // quiet text-link version of this same action further down
                // is deliberately NOT also shown in this branch — it would
                // just be a second control for the exact same resolution.
                Button(action: { resolve(.skip) }) {
                    Label("Keep what I already have", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.blue)
                .keyboardShortcut(.defaultAction)
            }

            Button(action: { resolve(.restart) }) {
                Label(restartLabel, systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(action: { resolve(.addSeparate) }) {
                Label("Save as \"\(conflict.suggestedAlternativeName)\"", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
                    .lineLimit(1)
                    // Middle truncation, not the default tail truncation —
                    // suggestedAlternativeName's whole point is the " (1)"
                    // (or similar) suffix right before the extension, which
                    // is exactly what tail truncation cuts first on a long
                    // title. Middle truncation keeps both the recognizable
                    // start of the title AND that suffix, sacrificing only
                    // the least useful part in between. Matches the same
                    // convention already used above for `existing.filename`
                    // in the header, for the same underlying reason.
                    .truncationMode(.middle)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            if showResumeExisting {
                Button(conflict.resolvingTaskID != nil ? "Cancel this download" : "Skip this download") { resolve(.skip) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    // Escape maps to the most reversible/least surprising
                    // choice here, not a true no-op — interactiveDismissDisabled()
                    // means there isn't one (every option has a real
                    // consequence, by design). Skipping a not-yet-started
                    // request costs nothing; cancelling an in-flight one is
                    // undoable by just downloading it again, unlike "Replace
                    // existing" (destructively removes the OTHER task) or
                    // "Save as" (commits to a specific name). Only bound in
                    // this branch — in the other branch, skip IS the
                    // prominent default above, already reachable via Return.
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 22)
    }

    // MARK: - State helpers

    private var showResumeExisting: Bool {
        switch existing.status {
        case .completed, .cancelled: return false
        default: return true
        }
    }

    /// "Keep existing" when already running/queued; "Resume existing" otherwise.
    private var resumeExistingLabel: String {
        if conflict.resolvingTaskID != nil {
            return "Keep existing, cancel this one"
        }
        switch existing.status {
        case .downloading, .starting, .validating, .refreshingLink, .waiting:
            return "Keep existing download"
        default:
            return "Resume existing download"
        }
    }

    /// "Restart from beginning" makes sense for a brand-new incoming request
    /// (nothing has downloaded yet); for an in-flight conflict, this button
    /// instead hands the plain name over to the download that's already
    /// running, after removing whichever task actually held it — nothing
    /// restarts from the beginning, so the label says what actually happens.
    private var restartLabel: String {
        conflict.resolvingTaskID != nil ? "Replace existing with this one" : "Restart from beginning"
    }

    private var resumeExistingIcon: String {
        switch existing.status {
        case .downloading, .starting, .validating, .refreshingLink, .waiting:
            return "checkmark.circle.fill"
        default:
            return "play.fill"
        }
    }

    private var showsProgressBar: Bool {
        switch existing.status {
        case .downloading, .paused, .waiting, .starting, .validating,
             .refreshingLink, .urlExpired, .destinationMissing:
            return true
        default:
            return false
        }
    }

    private var existingStatusText: String {
        switch existing.status {
        case .waiting:                                  return "Waiting"
        case .starting, .validating, .refreshingLink:   return "Starting"
        case .downloading:                              return "Downloading"
        case .paused:                                   return "Paused"
        case .completed:                                return "Completed"
        case .failed:                                   return "Failed"
        case .cancelled:                                return "Cancelled"
        case .urlExpired:                               return "Expired"
        case .destinationMissing:                       return "Folder Missing"
        case .awaitingDuplicateResolution:               return "Needs Input"
        }
    }

    private var existingStatusColor: Color {
        switch existing.status {
        case .waiting:                                  return .orange
        case .starting, .validating, .refreshingLink,
             .downloading:                              return .blue
        case .paused:                                   return .yellow
        case .completed:                                return .green
        case .failed:                                   return .red
        case .cancelled:                                return .gray
        case .urlExpired:                               return .orange
        case .destinationMissing:                       return .orange
        case .awaitingDuplicateResolution:               return .orange
        }
    }

    private func resolve(_ resolution: ConflictResolution) {
        Task { await downloadManager.resolveConflict(conflict, resolution: resolution) }
    }

    // MARK: - Formatting

    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(bytes)
        var unit = 0
        while size >= 1024, unit < units.count - 1 { size /= 1024; unit += 1 }
        return String(format: "%.1f %@", size, units[unit])
    }
}
