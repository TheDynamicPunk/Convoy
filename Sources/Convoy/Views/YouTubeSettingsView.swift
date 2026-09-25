import SwiftUI
import DownloadEngine

/// Settings → YouTube.
///
/// Leads with one plain answer, "do YouTube downloads work?", and its one
/// action. Helper names are only a caption; the optional PO-Token provider has
/// its own section below, shown once the required helpers are in, since its
/// yt-dlp plugin does nothing without yt-dlp.
struct YouTubeSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var status: YouTubeHelperInstaller.Status?
    @StateObject private var mainInstall = InstallRun()
    @StateObject private var poTokenInstall = InstallRun()

    private var isBusy: Bool { mainInstall.isRunning || poTokenInstall.isRunning }

    private enum Readiness {
        case notSetUp
        /// yt-dlp is in but the JS runtime isn't: some videos lose formats.
        case needsAttention
        case ready
    }

    private var readiness: Readiness? {
        guard let status else { return nil }
        if !status.ytdlpInstalled { return .notSetUp }
        return status.jsRuntimeInstalled ? .ready : .needsAttention
    }

    var body: some View {
        Form {
            Section {
                if let readiness, let status {
                    readinessRow(readiness, status: status)
                    InstallOutput(run: mainInstall)
                } else {
                    ProgressView().controlSize(.small)
                }
            } header: {
                Text("YouTube Downloads")
            } footer: {
                Text("Helpers are downloaded from their official releases. Newer versions come with Convoy updates.")
            }

            if let status, status.ytdlpInstalled {
                Section {
                    Toggle("Keep helpers up to date", isOn: $settings.keepHelpersUpToDate)
                    HelperAutoUpdateStatus()
                } footer: {
                    Text("When a Convoy update includes newer helpers, fetch them automatically — about 50 MB. Skipped on a personal hotspot or in Low Data Mode.")
                }
            }

            Section("Sign-in") {
                Toggle("Use browser cookies for YouTube", isOn: $settings.youtubeUseBrowserCookies)
                if settings.youtubeUseBrowserCookies {
                    Picker("Read cookies from", selection: $settings.youtubeCookieBrowser) {
                        ForEach(AppSettings.supportedCookieBrowsers, id: \.self) { browser in
                            Text(browser.capitalized).tag(browser)
                        }
                    }
                }
                Text("YouTube increasingly refuses signed-out downloads — returning no usable formats, or a link that stops working part-way through the file. Using your browser's logged-in session is the standard fix. Cookies are read on this Mac and sent only to YouTube; macOS may ask for Keychain permission the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let status, status.ytdlpInstalled {
                Section {
                    poTokenRow(status)
                    InstallOutput(run: poTokenInstall)
                } header: {
                    Text("Optional")
                } footer: {
                    Text("Also called a PO-Token provider. Downloads work without it today.")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .task { status = await YouTubeHelperInstaller.shared.currentStatus() }
    }

    // MARK: - Rows

    /// Only says anything when there is something to say.
    private struct HelperAutoUpdateStatus: View {
        @ObservedObject private var autoUpdate = HelperAutoUpdate.shared

        var body: some View {
            switch autoUpdate.state {
            case .idle:
                EmptyView()
            case .updating:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Updating helpers…").font(.callout)
                }
            case .waiting(let reason):
                Label(message(for: reason), systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }

        private func message(for reason: HelperAutoUpdate.Reason) -> String {
            switch reason {
            case .turnedOff:
                "Newer helpers are available. Reinstall above to get them."
            case .meteredConnection:
                "Newer helpers are available, waiting for a connection that isn't metered."
            case .failed:
                "Couldn't update the helpers. Convoy will try again next time it opens."
            }
        }
    }

    @ViewBuilder
    private func readinessRow(_ readiness: Readiness, status: YouTubeHelperInstaller.Status) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                switch readiness {
                case .notSetUp:
                    Label("Not set up", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    caption("YouTube downloads need two small helpers, about 53 MB.")
                case .needsAttention:
                    Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    caption("The JavaScript runtime is missing, so some videos may offer fewer qualities or fail to load.")
                case .ready:
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    caption([status.ytdlpVersion.map { "yt-dlp \($0)" } ?? "yt-dlp", "JavaScript runtime installed"]
                        .joined(separator: " · "))
                }
            }
            Spacer(minLength: 12)
            installButton(readiness)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func installButton(_ readiness: Readiness) -> some View {
        let title = switch readiness {
        case .notSetUp: "Install"
        case .needsAttention: "Fix"
        // Not "Check for Updates": there is nothing online to check. The list
        // of what to install ships with the app, so this re-runs the install
        // against that list -- which repairs a broken helper as well.
        case .ready: "Reinstall"
        }
        let button = Button(title) {
            Task { await install() }
        }
        .disabled(isBusy)

        if readiness == .ready {
            button
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    private func poTokenRow(_ status: YouTubeHelperInstaller.Status) -> some View {
        let installed = status.potInstalled && status.potPluginInstalled
        // The server binary and its yt-dlp plugin are useless apart, so half
        // installed is reported as broken, never as partial progress.
        let incomplete = status.potInstalled != status.potPluginInstalled
        let title = installed ? "Update" : (incomplete ? "Repair" : "Install")

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Bot-check helper")
                caption("Only needed if YouTube starts refusing downloads or asks you to prove you're not a bot. About 41 MB.")
            }
            Spacer(minLength: 12)
            if installed {
                statusBadge(installed: true, detail: nil)
            } else if incomplete {
                Label("Incomplete", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Button(title) {
                Task { await installPOToken() }
            }
            .disabled(isBusy)
        }
        .padding(.vertical, 4)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statusBadge(installed: Bool, detail: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(installed ? .green : .secondary)
            Text(installed ? (detail ?? "Installed") : "Not installed")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func installPOToken() async {
        let wasInstalled = status.map { $0.potInstalled && $0.potPluginInstalled } ?? false
        await poTokenInstall.run(describe: { Self.describe($0, wasInstalled: wasInstalled) }) {
            try await YouTubeHelperInstaller.shared.installPOTokenProvider(progress: $0)
        }
        status = await YouTubeHelperInstaller.shared.currentStatus()
    }

    private func install() async {
        let wasSetUp = readiness.map { $0 != .notSetUp } ?? false
        await mainInstall.run(describe: { Self.describe($0, wasInstalled: wasSetUp) }) {
            try await YouTubeHelperInstaller.shared.installOrUpdate(progress: $0)
        }
        status = await YouTubeHelperInstaller.shared.currentStatus()
    }

    /// A first install needs no message: the status changing says it.
    private static func describe(_ result: HelperUpdateResult, wasInstalled: Bool) -> InstallRun.Message? {
        if result.updated.isEmpty {
            // checkedOnline is always false now that no feed is fetched, and
            // saying so read as a failure. Matching the list the app shipped
            // with IS up to date.
            return .upToDate("Already up to date.")
        }
        guard wasInstalled else { return nil }
        return .upToDate("Updated \(ListFormatter.localizedString(byJoining: result.updated)).")
    }
}

/// One install's progress, warnings and error.
///
/// Events arrive from the installer and from URLSession's delegate queue.
/// They're read in order from one stream: a `Task` per event could apply a
/// late byte count after the switch to "Installing", or after the install
/// finished and the bar was cleared.
@MainActor
private final class InstallRun: ObservableObject {
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
private struct InstallOutput: View {
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
                            Text("\(Self.size(progress.receivedBytes)) of \(Self.size(expected))")
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

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
