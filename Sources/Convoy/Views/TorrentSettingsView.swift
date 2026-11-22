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
    @State private var status: TorrentHelperInstaller.Status?
    @StateObject private var installRun = InstallRun()
    @State private var isDefaultMagnetHandler = false
    @State private var magnetHandlerError: String?

    // Draft state for launch-time helper settings so users can choose between
    // Save (applies on next Convoy relaunch) and Save & Restart Helper (applies now).
    @State private var draftUploadLimitKBps = 0
    @State private var draftListenPort = 0
    @State private var draftEnableUPnP = false
    @State private var draftEnableLSD = false
    @State private var draftPersistDHT = false
    @State private var hasPendingHelperRestart = false
    @State private var isRestartingHelper = false

    private var hasUnsavedHelperChanges: Bool {
        draftUploadLimitKBps != max(0, settings.torrentUploadLimitKBps)
        || draftListenPort != settings.torrentListenPort
        || draftEnableUPnP != settings.torrentEnableUPnP
        || draftEnableLSD != settings.torrentEnableLSD
        || draftPersistDHT != settings.torrentPersistDHT
    }

    var body: some View {
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

                LabeledContent("Upload speed limit") {
                    HStack(spacing: 8) {
                        TextField(
                            "Upload speed limit",
                            value: Binding(
                                get: { max(0, draftUploadLimitKBps) },
                                set: { draftUploadLimitKBps = max(0, $0) }
                            ),
                            format: .number
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)

                        Text(draftUploadLimitKBps > 0 ? "KB/s" : "KB/s (0 = unlimited)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Seeding")
            } footer: {
                Text("Torrents upload to other peers while downloading regardless of this setting. Seeding policy changes apply immediately; upload limit changes take effect when you save and restart the helper or relaunch Convoy.")
            }

            Section {
                LabeledContent("Listening port") {
                    HStack(spacing: 8) {
                        TextField(
                            "Listening port",
                            value: Binding(
                                get: { draftListenPort },
                                set: { newValue in
                                    if newValue <= 0 {
                                        draftListenPort = 0
                                    } else {
                                        draftListenPort = min(max(newValue, 1024), 65535)
                                    }
                                }
                            ),
                            format: .number
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)

                        Text(draftListenPort == 0 ? "Random (recommended)" : "Fixed port")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("UPnP port forwarding", isOn: $draftEnableUPnP)
                Toggle("Local peer discovery", isOn: $draftEnableLSD)
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Remember DHT nodes between launches", isOn: $draftPersistDHT)
                    Text("Stores routing nodes in ~/Library/Caches/com.rqbit.dht to speed up peer discovery on launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if hasUnsavedHelperChanges || hasPendingHelperRestart {
                    helperApplyRow
                }
            } header: {
                Text("Network")
            } footer: {
                Text("BitTorrent downloads are visible to other people sharing the same torrent. Save to apply on next Convoy relaunch, or Save & Restart Helper to apply immediately.")
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
        .onAppear {
            loadHelperDrafts()
        }
        .task {
            status = await TorrentHelperInstaller.shared.currentStatus()
            refreshDefaultMagnetHandler()
        }
    }

    // MARK: - Helper launch-settings save / restart

    @ViewBuilder
    private var helperApplyRow: some View {
        HStack(spacing: 10) {
            if hasUnsavedHelperChanges {
                Text("Unsaved helper changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Save") {
                    commitHelperDrafts()
                    hasPendingHelperRestart = true
                }
                .disabled(isRestartingHelper)
                Button("Save & Restart Helper") {
                    Task { await saveAndRestartHelper() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRestartingHelper)
            } else if hasPendingHelperRestart {
                Text("Saved — will apply on next Convoy relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Restart Helper Now") {
                    Task { await restartHelperNow() }
                }
                .disabled(isRestartingHelper)
            }
            if isRestartingHelper {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func loadHelperDrafts() {
        draftUploadLimitKBps = max(0, settings.torrentUploadLimitKBps)
        draftListenPort = settings.torrentListenPort
        draftEnableUPnP = settings.torrentEnableUPnP
        draftEnableLSD = settings.torrentEnableLSD
        draftPersistDHT = settings.torrentPersistDHT
    }

    private func commitHelperDrafts() {
        settings.torrentUploadLimitKBps = max(0, draftUploadLimitKBps)
        settings.torrentListenPort = draftListenPort
        settings.torrentEnableUPnP = draftEnableUPnP
        settings.torrentEnableLSD = draftEnableLSD
        settings.torrentPersistDHT = draftPersistDHT
    }

    private func saveAndRestartHelper() async {
        commitHelperDrafts()
        await restartHelperNow()
    }

    private func restartHelperNow() async {
        isRestartingHelper = true
        await DownloadManager.shared.restartTorrentHelper()
        hasPendingHelperRestart = false
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
