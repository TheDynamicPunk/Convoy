import Foundation
import SwiftUI

@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    /// Every stored setting's name. The properties below read theirs from
    /// here, so restoring defaults can't miss one added later.
    private enum Key: String, CaseIterable {
        case downloadDirectory
        case maxConcurrentDownloads
        case defaultSegmentCount
        case speedLimit
        case autoStartDownloads
        case bringWindowToFrontOnCapture
        case showNotifications
        case playCompletionSound
        case temporaryFilesNoticeThresholdGB
        case theme
        case language
        case preferredAudioLanguage
        case youtubeUseBrowserCookies
        case youtubeCookieBrowser
        case keepHelpersUpToDate
        case downloadCategoriesEnabled
        case downloadCategories
        case hideDockIcon
    }
    
    @AppStorage(Key.downloadDirectory.rawValue) public var downloadDirectory: String = ""
    @AppStorage(Key.maxConcurrentDownloads.rawValue) public var maxConcurrentDownloads: Int = 3
    @AppStorage(Key.defaultSegmentCount.rawValue) public var defaultSegmentCount: Int = 8
    @AppStorage(Key.speedLimit.rawValue) public var speedLimit: Int = 0
    @AppStorage(Key.autoStartDownloads.rawValue) public var autoStartDownloads: Bool = true
    /// Whenever a download is captured from the browser (extension button,
    /// context menu, or intercepted native download) or handed off via the
    /// convoy:// URL scheme, bring Convoy's window to the
    /// front so the capture is visible immediately instead of silently
    /// landing in a background window. On by default — that's the behavior
    /// the app already had for YouTube captures specifically, before this
    /// setting existed to also cover it and extend it to every capture path.
    /// Turning it off keeps captures silent (just the flying-file animation
    /// and the new row appearing) for anyone who finds window-stealing
    /// disruptive, e.g. while working in another app.
    @AppStorage(Key.bringWindowToFrontOnCapture.rawValue) public var bringWindowToFrontOnCapture: Bool = true
    @AppStorage(Key.showNotifications.rawValue) public var showNotifications: Bool = true
    @AppStorage(Key.playCompletionSound.rawValue) public var playCompletionSound: Bool = true
    /// When on, Convoy lives only in the menu bar — no Dock icon and not shown in the ⌘+Tab app switcher.
    @AppStorage(Key.hideDockIcon.rawValue) public var hideDockIcon: Bool = false
    /// How much has to pile up before the main window mentions it.
    @AppStorage(Key.temporaryFilesNoticeThresholdGB.rawValue) public var temporaryFilesNoticeThresholdGB: Double =
        TemporaryStorageNotice.defaultThresholdGB
    @AppStorage(Key.theme.rawValue) public var theme: AppTheme = .system
    @AppStorage(Key.language.rawValue) public var language: String = "en"
    /// BCP-47 preference used only when a DASH manifest offers more than one
    /// audio track. An empty value leaves the manifest's own default intact.
    @AppStorage(Key.preferredAudioLanguage.rawValue) public var preferredAudioLanguage: String = ""

    /// Opt-in: pass `--cookies-from-browser` to yt-dlp so it downloads using
    /// your logged-in YouTube session.
    ///
    /// Off by default deliberately. It materially improves what YouTube will
    /// serve — a signed-out session is increasingly refused outright, returning
    /// either no usable formats or a URL authorized for only a fraction of the
    /// stream — but it also means reading the browser's cookie store, which
    /// macOS may prompt for Keychain access to do. That's the user's call to
    /// make explicitly, not something to switch on for them.
    @AppStorage(Key.youtubeUseBrowserCookies.rawValue) public var youtubeUseBrowserCookies: Bool = false
    @AppStorage(Key.youtubeCookieBrowser.rawValue) public var youtubeCookieBrowser: String = "safari"

    /// Whether an app update that names newer helpers may fetch them by
    /// itself.
    ///
    /// On by default, because yt-dlp breaking when YouTube changes is the
    /// single most common way a downloader stops working, and a helper the
    /// user never updates is one that eventually fails. Only ever acts for
    /// someone who already installed helpers -- it is maintenance of a choice
    /// already made, not a new one -- and `HelperAutoUpdate` additionally
    /// skips metered and Low Data Mode connections, since yt-dlp alone is
    /// over 50 MB.
    @AppStorage(Key.keepHelpersUpToDate.rawValue) public var keepHelpersUpToDate: Bool = true

    /// Whether finished downloads are filed into folders by type or site. Off
    /// by default: turning it on changes where every future download lands,
    /// so that has to be the person's decision.
    @AppStorage(Key.downloadCategoriesEnabled.rawValue) public var downloadCategoriesEnabled: Bool = false
    /// The categories, as JSON. @AppStorage holds only simple values, so the
    /// list is encoded into one string; use `downloadCategories` instead of
    /// reading this.
    @AppStorage(Key.downloadCategories.rawValue) private var downloadCategoriesJSON: String = ""

    /// The person's categories in priority order (first match wins).
    ///
    /// Before anything has been saved this is the original set, so a fresh
    /// install shows real categories (with routing still switched off) and
    /// "Reset to Defaults" has something to return to. Once the person has
    /// edited the list, it is exactly what they left, even if that is empty.
    /// See `CategoryStorage` for the three cases.
    public var downloadCategories: [DownloadCategory] {
        get {
            CategoryStorage.load(json: downloadCategoriesJSON, downloadsFolder: downloadDirectory)
        }
        set {
            guard let json = CategoryStorage.encode(newValue) else { return }
            objectWillChange.send()
            downloadCategoriesJSON = json
        }
    }

    /// Puts the original categories back, replacing whatever is there now.
    /// Callers must confirm with the person first: this discards any category
    /// they added or changed. It deliberately leaves the on/off switch alone,
    /// since resetting the list is not a decision about whether to sort
    /// downloads at all.
    public func resetCategoriesToDefaults() {
        downloadCategories = DownloadCategory.suggestedCategories(in: downloadDirectory)
    }

    /// Browsers yt-dlp can read cookies from, limited to those that ship on or
    /// are common on macOS. Values are exactly the keywords yt-dlp's
    /// `--cookies-from-browser` accepts.
    public static let supportedCookieBrowsers = ["safari", "chrome", "brave", "edge", "firefox", "vivaldi", "opera", "chromium"]
    
    public enum AppTheme: String, CaseIterable, Identifiable {
        case light = "Light"
        case dark = "Dark"
        case system = "System"
        
        public var id: String { rawValue }
        public var colorScheme: ColorScheme? {
            switch self {
            case .light: return .light
            case .dark: return .dark
            case .system: return nil
            }
        }
    }
    
    private init() {
        fillDerivedDefaults()
    }

    /// Puts every setting back to its default. Downloads, helpers and window
    /// state aren't settings and are left alone.
    public func restoreDefaults() {
        objectWillChange.send()
        for key in Key.allCases {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
        fillDerivedDefaults()
    }

    /// Defaults that depend on the Mac rather than being constants.
    private func fillDerivedDefaults() {
        if downloadDirectory.isEmpty {
            downloadDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? ""
        }
    }
}
