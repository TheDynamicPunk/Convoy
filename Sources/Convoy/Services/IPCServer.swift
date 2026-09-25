import Foundation
import DownloadEngine
import IPCKit
import os

final class IPCServer {
    static let shared = IPCServer()

    private static let logger = Logger(subsystem: "Convoy", category: "IPCServer")

    private var serverSocket: Int32?
    private var isRunning = false

    func start() {
        let socketPath = IPCSocketPath.current

        // Unlike the old AF_INET scheme (every instance bound its own
        // ephemeral port, so two instances never collided), AF_UNIX binds
        // to one well-known filesystem path shared by every instance. With
        // no single-instance enforcement elsewhere in the app, blindly
        // unlinking that path could steal it out from under a still-running
        // listener (e.g. a rapid double-launch, or a slow-quitting previous
        // instance) — that instance would keep running but become silently
        // unreachable. Probing first turns that into a loud, visible
        // refusal instead of a silent split.
        if anotherInstanceIsListening(at: socketPath) {
            Self.logger.error("another Convoy instance already owns the IPC socket — not starting a second IPC server in this process")
            return
        }

        isRunning = true

        // A stale socket file from a previous run that didn't exit cleanly
        // (crash, force-quit) makes bind() fail with "address already in
        // use" — AF_UNIX binds to a filesystem path, unlike AF_INET's
        // ephemeral port, so the path itself has to be clear first. The
        // check above already established nothing is actually listening
        // there.
        unlink(socketPath)

        let socket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return }
        self.serverSocket = socket

        let (addr, addrLen) = IPCSocketAddress.make(path: socketPath)
        var mutableAddr = addr

