import SwiftUI
import DownloadEngine

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @AppStorage("settingsSelectedSection") private var selectedSectionName = SettingsSection.general.rawValue

    var body: some View {
        TabView(selection: Binding(
            get: { SettingsSection(rawValue: selectedSectionName) ?? .general },
            set: { selectedSectionName = $0.rawValue }
        )) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape.fill") }
                .tag(SettingsSection.general)

            DownloadSettingsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
                .tag(SettingsSection.downloads)

            BrowserIntegrationView()
                .tabItem { Label("Browser", systemImage: "globe") }
                .tag(SettingsSection.browser)

            YouTubeSettingsView()
                .tabItem { Label("YouTube", systemImage: "play.rectangle.fill") }
                .tag(SettingsSection.youtube)

            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver.fill") }
                .tag(SettingsSection.advanced)
        }
        // No .tabViewStyle needed here — hosting this TabView inside the
        // app's `Settings { }` scene (see ConvoyApp.swift) already
        // makes AppKit render it as a native preference-pane toolbar, the
        // same mechanism Safari/Mail/Xcode use. Letting it size and space
        // the icon+label items itself (rather than the old fixed-width
        // Label wrapper) is what actually reads as "native" — AppKit's own
        // toolbar layout already centers and spaces these correctly.
        .frame(width: 640, height: 400)
        .preferredColorScheme(settings.theme.colorScheme)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case downloads
    case browser
    case youtube
    case advanced

    var id: String { rawValue }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    private struct LanguageChoice: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    private let audioLanguages = [
        LanguageChoice(code: "", name: "Original"),
        LanguageChoice(code: "en", name: "English"),
        LanguageChoice(code: "es", name: "Spanish"),
        LanguageChoice(code: "fr", name: "French"),
        LanguageChoice(code: "de", name: "German"),
        LanguageChoice(code: "hi", name: "Hindi"),
        LanguageChoice(code: "it", name: "Italian"),
        LanguageChoice(code: "ja", name: "Japanese"),
        LanguageChoice(code: "ko", name: "Korean"),
        LanguageChoice(code: "pt", name: "Portuguese"),
        LanguageChoice(code: "zh", name: "Chinese")
    ]

    var body: some View {
        Form {
            // About then Updates, the order System Settings > General uses.
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
            }

            UpdatesSection()

            Section {
                Picker("Appearance", selection: $settings.theme) {
                    ForEach(AppSettings.AppTheme.allCases) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Choose whether Convoy follows the system appearance or stays light or dark.")
            }

            Section {
                Toggle("Download notifications", isOn: $settings.showNotifications)
                Toggle("Completion sound", isOn: $settings.playCompletionSound)
                    .disabled(!settings.showNotifications)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Plays whatever sound and respects whatever Focus settings you've chosen for notifications on your Mac.")
            }

            Section("Downloads") {
                Toggle("Start downloads automatically", isOn: $settings.autoStartDownloads)
                Toggle("Bring Convoy to the front when a download is captured", isOn: $settings.bringWindowToFrontOnCapture)
                Toggle("Focus Convoy for dialogs that need your input", isOn: $settings.alwaysFocusForRequiredInput)
            }

            Section {
                Picker("App language", selection: $settings.language) {
                    Text("English").tag("en")
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Additional languages are planned for a future update.")
            }

            Section {
                Picker("Preferred audio language", selection: $settings.preferredAudioLanguage) {
                    ForEach(audioLanguages) { language in
                        Text(language.name).tag(language.code)
                    }
                }
            } header: {
                Text("Audio language")
            } footer: {
                Text("Used when a video has dubbed audio or several audio tracks, otherwise the original. YouTube downloads can override it per download.")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

struct DownloadSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    /// Re-checked on appear and right after choosing a new folder — a plain
    /// computed property here would also re-run FileManager on every
    /// unrelated redraw (every keystroke in another field, etc.), which
    /// isn't worth it for something that only ever changes from user action
    /// or external deletion. Note this deliberately does *not* re-check
    /// live while Settings just sits open in the background — if you delete
    /// the folder in Finder while Settings happens to be open, this won't
    /// notice until the next appear/change. Acceptable: the check that
    /// actually matters (DownloadTask.start()) always runs fresh at
    /// download time regardless of what this shows.
    @State private var folderExists = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Default folder") {
                    HStack(spacing: 10) {
                        if !folderExists {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("This folder can't be found")
                        }
                        Text(settings.downloadDirectory)
                            .foregroundStyle(folderExists ? .secondary : Color.orange)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { selectDirectory() }
                    }
                }
            } header: {
                Text("Download Location")
            } footer: {
                if folderExists {
                    Text("Applies to new downloads only — downloads already in progress keep saving to the folder they started in.")
                } else {
                    Text("This folder can't be found — it may have been moved or deleted. Choose a new one; new downloads will otherwise pause and ask before saving here again.")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                NumericSettingRow(
                    title: "Concurrent downloads",
                    detail: "How many files can download at the same time.",
                    value: $settings.maxConcurrentDownloads,
                    range: 1...10
                )

                NumericSettingRow(
                    title: "Segments per download",
                    detail: "More segments can improve speed on suitable servers.",
                    value: $settings.defaultSegmentCount,
                    range: 1...16
                )
            } header: {
                Text("Defaults")
            } footer: {
                Text("Segment count applies to new downloads only. The concurrent-download limit applies immediately, including to downloads already waiting.")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .onAppear { checkFolderExists() }
        .onChange(of: settings.downloadDirectory) { checkFolderExists() }
    }

    private func checkFolderExists() {
        folderExists = FileManager.default.fileExists(atPath: settings.downloadDirectory)
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.downloadDirectory = url.path
        }
    }
}

private struct NumericSettingRow: View {
    let title: String
    let detail: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Text("\(value)")
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 34)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(title)
                    .accessibilityValue("\(value)")

                Stepper("Adjust \(title)", value: $value, in: range)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }
}

