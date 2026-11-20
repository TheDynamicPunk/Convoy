import XCTest
@testable import DownloadEngine

final class LoopbackHelperTests: XCTestCase {

    /// Binds `port` on all interfaces, the way a helper's peer port would be.
    private func bindable(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    func testAFreePortIsNotPrivilegedAndCanBeBoundStraightAway() throws {
        for _ in 0..<20 {
            let port = try LoopbackHelper.freePort()
            XCTAssertGreaterThan(port, 1023)
            XCTAssertTrue(bindable(port), "port \(port) was handed out but could not be bound")
        }
    }

    func testASecretIsLowercaseHexOfTheRequestedLength() throws {
        let secret = try LoopbackHelper.randomSecret(byteCount: 24)
        XCTAssertEqual(secret.count, 48)
        XCTAssertTrue(secret.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(try LoopbackHelper.randomSecret(byteCount: 8).count, 16)
    }

    func testSecretsDoNotRepeat() throws {
        let secrets = try (0..<50).map { _ in try LoopbackHelper.randomSecret() }
        XCTAssertEqual(Set(secrets).count, secrets.count)
    }

    func testNonPositiveSecretByteCountIsRejected() {
        for count in [0, -1, -16] {
            XCTAssertThrowsError(try LoopbackHelper.randomSecret(byteCount: count)) { error in
                XCTAssertEqual(error as? LoopbackHelper.Failure, .noRandomness)
            }
        }
    }
}
