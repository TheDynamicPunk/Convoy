import SwiftUI
import DownloadEngine

/// One pending delete, whatever raised it. Every entry point builds one of
/// these rather than calling the manager directly, which is what keeps the
/// six of them saying the same thing.
struct DeleteRequest: Identifiable {
    let id = UUID()
    let taskIDs: Set<DownloadTask.ID>
    /// Set when Shift was held on the way in — pre-checks the Trash box the
    /// way Motrix does, so a deliberate "and bin the files" is one gesture
    /// without ever making that the default.
    let preCheckTrash: Bool

    init(taskIDs: Set<DownloadTask.ID>, preCheckTrash: Bool = false) {
        self.taskIDs = taskIDs
        self.preCheckTrash = preCheckTrash
    }
}

/// The one delete confirmation in the app. Its content is derived from what's
/// actually in the selection — never from which control was pressed — so a
/// row, a multi-selection and a category delete are all the same decision
/// presented at the same weight.
///
/// A sheet rather than `.confirmationDialog`/`.alert` because neither of
/// those can host the Trash checkbox, and the checkbox is the whole point:
/// it's what turns "delete" from an ambiguous word into two separate,
/// visible outcomes.
struct DeleteConfirmationSheet: View {
    @EnvironmentObject var downloadManager: DownloadManager
    let request: DeleteRequest
    let onComplete: (DeletionOutcome) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var moveFilesToTrash: Bool
    @State private var isDeleting = false

    init(request: DeleteRequest, onComplete: @escaping (DeletionOutcome) -> Void) {
        self.request = request
        self.onComplete = onComplete
        _moveFilesToTrash = State(initialValue: request.preCheckTrash)
    }

    private var plan: DeletionPlan {
        let all = downloadManager.tasks + downloadManager.completedTasks
        return DeletionPlan(tasks: all.filter { request.taskIDs.contains($0.id) })
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
        // Everything here vanished while the sheet was open (finished and
        // cleared elsewhere, say) — there's nothing left to confirm.
        .onChange(of: plan.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.red.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "trash")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.red)
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(messageLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if plan.trashableCount > 0 {
                Toggle(isOn: $moveFilesToTrash) {
                    Text(trashToggleLabel)
                        .font(.system(size: 12.5))
                }
                .toggleStyle(.checkbox)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: - Actions

    /// Exactly one filled button — the default one, in the system accent —
    /// and nothing tinted red, which is how macOS's own destructive alerts
    /// are built (Finder's Empty Trash / Delete Immediately included). The
    /// severity is carried by the header icon and the verb; a second filled
    /// button would only make it ambiguous which one Return actually hits.
    private var actions: some View {
        HStack(spacing: 12) {
            Spacer()

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .frame(minWidth: 76)

            Button(confirmLabel) {
                performDelete()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isDeleting)
            .frame(minWidth: 76)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 20)
    }

    private func performDelete() {
        guard !isDeleting else { return }
        isDeleting = true
        let ids = request.taskIDs
        let trash = moveFilesToTrash
        Task {
            let outcome = await downloadManager.delete(taskIDs: ids, moveFilesToTrash: trash)
            onComplete(outcome)
            dismiss()
        }
    }

    // MARK: - Copy

    private var title: String {
        if let single = plan.single {
            return "Delete \"\(single.filename)\"?"
        }
        return "Delete \(plan.count) downloads?"
    }

    private var confirmLabel: String {
        plan.count > 1 ? "Delete \(plan.count)" : "Delete"
    }

    /// One line per consequence that actually applies. Deliberately states
    /// what happens to bytes, not what happens to rows — "removes it from
    /// the list" was the old copy's whole message and it's the least
    /// important half of the truth.
    private var messageLines: [String] {
        if let single = plan.single { return singleLines(for: single) }
        return multiLines
    }

    private func singleLines(for item: DeletionPlan.Item) -> [String] {
        switch item.impact {
        case .finishedFile:
            return ["Delete from your downloads list?"]
        case .finishedFileMissing:
            // Unreachable in practice — DeletionPlan.isTriviallyDeletable
            // routes this case around the sheet entirely (see
            // ContentView.requestDelete). Kept as a sane fallback in case a
            // future caller presents the sheet without checking that first.
            return ["This removes it from your downloads list. The file is already gone from where it was saved."]
        case .discardsProgress(let bytes):
            if item.isFailed {
                return ["Delete this download and discard the \(formatBytes(bytes)) already downloaded?"]
            }
            return ["This download hasn't finished — its progress will be lost."]
        case .nothingToLose:
            // Also unreachable — same reasoning as .finishedFileMissing above.
            return ["This removes it from your downloads list."]
        }
    }

    private var multiLines: [String] {
        var lines: [String] = []

        let unfinished = plan.progressDiscardingCount
        if unfinished > 0 {
            let bytes = formatBytes(plan.progressDiscardingBytes)
            let noun = unfinished == 1 ? "download" : "downloads"
            lines.append("This will discard \(bytes) already downloaded across \(unfinished) unfinished \(noun).")
        }

        // No separate line for the finished-file bucket: the checkbox below
        // ("Move N finished files to Trash") already says what happens to
        // them, unticked by default, same as the single-item case never
        // explains its own checkbox in prose either. A sentence here would
        // just be narrating the control sitting three lines down.
        //
        // When the whole selection is finished files and nothing is
        // unfinished, that leaves this empty — which is exactly when the
        // fallback below becomes the only (and correct) line: a plain "this
        // just removes them from the list", mirroring the single-item
        // completed case's plain title-only framing.
        if lines.isEmpty {
            lines.append("This removes them from your downloads list.")
        }
        return lines
    }

    private var trashToggleLabel: String {
        let bytes = formatBytes(plan.trashableBytes)
        if plan.single != nil {
            return "Move file to Trash (\(bytes))"
        }
        let noun = plan.trashableCount == 1 ? "finished file" : "finished files"
        return "Move \(plan.trashableCount) \(noun) to Trash (\(bytes))"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(bytes)
        var unit = 0
        while size >= 1024 && unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        return String(format: "%.1f %@", size, units[unit])
    }
}
