import SwiftUI
import DownloadEngine

/// One helper install's progress, warnings and error.
///
/// Events arrive from the installer and from URLSession's delegate queue.
/// They're read in order from one stream: a `Task` per event could apply a
/// late byte count after the switch to "Installing", or after the install
/// finished and the bar was cleared.
@MainActor
final class InstallRun: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress: HelperInstallProgress?
    @Published private(set) var warnings: [String] = []
    @Published private(set) var error: String?
    @Published private(set) var message: Message?

    enum Message {
        case upToDate(String)
        /// Informational, e.g. the update server couldn't be reached.
        case note(String)
    }

    func run(
        describe: @escaping (HelperUpdateResult) -> Message?,
        _ operation: @escaping @Sendable (@escaping @Sendable (HelperInstallEvent) -> Void) async throws -> HelperUpdateResult
    ) async {
        isRunning = true
        progress = nil
        warnings = []
        error = nil
        message = nil

        let (events, sink) = AsyncStream.makeStream(of: HelperInstallEvent.self)
        let work = Task {
            defer { sink.finish() }
            return try await operation { sink.yield($0) }
        }
        for await event in events {
            switch event {
            case .progress(let update): progress = update
            case .warning(let message): warnings.append(message)
            }
        }
        do {
            message = describe(try await work.value)
        } catch {
            self.error = error.localizedDescription
        }
        progress = nil
        isRunning = false
    }
}

/// The running install's bar, then any warning or error, under its row.
struct InstallOutput: View {
    @ObservedObject var run: InstallRun

    var body: some View {
        if run.progress != nil || !run.warnings.isEmpty || run.error != nil || run.message != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let progress = run.progress {
                    HStack(alignment: .firstTextBaseline) {
                        Text(progress.stepCount > 0
                             ? "\(progress.title) (\(progress.step) of \(progress.stepCount))"
                             : progress.title)
                        Spacer()
                        if let expected = progress.expectedBytes {
                            Text("\(ByteFormat.size(progress.receivedBytes)) of \(ByteFormat.size(expected))")
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                ForEach(run.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = run.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                switch run.message {
                case .upToDate(let text):
                    Label(text, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .note(let text):
                    Label(text, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case nil:
                    EmptyView()
                }
            }
            .padding(.vertical, 2)
        }
    }
}
