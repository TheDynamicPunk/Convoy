import Foundation
import Security

/// The two things any helper Convoy talks to over loopback needs before it
/// starts: a port nobody else holds, and a secret only Convoy and the helper
/// know.
enum LoopbackHelper {

    enum Failure: Error, Equatable {
        case noFreePort
        case noRandomness
    }

    /// A TCP port that nothing held a moment ago, found by asking the system
    /// for one and giving it back.
    ///
    /// There is a window between this returning and the helper binding the
    /// port in which something else could take it. It is short, and a helper
    /// that loses the race exits at once with "address in use", so a caller
    /// that launches helpers should be ready to ask again.
    ///
    /// Checked on all interfaces, so the port is also free on loopback.
    static func freePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.noFreePort }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard bound == 0 else { throw Failure.noFreePort }

        var length = size
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw Failure.noFreePort }
        return UInt16(bigEndian: address.sin_port)
    }

    /// Random bytes from the system's secure generator, as lowercase hex.
    static func randomSecret(byteCount: Int = 24) throws -> String {
        guard byteCount > 0 else { throw Failure.noRandomness }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            throw Failure.noRandomness
        }
        return bytes.hexString
    }
}
