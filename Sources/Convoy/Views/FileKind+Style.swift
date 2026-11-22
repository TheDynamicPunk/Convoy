import SwiftUI
import DownloadEngine

/// How each kind of file looks wherever a file is drawn: the symbol and the
/// colour of its tinted square. The downloads list and the capture dialog both
/// read this, so a file looks the same in either.
extension FileKind {
    var symbol: String {
        switch self {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        case .document: return "doc.text"
        case .book: return "book.closed"
        case .archive: return "archivebox"
        case .program: return "shippingbox"
        case .code: return "curlybraces"
        case .other: return "doc"
        }
    }

    var tint: Color {
        switch self {
        case .video: return .purple
        case .audio: return .pink
        case .image: return .green
        case .document: return .blue
        case .book: return .indigo
        case .archive: return .orange
        case .program: return .teal
        case .code: return .brown
        case .other: return .gray
        }
    }
}

/// Shared visual identity for BitTorrent rows, dialogs and the Settings tab.
/// A plain SF Symbol (connected peers) so it scales, tints and adapts like
/// every other icon in the app. Magnet links and `.torrent` files share it.
enum TorrentStyle {
    static let symbol = "point.3.filled.connected.trianglepath.dotted"
    static let tint: Color = .indigo
}
