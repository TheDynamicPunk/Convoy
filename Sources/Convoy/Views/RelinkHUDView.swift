import SwiftUI
import DownloadEngine

/// The re-link window's content, rebuilt from the coordinator's state. The
/// theme is applied here because the panel is its own window.
struct RelinkHUDRoot: View {
    @ObservedObject var coordinator: RelinkCoordinator
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Group {
            if let task = coordinator.task {
                RelinkHUDView(task: task, phase: coordinator.phase, coordinator: coordinator)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .preferredColorScheme(settings.theme.colorScheme)
    }
}

struct RelinkHUDView: View {
    let task: DownloadTask
    let phase: RelinkPhase
    let coordinator: RelinkCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch phase {
            case .listening:
                listening
            case .mismatch(let mismatch):
                mismatchPrompt(mismatch)
            case .success(let restarted):
                success(restarted: restarted)
            }
        }
        .padding(18)
        .frame(width: 400, alignment: .leading)
    }

    // MARK: - Waiting for a capture

    private var listening: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                    .symbolEffect(.variableColor.iterative.reversing)
                Text("Waiting for a fresh link…")
                    .font(.headline)
            }

            fileSummary

            Text("Go back to the page and start this download again. Convoy will catch the new link and check that it is the same file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if task.referrerURL != nil {
                    Button("Copy Source Link") { coordinator.copySourceLink() }
                }
                Spacer()
                Button("Cancel") { coordinator.cancel() }
            }
        }
    }

    // MARK: - A capture that does not match

    private func mismatchPrompt(_ mismatch: RelinkMismatch) -> some View {
        // Judged once and handed to both places that describe it, so the tag
        // and the sentence can never disagree.
        let names = nameVerdict(for: mismatch)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                Text("This doesn’t look like the same file")
                    .font(.headline)
            }

            comparison(mismatch, names: names)

            Text(explanation(for: mismatch, names: names))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Ignore It") { coordinator.ignoreCapture() }
                Spacer()
                Button("Add as New") { coordinator.addAsNewDownload() }
                Button("Re-link & Restart") { coordinator.confirmRestart() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Side by side

    /// A small label shown beside a name or size. `warns` is for a difference
    /// (or something that could not be checked); otherwise it is just a note.
    private typealias Tag = (text: String, warns: Bool)

    private func nameVerdict(for mismatch: RelinkMismatch) -> RelinkNameVerdict {
        RelinkNameVerdict.judge(
            known: [task.filename, task.originalName],
            offered: mismatch.capture.suggestedFilename
        )
    }

    /// The download and the new capture one above the other, with what
    /// differs marked, so the person does not have to compare two sentences.
    private func comparison(_ mismatch: RelinkMismatch, names: RelinkNameVerdict) -> some View {
        let nameTag: Tag
        switch names {
        case .same: nameTag = ("Same name", false)
        case .different: nameTag = ("Different name", true)
        case .unknown: nameTag = ("Name guessed from the link", false)
        }

        let sizeTag: Tag?
        switch mismatch.verdict {
        case .differentSize: sizeTag = ("Different size", true)
        case .cannotVerify: sizeTag = ("Size couldn’t be checked", true)
        case .sameFile: sizeTag = nil
        }

        let currentSize = task.totalBytes > 0 ? ByteFormat.size(task.totalBytes) : "Size unknown"
        let newSize = mismatch.capture.offeredSize.map { ByteFormat.size($0) } ?? "Size unknown"

        return VStack(alignment: .leading, spacing: 10) {
            detail(title: "Current download", name: task.filename, nameTag: nil, size: currentSize, sizeTag: nil)
            Divider()
            detail(title: "New capture", name: mismatch.capture.displayName, nameTag: nameTag, size: newSize, sizeTag: sizeTag)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func detail(title: String, name: String, nameTag: Tag?, size: String, sizeTag: Tag?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            detailRow(name, tag: nameTag, bold: true)
            detailRow(size, tag: sizeTag, bold: false)
        }
    }

    private func detailRow(_ text: String, tag: Tag?, bold: Bool) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 13, weight: bold ? .semibold : .regular))
                .foregroundStyle(tag?.warns == true ? Color.orange : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let tag {
                Text(tag.text)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tag.warns ? Color.orange : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill((tag.warns ? Color.orange : Color.secondary).opacity(0.15)))
                    .fixedSize()
            }
        }
    }

    /// Leads with what differs. The sizes themselves are in the comparison
    /// above, so this only says what it means and what re-linking costs.
    private func explanation(for mismatch: RelinkMismatch, names: RelinkNameVerdict) -> String {
        let discarded = "Re-linking uses the new link and starts again from the beginning, discarding the \(ByteFormat.size(task.downloadedBytes)) already downloaded."
        let what: String
        switch (mismatch.verdict, names) {
        case (.differentSize, .different):
            what = "Both the name and the size are different, so this looks like another file."
        case (.differentSize, _):
            what = "The size is different, so the partial download can’t be continued from this file."
        case (_, .different):
            what = "The name is different, and Convoy couldn’t check the size of the new file."
        default:
            what = "Convoy couldn’t check the size of the new file, so it can’t confirm it matches."
        }
        return "\(what) \(discarded)"
    }

    // MARK: - Done

    private func success(restarted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Link updated")
                    .font(.headline)
                Text(restarted ? "Starting again from the beginning…" : "Resuming where it left off…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Shared

    /// Name, site, and how far the download got.
    private var fileSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.filename)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(summaryLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var summaryLine: String {
        var parts: [String] = []
        if let host = task.url.host { parts.append(host) }
        if task.totalBytes > 0 {
            let percent = Int((Double(task.downloadedBytes) / Double(task.totalBytes) * 100).rounded())
            parts.append("\(ByteFormat.size(task.downloadedBytes)) of \(ByteFormat.size(task.totalBytes)) (\(percent)%)")
        } else {
            parts.append("\(ByteFormat.size(task.downloadedBytes)) downloaded")
        }
        return parts.joined(separator: " · ")
    }
}