        // Bracket the socket file's creation with a restrictive umask so it
        // is never briefly world-accessible between bind() and the chmod
        // below — closes that window at the root instead of narrowing it
        // after the fact.
        let previousUmask = umask(0o077)
        let bindResult = withUnsafePointer(to: &mutableAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, addrLen)
            }
        }
        umask(previousUmask)
        guard bindResult >= 0 else { close(socket); return }

        // Belt-and-suspenders alongside the umask above (which should
        // already make this a no-op) and the per-connection peer
        // code-signing check below (which restricts by specific program,
        // not just by user account) — logged, not silently ignored, since
        // this is the last layer that can still narrow exposure if the
        // umask bracketing above didn't take effect for some reason.
        if chmod(socketPath, 0o600) != 0 {
            Self.logger.error("failed to set IPC socket permissions (errno \(errno)) — continuing, but the socket may be more accessible than intended")
        }

        listen(socket, 5)

        DispatchQueue.global().async { [weak self] in
            self?.acceptLoop(socket)
        }
    }

    func stop() {
        isRunning = false
        if let socket = serverSocket {
            close(socket)
            serverSocket = nil
        }
        unlink(IPCSocketPath.current)
    }

    /// True if a live process is already accepting connections at `path` —
    /// distinguishes "a previous run's orphaned socket file" (safe to
    /// unlink and rebind) from "another instance is genuinely running right
    /// now" (unlinking would steal its address instead).
    private func anotherInstanceIsListening(at path: String) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }

        let (addr, addrLen) = IPCSocketAddress.make(path: path)
        var mutableAddr = addr
        let result = withUnsafePointer(to: &mutableAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, addrLen)
            }
        }
        return result >= 0
    }

    private func acceptLoop(_ socket: Int32) {
        while isRunning {
            let client = accept(socket, nil, nil)
            if client >= 0 {
                DispatchQueue.global().async { [weak self] in
                    self?.handleClient(client)
                }
            }
        }
    }

    private func handleClient(_ client: Int32) {
        defer { close(client) }

        // The connecting side should be the NativeMessagingHost binary
        // shipped next to this app's own executable, and nothing else.
        let verification = IPCPeerVerification.verifyPeer(onSocket: client, expecting: .nativeMessagingHost)
        guard verification.isTrusted else {
            IPCDiagnostics.recordFailure("app refused a connection: \(verification.rejectionReason ?? "unknown reason")")
            return
        }
        IPCDiagnostics.recordSuccess()

        var data = Data()
        while true {
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = recv(client, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }

        guard !data.isEmpty else { return }

        let response = processRequest(data)
        _ = response.withUnsafeBytes { ptr in
            send(client, ptr.baseAddress, response.count, 0)
        }
    }
    
    private func processRequest(_ data: Data) -> Data {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = dict["type"] as? String else {
            return encode(["success": false, "error": "Invalid request"])
        }
        
        switch type {
        case "download":
            return DispatchQueue.main.sync {
                let urls = (dict["urls"] as? [String] ?? []).compactMap { URL(string: $0) }
                guard !urls.isEmpty else {
                    return self.encode(["success": false, "error": "No valid URLs"])
                }
                
                let rawHeaders = dict["headers"] as? [String: String] ?? [:]
                
                // rawHeaders may include a Content-Length the extension sent
                // purely for Re-link size-matching (matchFreshURL below) —
                // never meant as a real outgoing request header.
                // Content-Length describes a REQUEST BODY's size and is
                // meaningless on a bodyless GET; sending a bogus one can get
                // the connection killed outright by the server or the network
                // stack ("the network connection was lost" is exactly this).
                // Keep the original dict for the match check, but strip it
                // from whatever actually becomes outgoing headers on the
                // real download request.
                var mergedHeaders = rawHeaders
                mergedHeaders.removeValue(forKey: "Content-Length")
                mergedHeaders.removeValue(forKey: "content-length")
                
                // The extension sends cookies both as a {name: value} dict and
                // as a pre-built "Cookie" header. If we have a Cookie header
                // already, use it directly; otherwise build one from the dict.
                if mergedHeaders["Cookie"] == nil,
                   let cookies = dict["cookies"] as? [String: String],
                   !cookies.isEmpty {
                    mergedHeaders["Cookie"] = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
                }
                
                // The extension also sends the page URL as "referrer" — this
                // was being silently dropped here (only headers/cookies were
                // ever read), which is exactly why CDNs like googlevideo.com
                // 403 the request: no Referer header, looks like a bot/hotlink
                // rather than a real page-initiated download.
                if mergedHeaders["Referer"] == nil, let referrer = dict["referrer"] as? String, !referrer.isEmpty {
                    mergedHeaders["Referer"] = referrer
                }
                
                // Plenty of CDNs (Google's included) also reject requests with
                // no/unusual User-Agent outright, independent of Referer.
                if mergedHeaders["User-Agent"] == nil {
                    mergedHeaders["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
                }
                
                // Every request through this endpoint is a genuine capture
                // (extension button, context menu, or an intercepted native
                // browser download) — gate window-focusing here the same way
                // ConvoyApp's onOpenURL gates it for the YouTube
                // hand-off path, so the setting covers every capture route,
                // not just YouTube's. showMainWindow() rather than a bare
                // NSApp.activate: it's the shared, already-correct
                // implementation (deminiaturizes, creates the window fresh
                // if none exists) — see MainWindowTracker.
                if AppSettings.shared.bringWindowToFrontOnCapture {
                    MainWindowTracker.shared.showMainWindow()
                }

                let referrerURL = (dict["referrer"] as? String).flatMap { URL(string: $0) }
                
                // 180 to match FilenameResolver.sanitize's own limit rather
                // than cutting shorter than the rest of the app: this is a
                // real title the extension resolved from the page, and post
                // titles on the sites this matters for run well past 120
                // characters. 180 plus an extension and a " (1)" dedup suffix
                // still sits comfortably inside the 255-byte filesystem limit.
                let providedFilename = (dict["filename"] as? String).flatMap { Self.sanitizeFilenameComponent($0, maxLength: 180) }
                let streamType = dict["streamType"] as? String
                let representationId = dict["representationId"] as? String
                let bandwidth = dict["bandwidth"] as? Int
                // HLS split-audio candidates for this variant's AUDIO group
                // (see parseHlsManifest in background.js) — each entry a
                // {url, lang, isDefault} dict. nil/empty for a combined
                // stream and for DASH, which resolves its own audio
                // app-side via AdaptationSets instead.
                let audioTracks: [HLSAudioCandidate]? = (dict["audioTracks"] as? [[String: Any]])?.compactMap { entry in
                    guard let urlString = entry["url"] as? String, let url = URL(string: urlString) else { return nil }
                    return HLSAudioCandidate(
                        url: url,
                        lang: entry["lang"] as? String,
                        isDefault: entry["isDefault"] as? Bool ?? false
                    )
                }

                let destURL: URL?
                if let fname = providedFilename, !fname.isEmpty {
                    destURL = URL(fileURLWithPath: AppSettings.shared.downloadDirectory, isDirectory: true).appendingPathComponent(fname)
                } else {
                    destURL = nil
                }
                
                for url in urls {
                    let throttledURL = Self.bypassGooglevideoThrottle(url)

                    // HLS/DASH manifest URLs → native stream download pipeline.
                    // Regular URLs → existing byte-range / Re-link path.
                    if let sType = streamType, sType == "hls" || sType == "dash" {
                        let filename = providedFilename ?? Self.streamFilename(from: throttledURL, referrerURL: referrerURL)
                        let streamDest = URL(
                            fileURLWithPath: AppSettings.shared.downloadDirectory,
                            isDirectory: true
                        ).appendingPathComponent(filename)
                        FlyingCaptureAnimation.shared.play(filename: filename)
                        Task {
                            _ = try? await DownloadManager.shared.addStreamDownload(
                                url: throttledURL,
                                streamType: sType,
                                destination: destURL ?? streamDest,
                                // .mediaTitle only when the extension actually
                                // resolved one from the page. streamFilename's
                                // own fallback is derived from the manifest or
                                // the referrer host, and a Content-Disposition
                                // header is a better name than either.
                                filenameSource: providedFilename == nil ? .pageMetadata : .mediaTitle,
                                customHeaders: mergedHeaders,
                                referrerURL: referrerURL,
                                representationId: representationId,
                                bandwidth: bandwidth,
                                hlsAudioTracks: audioTracks
                            )
                        }
                    } else {
                        let filename = providedFilename ?? (throttledURL.lastPathComponent.isEmpty ? (throttledURL.host ?? throttledURL.absoluteString) : throttledURL.lastPathComponent)
                        FlyingCaptureAnimation.shared.play(filename: filename)
                        Task {
                            let relinked = await DownloadManager.shared.matchFreshURL(throttledURL, headers: rawHeaders)
                            if !relinked {
                                let explicitSegments = dict["segmentCount"] as? Int
                                _ = try? await DownloadManager.shared.addDownload(
                                    url: throttledURL, destination: destURL,
                                    // destURL is non-nil exactly when the
                                    // extension supplied a filename, and the
                                    // latch is the only path that does — every
                                    // other caller (context menu, intercepted
                                    // browser download) sends none and keeps
                                    // the ordinary Content-Disposition
                                    // behaviour. If another path ever starts
                                    // sending one, it must be a page-resolved
                                    // media title or this is the wrong source.
                                    filenameSource: destURL == nil ? nil : .mediaTitle,
                                    segmentCount: explicitSegments, customHeaders: mergedHeaders, referrerURL: referrerURL
                                )
                            }
                        }
                    }
                }
                return self.encode(["success": true, "count": urls.count])

            }
            
        case "getDownloads":
            return DispatchQueue.main.sync {
                let manager = DownloadManager.shared
                let allTasks = manager.tasks + manager.completedTasks
                let downloads = allTasks.map { task in
                    [
                        "id": task.id.uuidString, "filename": task.filename,
                        "url": task.url.absoluteString, "progress": task.progress,
                        "status": "\(task.status)", "speed": task.speed,
                        "totalBytes": task.totalBytes, "downloadedBytes": task.downloadedBytes
                    ] as [String: Any]
                }
                return self.encode(["success": true, "downloads": downloads])
            }
            
        case "pause", "resume", "cancel":
            guard let idString = dict["id"] as? String,
                  let uuid = UUID(uuidString: idString) else {
                return encode(["success": false, "error": "No download ID"])
            }
            return DispatchQueue.main.sync {
                let manager = DownloadManager.shared
                guard let task = manager.tasks.first(where: { $0.id == uuid }) else {
                    return self.encode(["success": false, "error": "Download not found"])
                }
                Task {
                    switch type {
                    case "pause": await manager.pauseDownload(task)
                    case "resume": try? await manager.resumeDownload(task)
                    case "cancel": await manager.cancelDownload(task)
                    default: break
                    }
                }
                return self.encode(["success": true])
            }

        default:
            return encode(["success": false, "error": "Unknown type: \(type)"])
        }
    }
    
    private func encode(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }
    
    /// Appends `ratebypass=yes` to `*.googlevideo.com` URLs that lack it.
    /// YouTube's CDN throttles any URL without this parameter to ~500 kbps,
    /// shared across all parallel connections — so segmentCount > 1 doesn't
    /// help without it. Idempotent: already-set values are left untouched.
    private static func bypassGooglevideoThrottle(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(), host.hasSuffix("googlevideo.com") else {
            return url
        }
        let urlString = url.absoluteString
        if urlString.contains("ratebypass=yes") {
            return url
        }
        let separator = urlString.contains("?") ? "&" : "?"
        return URL(string: urlString + separator + "ratebypass=yes") ?? url
    }


    /// Generates a readable output filename for a stream download.
    ///
    /// Priority:
    /// 1. Meaningful stem from the manifest URL (e.g. `hls/movie-1080p.m3u8` → `movie-1080p`)
    /// 2. Parent directory of the manifest (e.g. `.../movie-1080p/index.m3u8` → `movie-1080p`)
    /// 3. Cleaned hostname of the referrer page (e.g. `video-dev.github.io`)
    /// 4. Cleaned hostname of the manifest URL itself
    ///
    /// The file extension (.ts or .mp4) is NOT added here — StreamDownloader
    /// appends it after inspecting the actual segment format.
    private static func streamFilename(from manifestURL: URL, referrerURL: URL?) -> String {
        // Words that indicate a generic manifest name with no useful signal.
        let genericNames: Set<String> = [
            "index", "master", "playlist", "manifest", "stream", "media",
            "video", "audio", "hls", "dash", "live", "vod", "chunklist",
            "main", "output", "encode", "player", "content", "segment",
            "default", "quality", "level", "track", "source", ""
        ]
        // Web page extensions to exclude when scanning referrer path components.
        let webExts: Set<String> = ["html", "htm", "php", "aspx", "jsp", "tsx", "vue", "py", "rb"]

        // Step 1: manifest filename stem (strip .m3u8 / .mpd)
        let stem = manifestURL.deletingPathExtension().lastPathComponent
        if !genericNames.contains(stem.lowercased()), stem.count > 2, let sanitized = sanitizeFilenameComponent(stem, maxLength: 60) {
            return sanitized
        }

        // Step 2: manifest parent directory name
        let parent = manifestURL.deletingLastPathComponent().lastPathComponent
        if parent != "/" && !parent.isEmpty && !genericNames.contains(parent.lowercased()), parent.count > 2, let sanitized = sanitizeFilenameComponent(parent, maxLength: 60) {
            return sanitized
        }

        // Step 3: referrer page — hostname + first non-generic, non-web-page path component
        if let ref = referrerURL, let refHost = ref.host {
            let cleanHost = refHost
                .replacingOccurrences(of: "www.", with: "")
                .components(separatedBy: ".").prefix(2).joined(separator: ".")  // e.g. video-dev.github (drop .io)

            // Walk path components from end toward root, skip web-page filenames
            let usefulPart = ref.pathComponents.reversed().first { comp in
                guard comp != "/", !comp.isEmpty else { return false }
                let ext = (comp as NSString).pathExtension.lowercased()
                let name = (comp as NSString).deletingPathExtension.lowercased()
                return !webExts.contains(ext) && !genericNames.contains(name) && comp.count > 1
            } ?? ""

            let base = usefulPart.isEmpty ? cleanHost : "\(cleanHost)-\(usefulPart)"
            if let sanitized = sanitizeFilenameComponent(base, maxLength: 60) { return sanitized }
        }

        // Step 4: just the manifest host
        let fallbackHost = (manifestURL.host ?? "stream")
            .replacingOccurrences(of: "www.", with: "")
        return sanitizeFilenameComponent(fallbackHost, maxLength: 60) ?? "stream-download"
    }

    /// Strips characters macOS disallows in filenames, collapses internal
    /// whitespace, trims to `maxLength`, and returns `nil` (not an empty
    /// string) when nothing usable survives — so a caller with its own
    /// fallback chain (see `streamFilename` above) can actually fall
    /// through to the next step, rather than silently landing on some
    /// baked-in default that isn't right for every call site.
    ///
    /// Applied to EVERY filename that reaches the filesystem from the
    /// extension, not just `streamFilename`'s narrower internal fallback
    /// chain this originally served: a page title (video-latch.js's
    /// `pageTitleForFilename`) is free-form text that can contain "/" or
    /// other path-breaking characters, and `appendingPathComponent` doesn't
    /// fail loudly on those — it silently creates unintended
    /// subdirectories. Sanitizing centrally, before providedFilename is
    /// ever used, is what actually prevents that.
    private static func sanitizeFilenameComponent(_ s: String, maxLength: Int) -> String? {
        let illegal = CharacterSet(charactersIn: ":/\\?*<>|\"")
        let collapsedWhitespace = s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let safe = collapsedWhitespace.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .init(charactersIn: "-. "))
        guard !safe.isEmpty else { return nil }
        return safe.count > maxLength ? String(safe.prefix(maxLength)) : safe
    }
}