struct AdvancedSettingsView: View {
    var body: some View {
        Form {
            Section {
                TemporaryFilesRow()
                TemporaryFilesThresholdRow()
            } header: {
                Text("Storage")
            } footer: {
                Text("Leftovers from a crash or a force-quit, not belonging to any download in your list. Doesn't affect the files used by unfinished downloads.")
            }

            Section {
                RestoreDefaultsRow()
            } header: {
                Text("Maintenance")
            } footer: {
                Text("Puts every setting back to how it was when you installed the app. Downloads aren't affected.")
            }

        }
        .formStyle(.grouped)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

private struct UpdatesSection: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }
            ))
            LabeledContent("Check now") {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Convoy checks once a day and asks before installing anything.")
        }
    }
}

/// How much has to accumulate before the main window says so at launch.
///
/// Runs over the index because the stops double (1, 2, 4, 8). No `step:`:
/// a stepped slider draws ticks and AppKit's flat tick-mark style with it,
/// so the binding snaps to whole stops instead.
private struct TemporaryFilesThresholdRow: View {
    @ObservedObject private var settings = AppSettings.shared

    private var choices: [Double] { TemporaryStorageNotice.thresholdChoicesGB }

    var body: some View {
        LabeledContent("Alert when temp files occupy more than") {
            VStack(alignment: .leading, spacing: 3) {
                Slider(value: selectedIndex, in: 0...Double(choices.count - 1))

                HStack(spacing: 0) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { position, gb in
                        Text("\(Int(gb)) GB")
                        if position < choices.count - 1 { Spacer(minLength: 0) }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(width: 220)
        }
    }

    /// Reads through `nearestChoiceGB`, so a value stored by an earlier build
    /// (3.5 GB, say) lands on a real stop instead of between two.
    private var selectedIndex: Binding<Double> {
        Binding(
            get: {
                let snapped = TemporaryStorageNotice.nearestChoiceGB(
                    to: settings.temporaryFilesNoticeThresholdGB
                )
                return Double(choices.firstIndex(of: snapped) ?? 0)
            },
            set: { settings.temporaryFilesNoticeThresholdGB = choices[Int($0.rounded())] }
        )
    }
}

/// Settings → Advanced → Storage.
///
/// Shows only what no download can claim, and clears only that. Files
/// belonging to a download that still exists are not "temporary files" from
/// anyone's point of view — they are that download's progress, and a paused
/// download resumes from exactly those bytes. They are never counted here and
/// never offered, so this control cannot destroy resumable progress however it
/// is pressed. That is why there is no confirmation: with nothing at stake
/// there is nothing to ask.
///
/// The only thing that clears orphans. Nothing sweeps automatically, so what a
/// crashed run stranded sits here until this is pressed; past a threshold the
/// main window says so (`TemporaryStorageNotice`) rather than waiting to be
/// found. The row stays visible at zero so it reads as a status rather than
/// appearing only when something is wrong.
private struct TemporaryFilesRow: View {
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var isClearing = false

    var body: some View {
        LabeledContent("Temporary files") {
            HStack(spacing: 10) {
                Text(sizeText)
                    .font(.callout)
                    .foregroundStyle(downloadManager.orphanedTemporaryBytes > 0 ? .primary : .secondary)

                // Always present, disabled when there is nothing to act on,
                // rather than appearing and vanishing. A control that comes
                // and goes moves the row around it and needs a message to
                // explain its absence.
                Button("Clear") {
                    Task { await clear() }
                }
                .disabled(isClearing || downloadManager.orphanedTemporaryBytes == 0)
            }
        }
        // Fires when Settings opens, when the Advanced tab is switched to, and
        // when the window is reopened — not when it merely regains focus.
        // Shows the last figure until the walk finishes, so nothing flickers.
        .task { await downloadManager.refreshOrphanedTemporaryBytes() }
    }

    private var sizeText: String {
        formatBytes(downloadManager.orphanedTemporaryBytes)
    }

    private func clear() async {
        isClearing = true
        // The re-read inside this is the feedback: whatever was freed stops
        // being counted, so the number falls to nothing and the button goes
        // quiet. Nothing has to be remembered about what just happened.
        await downloadManager.clearOrphanedTemporaryFiles()
        isClearing = false
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = bytes == 0 ? [.useMB] : [.useGB, .useMB]
        f.countStyle = .file
        // Off, or zero formats as the words "Zero KB" — which also ignores
        // allowedUnits. The row is a figure that changes; it should read as
        // one at every value, including nothing.
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: bytes)
    }
}

private struct RestoreDefaultsRow: View {
    @State private var isConfirming = false

    var body: some View {
        LabeledContent("Settings") {
            Button("Restore Defaults…") { isConfirming = true }
        }
        .alert("Restore all settings to their defaults?", isPresented: $isConfirming) {
            Button("Restore Defaults", role: .destructive) {
                AppSettings.shared.restoreDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your downloads, their files and the download list stay as they are.")
        }
    }
}
