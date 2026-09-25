import Foundation
import Security
import Darwin
import MachO
import os

/// Verifies that whoever is on the other end of a connected AF_UNIX socket
/// is the *specific counterpart binary shipped alongside this one*, not
/// merely "some process running as this user," which is all a Unix-socket
/// file permission check alone can guarantee.
///
/// Deliberately socket-based rather than Mach-service/NSXPCConnection-based:
/// NativeMessagingHost is launched directly by the browser with no launchd
/// relationship to the already-running app, which is exactly the case
/// `NSXPCListener(machServiceName:)` is NOT designed for (it expects a
/// launchd-registered service — a LaunchAgent or an embedded .xpc bundle
/// reached from the same process tree). The audit-token + code-signing
/// check below is the same underlying mechanism
/// `NSXPCConnection.setCodeSigningRequirement` uses internally, applied
/// directly to a plain socket peer instead, without taking on a LaunchAgent
/// to install and maintain.
///
/// Used symmetrically: IPCServer verifies the connecting NativeMessagingHost
/// before acting on its request, and NativeMessagingHost verifies the
/// listening app before handing it cookies/URLs — closing both "something
/// else pretends to be the extension" and "something else squats the
/// socket path before the real app starts."
///
/// ## Why sibling pinning rather than a Team ID requirement
///
/// This previously asked "is the peer signed by the same Developer ID team
/// as me?", which required a paid Apple Developer Program membership to
/// mean anything at all: an ad-hoc signature carries no team identifier, so
/// the check found no team of its own to compare against, logged a warning,
/// and fell through to **accepting every peer unconditionally**. Since this
/// app is distributed un-notarized and ad-hoc signed, that relaxed path was
/// not a development-only fallback — it was the only path that ever ran, in
/// development and in release alike. A security component that reads as
/// implemented but never engages is worse than an absent one, because it
/// stops anyone from noticing the gap.
///
/// The requirement is now derived from the counterpart binary sitting next
/// to this one on disk: `Contents/MacOS/` in an assembled `.app`, or
/// `.build/release/` in a plain `swift build` layout — the same-directory
/// rule holds for both. We read that file's designated requirement and
/// demand the connected peer satisfy it.
///
/// This is *narrower* than the Team ID check it replaces. A team
/// requirement accepts any binary that team ever signed; this accepts one
/// specific file. It also needs no certificate, so it actually engages on
/// an ad-hoc build — and it upgrades on its own if this app is ever signed
/// with a Developer ID, because the designated requirement of a
/// Developer-ID-signed binary is a certificate-chain requirement rather
/// than a cdhash, with no code change here.
///
/// ### What this does not defend against
///
/// An attacker who can write inside the app bundle can replace the
/// counterpart binary and be trusted by it. macOS 14's App Management
/// protection raises that bar — another app cannot modify this bundle
/// without explicit user consent — but this is genuinely weaker than a
/// notarized, tamper-evident bundle would be. Documented here rather than
/// implied away.
///
/// ### Mixed architectures are handled, but not by anything here
///
/// Worth recording, because the opposite is easy to assume: for a universal
/// binary, `codesign` emits a designated requirement that is a disjunction
/// over every slice's cdhash —
/// `cdhash H"<arm64>" or cdhash H"<x86_64>"` — so a peer running either
/// slice satisfies it. That covers the case this would otherwise get wrong:
/// an Intel browser under Rosetta exec'ing the host while the app runs
/// natively on Apple Silicon. Nothing in this file has to know about
/// architectures for that to work, and nothing here should start to.
public enum IPCPeerVerification {

    private static let logger = Logger(subsystem: "Convoy", category: "IPCPeerVerification")

    /// Which of this app's two binaries the caller expects to find on the
    /// other end of the socket.
    public enum Counterpart: Sendable {
        /// The main Convoy app — what NativeMessagingHost connects to.
        case app
        /// The browser-launched native messaging host — what the app accepts from.
        case nativeMessagingHost

        /// File name as it appears next to the caller's own executable.
        ///
        /// Kept in step with the executable product names in Package.swift
        /// and the two `cp` lines in build.sh that place both binaries in
        /// `Contents/MacOS/`. Renaming the app means changing these.
        var executableName: String {
            switch self {
            case .app: return "Convoy"
            case .nativeMessagingHost: return "NativeMessagingHost"
            }
        }
    }

    /// The result of a verification attempt. Deliberately carries a
    /// human-readable reason rather than being a bare `Bool`: the caller on
    /// the host side has no usable channel to report failure through —
    /// Chrome renders any native-host problem as "Native host has exited"
    /// with no detail — so the reason has to be persisted somewhere a
    /// person can actually read it. See `IPCDiagnostics`.
    public enum Outcome: Sendable {
        case trusted
        case rejected(String)

        public var isTrusted: Bool {
            if case .trusted = self { return true }
            return false
        }

        public var rejectionReason: String? {
            if case .rejected(let reason) = self { return reason }
            return nil
        }
    }

