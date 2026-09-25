import Foundation
import AppKit
import IPCKit

/// Talks to the browser extension over Chrome's Native Messaging stdio
/// protocol (4-byte little-endian length prefix + UTF-8 JSON, both ways),
/// and relays download-related requests to the running Convoy app
/// over a local AF_UNIX domain socket, peer-verified via code signature
/// (see IPCServer in the main app target and IPCPeerVerification in IPCKit).
///
/// Deliberately uses plain JSONSerialization dictionaries rather than a
/// Codable enum for the wire format — the previous version required the
/// browser extension to send a specific nested `{ payload: { type, data } }`
/// shape that didn't match what the extension's JS actually sent, so every
/// message silently failed to decode. Matching the simpler, natural JSON
/// shape the extension sends is both correct and far less brittle.
actor NativeMessagingHost {
    private var isRunning = true
    /// The main app's bundle identifier — used to launch it via `open -b`
    /// when a relayed request fails because it isn't running. Matches
    /// CFBundleIdentifier in Resources/Info.plist.
    private let appBundleIdentifier = "io.github.thedynamicpunk.convoy"

    /// The containing app bundle's marketing version, for the extension's
    /// "connected to version X" display.
    ///
    /// Read from the bundle's Info.plist rather than hardcoded: build.sh
    /// injects that value from the git tag, so a literal here would start
    /// drifting the first time a release is cut. Located relative to this
    /// executable because `Bundle.main` is not the app bundle from inside
    /// this process -- the browser exec'd a bare binary, and Bundle.main
    /// resolves to the Contents/MacOS directory it sits in.
    private static let appVersion: String = {
        guard let executable = IPCPeerVerification.ownExecutableURL() else { return "unknown" }
        let infoPlist = executable
            .deletingLastPathComponent()   // Contents/MacOS
            .deletingLastPathComponent()   // Contents
            .appendingPathComponent("Info.plist")
        guard let contents = NSDictionary(contentsOf: infoPlist),
              let version = contents["CFBundleShortVersionString"] as? String else { return "unknown" }
        return version
    }()
    
    func run() async {
        FileHandle.standardError.write("Native messaging host started\n".data(using: .utf8)!)
        while isRunning {
            await readAndProcessMessage()
        }
    }
    
    private func readAndProcessMessage() async {
        let stdin = FileHandle.standardInput
        
        guard let lengthData = try? stdin.read(upToCount: 4), lengthData.count == 4 else {
            isRunning = false
            return
        }
        
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        
        guard length > 0, length < 50_000_000,
              let messageData = try? stdin.read(upToCount: Int(length)),
              messageData.count == Int(length) else {
            isRunning = false
            return
        }
        
        await processMessage(messageData)
    }
    
    private func processMessage(_ data: Data) async {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = dict["type"] as? String else {
            await sendResponse(json: ["success": false, "error": "Invalid message format"])
            return
        }
        
        let payload = dict["payload"] as? [String: Any] ?? [:]
        
        switch type {
        case "ping":
            // appRunning is what the popup's status line shows; the host
            // answering at all only proves the host is installed.
            await sendResponse(json: ["status": "ok", "version": Self.appVersion,
                                      "appRunning": await isIPCServerReachable()])
            
        case "downloadRequest":
            let urls = payload["urls"] as? [String] ?? []
            guard !urls.isEmpty else {
                await sendResponse(json: ["success": false, "error": "No valid URLs"])
                return
            }
            var body: [String: Any] = ["type": "download", "urls": urls]
            if let referrer = payload["referrer"] as? String { body["referrer"] = referrer }
            if let filename = payload["filename"] as? String { body["filename"] = filename }
            if let segmentCount = payload["segmentCount"] as? Int { body["segmentCount"] = segmentCount }
            if let headers = payload["headers"] as? [String: String], !headers.isEmpty {
                body["headers"] = headers
            }
            if let cookies = payload["cookies"] as? [String: String], !cookies.isEmpty {
                body["cookies"] = cookies
            }
            // HLS/DASH stream download routing fields
            if let streamType = payload["streamType"] as? String { body["streamType"] = streamType }
            if let repId = payload["representationId"] as? String { body["representationId"] = repId }
            if let bw = payload["bandwidth"] as? Int { body["bandwidth"] = bw }
            // HLS split-audio candidates from this variant's AUDIO group (see
            // parseHlsManifest in background.js) — each a {url, lang,
            // isDefault} dict, forwarded as-is; IPCServer does the actual
            // decoding and language-preference selection.
            if let audioTracks = payload["audioTracks"] as? [[String: Any]], !audioTracks.isEmpty {
                body["audioTracks"] = audioTracks
            }
            await relayToApp(body)


        case "getDownloads":
            await relayToApp(["type": "getDownloads"], fallback: ["success": true, "downloads": []])
            
        case "pauseDownload", "resumeDownload", "cancelDownload":
            guard let id = (payload["id"] as? String) ?? (dict["id"] as? String) else {
                await sendResponse(json: ["success": false, "error": "No download ID"])
                return
            }
            let mapped = type == "pauseDownload" ? "pause" : type == "resumeDownload" ? "resume" : "cancel"
            await relayToApp(["type": mapped, "id": id])

        case "openYouTubeDownload":
            // Sent by the browser extension when the user clicks download on
            // a YouTube page. Deliberately does NOT go through relayToApp /
            // the IPC socket at all — opens the app via its
            // convoy:// URL scheme with the watch-page URL attached,
            // and the app's own AddDownloadsView (already wired to
            // YouTubeResolver in-process, see NewDownloadView.swift) does
            // the rest: fetch formats, show the quality picker, download,
            // mux. There's no browser-side format list or panel anymore.
            //
            // `open` on a registered custom URL scheme is handled entirely
            // by LaunchServices — it launches the app if it isn't running
            // and activates + delivers the URL if it already is, so unlike
            // launchMainAppAndWait below, there's no need to poll for a live
            // IPC server here.
            guard let urlString = (payload["url"] as? String) ?? (dict["url"] as? String) else {
                await sendResponse(json: ["success": false, "error": "No URL provided"])
                return
            }
            await openAppWithYouTubeURL(urlString)
            
        case "launchApp":
            // Sent automatically whenever a relay failed because the app
            // wasn't running (see relayToApp's fallback below), and from any
            // Open control the user clicks (popup, banner, notification).
            // foreground is set only for the click; the automatic launch
            // stays in the background and leaves focus to the app's own
            // bring-to-front setting.
            await launchMainAppAndWait(foreground: payload["foreground"] as? Bool == true)
            
        default:
            await sendResponse(json: ["success": false, "error": "Unknown type: \(type)"])
        }
    }

    private func relayToApp(_ body: [String: Any], fallback: [String: Any] = ["success": false, "error": "Convoy app not running"]) async {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            await sendResponse(json: ["success": false, "error": "Failed to encode request"])
            return
        }
        guard let responseData = await sendToAppSocket(bodyData) else {
            await sendResponse(json: fallback)
            return
        }
        await sendResponse(data: responseData)
    }
    
    private func sendToAppSocket(_ data: Data) async -> Data? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let socketPath = IPCSocketPath.current
                let sock = socket(AF_UNIX, SOCK_STREAM, 0)
                guard sock >= 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { close(sock) }

                let (addr, addrLen) = IPCSocketAddress.make(path: socketPath)
                var mutableAddr = addr
                let connectResult = withUnsafePointer(to: &mutableAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(sock, $0, addrLen)
                    }
                }
                guard connectResult >= 0 else {
                    // No socket file, or nothing listening — the app isn't
                    // running. Same meaning as the old "port file missing"
                    // case, just detected differently.
                    continuation.resume(returning: nil)
                    return
                }

                // Verify the listening app is really Convoy before
                // handing it cookies/URLs — the symmetric case of
                // IPCServer's own check: without this, something that got
                // to this socket path first (before the real app started)
                // could impersonate the app and harvest whatever this host
                // sends it.
                let verification = IPCPeerVerification.verifyPeer(onSocket: sock, expecting: .app)
                guard verification.isTrusted else {
                    // The browser renders every native-host problem as
                    // "Native host has exited", so the reason has to go
                    // somewhere a person can actually read it.
                    IPCDiagnostics.recordFailure("native messaging host refused the listening app: \(verification.rejectionReason ?? "unknown reason")")
                    continuation.resume(returning: nil)
                    return
                }
                IPCDiagnostics.recordSuccess()

                _ = data.withUnsafeBytes { ptr in
                    Darwin.send(sock, ptr.baseAddress, data.count, 0)
                }

                // Critical: signal we're done writing. IPCServer's read loop
                // (in the main app) blocks on recv() until it sees EOF before
                // it will process anything — without this, both sides sit
                // waiting on each other forever and every request times out.
                shutdown(sock, SHUT_WR)

                var responseData = Data()
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let bytesRead = recv(sock, &buffer, buffer.count, 0)
                    if bytesRead <= 0 { break }
                    responseData.append(contentsOf: buffer[0..<bytesRead])
                }

                continuation.resume(returning: responseData.isEmpty ? nil : responseData)
            }
        }
    }
    
    /// Opens (or foregrounds) Convoy via its convoy:// URL
    /// scheme, with the YouTube watch-page URL attached as a query item. See
    /// the "openYouTubeDownload" case above for why this bypasses the IPC
    /// socket entirely.
    private func openAppWithYouTubeURL(_ urlString: String) async {
        var components = URLComponents()
        components.scheme = "convoy"
        components.host = "add"
        // URLComponents percent-encodes `?`, `&` and `=` inside the value, so a
        // watch URL's own query string survives the round trip intact —
        // verified for ?v=, &t=, &list= and youtu.be/?si= forms.
        components.queryItems = [URLQueryItem(name: "url", value: urlString)]
        guard let launchURL = components.url else {
            await sendResponse(json: ["success": false, "error": "Failed to build launch URL"])
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [launchURL.absoluteString]
        do {
            try process.run()
            await sendResponse(json: ["success": true])
        } catch {
            await sendResponse(json: ["success": false, "error": "Couldn't open Convoy: \(error.localizedDescription)"])
        }
    }

    /// Resolves the installed app bundle associated with this host without
    /// relying on a LaunchServices bundle-ID lookup. In production the host
    /// is embedded at `Convoy.app/Contents/MacOS/NativeMessagingHost`,
    /// so walking up from the host executable finds the exact signed bundle
    /// registered with the browser.
    private var mainAppBundleURL: URL? {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])

        let bundleURL = executableURL
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // Convoy.app

        guard bundleURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: bundleURL.path) else { return nil }
        return bundleURL
    }
    
    /// Launches the main Convoy.app and waits for its IPCServer to
    /// come up before responding — so the extension can reliably retry the
    /// original request right after this succeeds instead of guessing how
    /// long a cold launch takes.
    ///
    /// Launches in the background (`open -g`). Whether the window then comes
    /// forward is the app's own bringWindowToFrontOnCapture setting, applied
    /// when it receives the replayed request.
    private func launchMainAppAndWait(foreground: Bool) async {
        // The user may also have already launched Convoy in the gap
        // between the original failed request and clicking the prompt —
        // process is up but its IPC server has not become reachable yet.
        // Spawning `open` on top of an already-activating app can produce a
        // duplicate window under some LaunchServices races, so detect this
        // case and just poll for a live IPC server instead of relaunching.
        // `runningApplications(withBundleIdentifier:)` queries the running
        // app list by bundle id; a running-but-not-yet-indexed-by-Launch-
        // -Services case can't actually happen (anything running had to be
        // launched *through* LaunchServices, which indexed it on the way).
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier)
        let appAlreadyRunning = runningApps.contains { $0.activationPolicy != .prohibited }
        if appAlreadyRunning {
            if foreground { runningApps.first?.activate() }
            if await waitForLiveIPCServer(timeoutSeconds: 10) {
                await sendResponse(json: ["success": true])
            } else {
                await sendResponse(json: ["success": false, "error": "Convoy is running but its download service didn't become available in time"])
            }
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let bundleURL = mainAppBundleURL, FileManager.default.fileExists(atPath: bundleURL.path) {
            // Launch the exact bundle we're embedded in, by path — no
            // LaunchServices lookup involved, so this can't land on a stale
            // copy elsewhere on disk. -g keeps the browser frontmost.
            process.arguments = foreground ? [bundleURL.path] : ["-g", bundleURL.path]
        } else {
            await sendResponse(json: ["success": false, "error": "Native messaging host is not embedded in Convoy.app"])
            return
        }
        do {
            try process.run()
        } catch {
            await sendResponse(json: ["success": false, "error": "Couldn't launch Convoy: \(error.localizedDescription)"])
            return
        }

        if await waitForLiveIPCServer(timeoutSeconds: 10) {
            await sendResponse(json: ["success": true])
        } else {
            await sendResponse(json: ["success": false, "error": "Timed out waiting for Convoy to start"])
        }
    }

    /// Waits for a usable IPC server rather than merely checking whether the
    /// socket path exists. A force-quit can leave a stale socket file
    /// behind (see IPCServer.start()'s liveness check before it unlinks
    /// one), which would otherwise make the host report launch success
    /// without ever actually reaching a running app.
    private func waitForLiveIPCServer(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await isIPCServerReachable() {
                return true
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    /// Uses the ordinary read-only `getDownloads` request as a health check.
    /// A stale socket file can remain at IPCSocketPath.current after the app
    /// exits (bind() unlinks and recreates it on next launch, but a killed
    /// process never gets that far), so connect() succeeding isn't proof
    /// anything is listening — only a running, peer-verified IPCServer can
    /// actually accept and answer this request.
    private func isIPCServerReachable() async -> Bool {
        guard let request = try? JSONSerialization.data(withJSONObject: ["type": "getDownloads"]) else {
            return false
        }
        return await sendToAppSocket(request) != nil
    }
    
    private func sendResponse(json: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        await sendResponse(data: data)
    }
    
    private func sendResponse(data: Data) async {
        var length = UInt32(data.count).littleEndian
        let lengthData = Data(bytes: &length, count: 4)
        
        let stdout = FileHandle.standardOutput
        try? stdout.write(contentsOf: lengthData)
        try? stdout.write(contentsOf: data)
    }
}

let host = NativeMessagingHost()
await host.run()
