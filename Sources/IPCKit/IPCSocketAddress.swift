import Darwin

/// Builds the `sockaddr_un` both IPCServer (bind/listen) and
/// NativeMessagingHost (connect) need — kept in one place so the low-level
/// struct marshalling can't drift between the two sides the way duplicated
/// copies of this exact code risk doing.
public enum IPCSocketAddress {
    /// Returns a populated `sockaddr_un` for `path` plus the address length
    /// to pass to `bind`/`connect`, computed the conventional way (header
    /// size + `strlen(path)`, no trailing NUL — `String.utf8CString`
    /// includes one, so it's subtracted back out here).
    public static func make(path: String) -> (addr: sockaddr_un, length: socklen_t) {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytesWithNul = Array(path.utf8CString)
        precondition(pathBytesWithNul.count <= 104, "IPC socket path exceeds sockaddr_un.sun_path capacity: \(path)")
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { cPtr in
                for (index, byte) in pathBytesWithNul.enumerated() { cPtr[index] = byte }
            }
        }

        let pathLength = pathBytesWithNul.count - 1 // exclude the NUL — the conventional SUN_LEN
        let length = UInt8(MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + pathLength)
        addr.sun_len = length
        return (addr, socklen_t(length))
    }
}