    /// Returns whether `socketFD`'s peer is the expected counterpart binary
    /// and should be trusted enough to exchange a request/response with.
    ///
    /// Fails closed: any unexpected error (bad fd, unsupported sockopt,
    /// missing counterpart, Security framework failure) is a rejection,
    /// never a silent pass.
    public static func verifyPeer(onSocket socketFD: Int32, expecting counterpart: Counterpart) -> Outcome {
        guard let counterpartURL = counterpartURL(for: counterpart) else {
            return reject("could not resolve this process's own executable path, so there is nothing to compare the peer against")
        }

        guard FileManager.default.fileExists(atPath: counterpartURL.path) else {
            return reject("expected counterpart binary is missing at \(counterpartURL.path) — this build is incomplete")
        }

        let requirement: SecRequirement
        switch designatedRequirement(ofBinaryAt: counterpartURL) {
        case .success(let req):
            requirement = req
        case .failure(let reason):
            return reject(reason)
        }

        guard let auditToken = peerAuditToken(socketFD) else {
            return reject("could not read the peer's audit token off the socket")
        }

        var guestCode: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        let copyStatus = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &guestCode)
        guard copyStatus == errSecSuccess, let peerCode = guestCode else {
            return reject("could not obtain a code object for the peer process (SecCodeCopyGuestWithAttributes status \(copyStatus))")
        }

        let validity = SecCodeCheckValidity(peerCode, SecCSFlags(), requirement)
        guard validity == errSecSuccess else {
            // Naming both paths turns the most likely cause into something
            // a person can act on: running the app from one location while
            // the browser's native-messaging manifest points at a
            // different install of it.
            return reject("""
            peer at \(path(of: peerCode)) does not match the counterpart binary at \(counterpartURL.path) \
            (SecCodeCheckValidity status \(validity)). The running app and the browser's native messaging \
            host are most likely from two different installs.
            """)
        }

        return .trusted
    }

    // MARK: - Requirement

    private enum RequirementResult {
        case success(SecRequirement)
        case failure(String)
    }

    /// The designated requirement of the binary at `url`, read live from
    /// disk on every verification rather than computed once and cached.
    ///
    /// Live is the correct choice here even though it costs a signature
    /// parse per connection: an in-place update (Sparkle replaces the whole
    /// bundle) changes both binaries at once, and a cached requirement from
    /// before the swap would reject the new, legitimate counterpart.
    /// Verifications happen once per user-initiated request, so the cost is
    /// irrelevant.
    private static func designatedRequirement(ofBinaryAt url: URL) -> RequirementResult {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return .failure("could not read a code signature from the counterpart binary at \(url.path) (status \(createStatus))")
        }

        var requirement: SecRequirement?
        let requirementStatus = SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &requirement)
        guard requirementStatus == errSecSuccess, let req = requirement else {
            // errSecCSUnsigned lands here. That is a real signal, not an
            // edge case: on Apple Silicon every binary must carry at least
            // an ad-hoc signature, so an unsigned counterpart means the
            // build script failed to sign it.
            return .failure("counterpart binary at \(url.path) has no designated requirement — it is probably unsigned (status \(requirementStatus))")
        }
        return .success(req)
    }

    // MARK: - Paths

    /// The expected on-disk location of `counterpart`: the same directory
    /// this process's own executable lives in.
    ///
    /// Holds for both layouts this app ships in — `Contents/MacOS/` inside
    /// an assembled `.app`, and `.build/release/` for a bare `swift build`
    /// — because build.sh copies both binaries into the same directory in
    /// each case.
    private static func counterpartURL(for counterpart: Counterpart) -> URL? {
        guard let ownExecutable = ownExecutableURL() else { return nil }
        return ownExecutable
            .deletingLastPathComponent()
            .appendingPathComponent(counterpart.executableName)
    }

    /// This process's own executable, resolved through symlinks.
    ///
    /// Public because NativeMessagingHost needs the same "where am I really"
    /// answer for a different reason -- locating its own bundle's Info.plist
    /// to report the app version -- and duplicating the dyld dance in two
    /// places is how the two answers drift apart.
    ///
    /// Uses `_NSGetExecutablePath` rather than `Bundle.main.executableURL`
    /// because the two callers have different bundle shapes — one is a real
    /// `.app`, the other a bare command-line binary the browser exec'd —
    /// and `Bundle.main`'s behaviour differs between them. The dyld call is
    /// identical for both. `realpath` matters because the returned path can
    /// contain `..` or traverse a symlink, and this value is about to be
    /// used to locate a security-relevant file.
    public static func ownExecutableURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }

        guard let resolved = realpath(buffer, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// Best-effort path of a peer, for diagnostics only — never for a
    /// trust decision. A path is not an identity; the signature check above
    /// is what decides.
    private static func path(of code: SecCode) -> String {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let sc = staticCode else { return "<unknown path>" }

        var url: CFURL?
        guard SecCodeCopyPath(sc, SecCSFlags(), &url) == errSecSuccess,
              let peerURL = url as URL? else { return "<unknown path>" }

        return peerURL.path
    }

    // MARK: - Socket peer identity

    /// Reads the connected peer's audit token directly off the socket via
    /// LOCAL_PEERTOKEN — the kernel-issued identity of that exact process
    /// instance. Deliberately not LOCAL_PEERPID: a PID can be recycled
    /// between accept() and the check (the peer process exits, a new
    /// unrelated process reuses the same PID), which would let a
    /// since-exited legitimate process vouch for an attacker's process. The
    /// audit token has no such reuse window.
    private static func peerAuditToken(_ fd: Int32) -> Data? {
        let size = MemoryLayout<audit_token_t>.size
        var buffer = [UInt8](repeating: 0, count: size)
        var len = socklen_t(size)
        let result = buffer.withUnsafeMutableBytes { rawBuf -> Int32 in
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, rawBuf.baseAddress, &len)
        }
        guard result == 0, len == socklen_t(size) else { return nil }
        return Data(buffer)
    }

    // MARK: - Rejection

    private static func reject(_ reason: String) -> Outcome {
        let collapsed = reason
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        logger.error("IPC peer rejected: \(collapsed, privacy: .public)")
        return .rejected(collapsed)
    }
}
