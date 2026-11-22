import AppKit
import SwiftUI
import DownloadEngine

/// Settings → Torrents.
///
/// Mirrors `YouTubeSettingsView`: leads with helper readiness and a single
/// install/reinstall button, followed by seeding policy, network switches,
/// and the opt-in default magnet-link handler button.
struct TorrentSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var status: TorrentHelperInstaller.Status?
    @StateObject private var installRun = InstallRun()
    @State private var isDefaultMagnetHandler = false
    @State private var magnetHandlerError: String?

    @State private var dismissedRestartBanner = false
    @State private var isRestartingHelper = false

    private var helperConfigSnapshot: TorrentHelperConfig {
        TorrentHelperConfig.current(from: settings)
    }

    private var showsRestartBar: Bool {
        isRestartingHelper || (downloadManager.torrentHelperNeedsRestart && !dismissedRestartBanner)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if let status {
                        readinessRow(status)
                        InstallOutput(run: installRun)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } header: {
                    Text("BitTorrent Helper")
                } footer: {
                    Text("The helper is downloaded from its official release. Newer versions come with Convoy updates.")
                }

                Section {
                    Picker("After downloading", selection: $settings.seedingPolicyMode) {
                        Text("Stop when finished").tag(AppSettings.SeedingPolicyMode.stopAtCompletion)
                        Text("Seed until ratio").tag(AppSettings.SeedingPolicyMode.untilRatio)
                        Text("Seed for a set time").tag(AppSettings.SeedingPolicyMode.untilDuration)
                    }

                    if settings.seedingPolicyMode == .untilRatio {
                        LabeledContent("Target ratio") {
                            HStack(spacing: 8) {
                                Text(ByteFormat.ratio(max(0.25, settings.torrentSeedRatioLimit)))
                                    .font(.body.monospacedDigit())
                                    .frame(minWidth: 44)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                                Stepper(
                                    "Target ratio",
                                    value: Binding(
                                        get: { max(0.25, settings.torrentSeedRatioLimit) },
                                        set: { settings.torrentSeedRatioLimit = max(0.25, ($0 * 4).rounded() / 4) }
                                    ),
                                    in: 0.25...10.0,
                                    step: 0.25
                                )
                                .labelsHidden()
                                .controlSize(.small)
                            }
                        }
                    } else if settings.seedingPolicyMode == .untilDuration {
                        NumericSettingRow(
                            title: "Seed duration",
                            value: Binding(
                                get: { max(15, settings.torrentSeedDurationMinutes) },
                                set: { settings.torrentSeedDurationMinutes = max(15, $0) }
                            ),
                            range: 15...1440,
                            step: 15,
                            unit: "min"
                        )
                    }

                    NumericSettingRow(
                        title: "Upload speed limit (KB/s)",
                        detail: "Max \(TorrentHelperConfig.maxUploadLimitKBps.formatted()) KB/s. Set 0 for unlimited.",
                        value: $settings.torrentUploadLimitKBps,
                        range: 0...TorrentHelperConfig.maxUploadLimitKBps,
                        input: .field
                    )
                } header: {
                    Text("Seeding")
                } footer: {
                    Text("Torrents upload to other peers while downloading regardless of this setting. Seeding policy changes apply immediately; upload limit changes apply after restarting the BitTorrent helper or relaunching Convoy.")
                }

                Section {
                    NumericSettingRow(
                        title: "Listening port",
                        detail: "Choose a port from 1024 to 65535. Set 0 to let Convoy handle it automatically.",
                        value: Binding(
                            get: { settings.torrentListenPort },
                            set: { newValue in
                                if newValue <= 0 {
                                    settings.torrentListenPort = 0
                                } else {
                                    settings.torrentListenPort = NumericSettingRow.clamped(
                                        newValue,
                                        to: TorrentHelperConfig.listenPortRange
                                    )
                                }
                            }
                        ),
                        range: 0...TorrentHelperConfig.listenPortRange.upperBound,
                        input: .field
                    )

                    Toggle("UPnP port forwarding", isOn: $settings.torrentEnableUPnP)
                    Toggle("Local peer discovery", isOn: $settings.torrentEnableLSD)
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle("Remember DHT nodes between launches", isOn: $settings.torrentPersistDHT)
                        Text("Stores routing nodes in ~/Library/Caches/com.rqbit.dht to speed up peer discovery on launch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Network")
                } footer: {
                    Text("BitTorrent downloads are visible to other people sharing the same torrent. Network changes apply after restarting the BitTorrent helper or relaunching Convoy.")
                }

                Section {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Default handler for magnet links")
                            if isDefaultMagnetHandler {
                                Text("Convoy opens magnet links from browsers and other apps.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Set Convoy as the default app when you click a magnet link.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 12)
                        if isDefaultMagnetHandler {
                            Label("Default", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.callout)
                        } else {
                            Button("Use Convoy for Magnet Links") {
                                setDefaultMagnetHandler()
                            }
                        }
                    }
                    if let magnetHandlerError {
                        Text(magnetHandlerError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Magnet Links")
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            if showsRestartBar {
                helperRestartBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .modifier(OutsideClickFocusDismisser())
        .animation(.easeInOut(duration: 0.2), value: showsRestartBar)
        .onChange(of: helperConfigSnapshot) { _, _ in
            dismissedRestartBanner = false
            Task { await downloadManager.refreshTorrentHelperRestartNeeded() }
        }
        .task {
            dismissedRestartBanner = false
            status = await TorrentHelperInstaller.shared.currentStatus()
            refreshDefaultMagnetHandler()
            await downloadManager.refreshTorrentHelperRestartNeeded()
        }
    }

    // MARK: - Pinned helper restart bar

    private var helperRestartBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if isRestartingHelper {
                    ProgressView()
                        .controlSize(.small)
                    Text("Restarting BitTorrent helper…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Restart the helper to apply changes now, or they'll apply on next launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Restart Later") {
                        dismissedRestartBanner = true
                    }
                    Button("Restart Helper") {
                        Task { await restartHelperNow() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func restartHelperNow() async {
        isRestartingHelper = true
        await downloadManager.restartTorrentHelper()
        dismissedRestartBanner = false
        isRestartingHelper = false
    }

    // MARK: - Helper readiness

    @ViewBuilder
    private func readinessRow(_ status: TorrentHelperInstaller.Status) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if status.installed {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(status.version.map { "rqbit \($0)" } ?? "rqbit installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Not set up", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text("BitTorrent downloads need the rqbit helper.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            let button = Button(status.installed ? "Reinstall" : "Install") {
                Task { await install() }
            }
            .disabled(installRun.isRunning)

            if status.installed {
                button
            } else {
                button.buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }

    private func install() async {
        let wasInstalled = status?.installed ?? false
        await installRun.run(describe: { result in
            if result.updated.isEmpty {
                return .upToDate("Already up to date.")
            }
            return wasInstalled ? .upToDate("Updated the BitTorrent helper.") : nil
        }) { progress in
            try await TorrentHelperInstaller.shared.installOrUpdate(progress: progress)
        }
        status = await TorrentHelperInstaller.shared.currentStatus()
    }

    // MARK: - Default magnet handler

    private func refreshDefaultMagnetHandler() {
        guard let magnetURL = URL(string: "magnet:?xt=urn:btih:0000000000000000000000000000000000000000"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: magnetURL) else {
            isDefaultMagnetHandler = false
            return
        }
        isDefaultMagnetHandler = appURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func setDefaultMagnetHandler() {
        magnetHandlerError = nil
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "magnet") { error in
            Task { @MainActor in
                if let error {
                    magnetHandlerError = error.localizedDescription
                }
                refreshDefaultMagnetHandler()
            }
        }
    }
}

/// Resigns text-field focus when the user clicks anywhere outside a text input
/// in the Settings window, so typed values in `NumericSettingRow` commit
/// immediately instead of staying focused until Return is pressed.
private struct OutsideClickFocusDismisser: ViewModifier {
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                    if let window = event.window,
                       window.firstResponder is NSTextView,
                       let contentView = window.contentView,
                       let hit = contentView.hitTest(event.locationInWindow),
                       !Self.isInsideTextInput(hit) {
                        window.makeFirstResponder(nil)
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                    self.monitor = nil
                }
            }
    }

    private static func isInsideTextInput(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is NSTextField || v is NSTextView { return true }
            current = v.superview
        }
        return false
    }
}
