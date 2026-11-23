import AppKit
import SwiftUI
import DownloadEngine

/// How each download status looks wherever a status is drawn: its label, its
/// colour, and whether it gets a progress bar. The downloads list and the
/// duplicate sheet both read this, so a status looks the same in either.
extension DownloadStatus {
    var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .starting, .refreshingLink: return "Starting"
        case .validating: return "Checking"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .urlExpired: return "Expired"
        case .destinationMissing: return "Folder Missing"
        case .awaitingDuplicateResolution: return "Needs Your Input"
        }
    }

    var color: Color {
        switch self {
        case .waiting, .urlExpired, .destinationMissing, .awaitingDuplicateResolution: return .orange
        case .starting, .refreshingLink, .downloading: return .blue
        case .validating: return Self.checkingColor
        case .paused: return .yellow
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .gray
        }
    }

    var showsProgressBar: Bool {
        switch self {
        case .waiting, .starting, .validating, .refreshingLink, .downloading,
             .paused, .urlExpired, .destinationMissing:
            return true
        case .completed, .failed, .cancelled, .awaitingDuplicateResolution:
            return false
        }
    }

    /// Checking is the step before downloading, so it is a lighter shade of the
    /// Downloading blue: the same hue, only softer. Blended toward white, not
    /// gray, so it stays a clean light blue instead of going dull. Opaque, so
    /// the row badge doesn't show through it.
    private static let checkingColor = Color(nsColor: NSColor(name: nil) { _ in
        let blue = NSColor.systemBlue.usingColorSpace(.sRGB) ?? .systemBlue
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        return blue.blended(withFraction: 0.30, of: white) ?? blue
    })
}
