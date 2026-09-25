import SwiftUI
import DownloadEngine

// MARK: - Settings → Browser

struct BrowserIntegrationView: View {
    @ObservedObject private var model = BrowserSetupModel.shared
    @State private var isConfirmingRemoveAll = false

    var body: some View {
        Form {
            if !model.isLocationStable {
                Section { MoveToApplicationsNotice() }
            }

            Section {
                if model.rows.isEmpty {
                    Text("No supported browser found. Convoy works with Chrome, Brave, Edge, Vivaldi, Opera, Arc and Chromium.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(model.rows) { row in
                        BrowserRow(row: row, canSetUp: model.isLocationStable,
                                   onSetUp: { model.setUp([row.browser]) },
                                   onRemove: { model.remove(row.browser) })
                    }
                }
            } header: {
                Text("Browsers")
            } footer: {
                Text("Setting up a browser adds a small file that lets the Convoy extension reach the app. If you move the app, Convoy updates these files the next time it opens.")
            }

            Section {
                ExtensionInstallSteps(model: model)
            } header: {
                Text("Extension")
            } footer: {
                Text("The folder is updated along with the app. Browsers load the new version when they restart.")
            }

            Section {
                LabeledContent("Browser integration") {
                    Button("Remove from All Browsers…") { isConfirmingRemoveAll = true }
                        .disabled(!model.rows.contains { $0.status != .notSetUp })
                }
            } header: {
                Text("Uninstall")
            } footer: {
                Text("Deletes the files Convoy added to your browsers. Do this before deleting the app. Remove the extension itself from each browser's extensions page.")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .onAppear { model.refresh() }
        .alert("Remove Convoy from all browsers?", isPresented: $isConfirmingRemoveAll) {
            Button("Remove", role: .destructive) { model.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The extension won't be able to reach the app until you set a browser up again.")
        }
        .alert("Couldn't update the browser", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct BrowserRow: View {
    let row: BrowserSetupModel.Row
    let canSetUp: Bool
    let onSetUp: () -> Void
    let onRemove: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                BrowserStatusLabel(status: row.status)
                switch row.status {
                case .notSetUp:
                    Button("Set Up", action: onSetUp).disabled(!canSetUp)
                case .needsRepair:
                    Button("Repair", action: onSetUp).disabled(!canSetUp)
                case .setUp:
                    Button("Remove", action: onRemove)
                }
            }
        } label: {
            BrowserName(row: row)
        }
    }
}

private struct BrowserName: View {
    let row: BrowserSetupModel.Row

    var body: some View {
        HStack(spacing: 8) {
            if let icon = row.icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "globe").frame(width: 20, height: 20).foregroundStyle(.secondary)
            }
            Text(row.browser.name)
        }
    }
}

private struct BrowserStatusLabel: View {
    let status: BrowserIntegration.Status

    var body: some View {
        switch status {
        case .setUp:
            Label("Set up", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .needsRepair:
            Label("Needs repair", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .notSetUp:
            Text("Not set up")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ExtensionInstallSteps: View {
    @ObservedObject var model: BrowserSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InstallStep(number: 1, text: "In the browser, open the extensions page (chrome://extensions) and turn on Developer mode.")
            // Chromium loads a folder dropped on the extensions page as
            // unpacked, but only with Developer mode on -- hence step 1.
            InstallStep(number: 2, text: "Drag the Convoy extension folder onto that page. Or click Load unpacked and choose it.")
            Button("Show Extension Folder") { model.revealExtensionFolder() }
                .padding(.leading, 26)
        }
        .padding(.vertical, 4)
    }
}

private struct InstallStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(width: 18, height: 18)
                .background(.quaternary, in: Circle())
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MoveToApplicationsNotice: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text("Move Convoy to Applications")
                    .font(.headline)
                Text("It's running from a temporary location, such as the disk image, so browsers can't be set up to reach it. Quit it, move it to Applications, and open it again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - First-launch sheet

struct BrowserSetupSheet: View {
    @ObservedObject private var model = BrowserSetupModel.shared
    @State private var selected: Set<String> = []
    @State private var showsInstallSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                if !model.isLocationStable {
                    MoveToApplicationsNotice()
                } else if showsInstallSteps {
                    ExtensionInstallSteps(model: model)
                } else {
                    browserChoices
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            Divider()
            actions
        }
        .frame(width: 460)
        .interactiveDismissDisabled()
        .onAppear {
            selected = Set(model.rows.filter { $0.status != .setUp }.map(\.id))
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: showsInstallSteps ? "puzzlepiece.extension.fill" : "globe")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(showsInstallSteps ? "Add the extension" : "Connect your browsers")
                    .font(.system(size: 14, weight: .semibold))
                Text(showsInstallSteps
                     ? "Do this once in each browser you set up."
                     : "The Convoy extension sends downloads from your browser to the app.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private var browserChoices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Each browser you pick gets a small file that lets the extension reach Convoy. You can change this later in Settings → Browser.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.rows) { row in
                    if row.status == .setUp {
                        HStack {
                            Toggle(isOn: .constant(true)) { BrowserName(row: row) }.disabled(true)
                            Spacer()
                            Text("Already set up").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Toggle(isOn: Binding(
                            get: { selected.contains(row.id) },
                            set: { if $0 { selected.insert(row.id) } else { selected.remove(row.id) } }
                        )) { BrowserName(row: row) }
                    }
                }
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            if !model.isLocationStable || showsInstallSteps {
                Button("Done") { model.finishFirstRun() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Not Now") { model.finishFirstRun() }
                    .keyboardShortcut(.cancelAction)
                Button(selected.isEmpty ? "Continue" : "Set Up") {
                    if model.setUp(model.rows.filter { selected.contains($0.id) }.map(\.browser)) {
                        showsInstallSteps = true
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty && !model.rows.contains { $0.status == .setUp })
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}
