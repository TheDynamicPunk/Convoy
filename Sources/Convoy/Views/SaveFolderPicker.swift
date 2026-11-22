import AppKit
import SwiftUI
import DownloadEngine

private enum SaveFolderChoice: Hashable {
    case automatic
    case folder(URL)
    case other
}

/// Shared "Save to" folder menu used by both `AddDownloadsView` and
/// `CaptureDialogView`.
///
/// Offers Automatic first when categories are active (and allowed for this
/// download kind — torrents skip category routing in v1), followed by
/// standard folders, recently used folders, and Other…
struct SaveFolderPicker: View {
    @Binding var folder: URL?
    let automaticTitle: String
    let allowsAutomatic: Bool
    /// True when hosted inside a non-activating panel (`CaptureDialogView`),
    /// where `NSOpenPanel` needs `NSApp.activate()` to appear in front.
    let activatesAppForOpenPanel: Bool
    /// Optional override for "Other…" (e.g. SwiftUI `.fileImporter` in a sheet).
    /// When nil, opens `NSOpenPanel`.
    let onChooseOther: (() -> Void)?

    @ObservedObject private var settings = AppSettings.shared
    private let manager = DownloadManager.shared
    @State private var recent = RecentDownloadFolders.load()

    init(
        folder: Binding<URL?>,
        automaticTitle: String = "Automatic",
        allowsAutomatic: Bool = true,
        activatesAppForOpenPanel: Bool = false,
        onChooseOther: (() -> Void)? = nil
    ) {
        self._folder = folder
        self.automaticTitle = automaticTitle
        self.allowsAutomatic = allowsAutomatic
        self.activatesAppForOpenPanel = activatesAppForOpenPanel
        self.onChooseOther = onChooseOther
    }

    /// The folder from Settings, where the download manager saves when nothing
    /// else is chosen.
    @MainActor
    static func defaultFolder(for settings: AppSettings? = nil) -> URL {
        let resolved = settings ?? .shared
        return URL(fileURLWithPath: resolved.downloadDirectory, isDirectory: true)
    }

    /// The Settings default, then Downloads and Desktop when they differ.
    @MainActor
    static func standardFolders(for settings: AppSettings? = nil) -> [URL] {
        let resolved = settings ?? .shared
        let fm = FileManager.default
        let candidates = [defaultFolder(for: resolved)]
            + fm.urls(for: .downloadsDirectory, in: .userDomainMask)
            + fm.urls(for: .desktopDirectory, in: .userDomainMask)
        return candidates.map(\.standardizedFileURL).reduce(into: []) { result, url in
            if !result.contains(url) { result.append(url) }
        }
    }

    /// "Automatic (FolderName)" when a concrete category/default preview is known.
    static func automaticTitle(for previewFolder: URL?) -> String {
        guard let previewFolder else { return "Automatic" }
        let name = FileManager.default.displayName(atPath: previewFolder.path)
        return "Automatic (\(name))"
    }

    private var showAutomatic: Bool {
        allowsAutomatic && manager.sortingIsActive
    }

    var body: some View {
        Picker("Save to", selection: Binding<SaveFolderChoice>(
            get: {
                if let folder { return .folder(folder.standardizedFileURL) }
                return showAutomatic ? .automatic : .folder(Self.defaultFolder(for: settings).standardizedFileURL)
            },
            set: { choice in
                switch choice {
                case .automatic:
                    folder = nil
                case .folder(let url):
                    folder = url
                case .other:
                    if let onChooseOther {
                        onChooseOther()
                    } else {
                        // After the menu's fade-out: opened any sooner, the panel
                        // freezes the half-faded menu on screen behind it.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(100))
                            chooseOther()
                        }
                    }
                }
            }
        )) {
            if showAutomatic {
                Label(automaticTitle, systemImage: "folder.badge.gearshape")
                    .tag(SaveFolderChoice.automatic)
                Divider()
            }
            ForEach(Self.standardFolders(for: settings), id: \.self) { row($0) }
            let recents = recentChoices
            if !recents.isEmpty {
                Divider()
                Text("Recent").disabled(true)
                ForEach(recents, id: \.self) { row($0) }
            }
            Divider()
            Text("Other\u{2026}").tag(SaveFolderChoice.other)
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private func row(_ url: URL) -> some View {
        Label(FileManager.default.displayName(atPath: url.path), systemImage: "folder")
            .tag(SaveFolderChoice.folder(url))
    }

    private var recentChoices: [URL] {
        let standard = Self.standardFolders(for: settings)
        var folders = recent
        if let folder, !folders.contains(folder.standardizedFileURL) {
            folders.insert(folder.standardizedFileURL, at: 0)
        }
        return folders.filter { !standard.contains($0) }
    }

    private func chooseOther() {
        if activatesAppForOpenPanel {
            NSApp.activate()
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
        }
    }
}
