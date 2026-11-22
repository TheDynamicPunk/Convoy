import Foundation

/// A client for rqbit's HTTP API, speaking the `TorrentEngine` interface.
///
/// This is the half of the adapter that is only HTTP: it knows the routes,
/// the credentials and how rqbit's answers map onto the engine's types, and
/// nothing about processes. `RqbitEngine` adds starting, restarting and
/// stopping the helper around it. The split is so everything here can be
/// tested without one.
///
/// Every shape and behaviour below was observed on a real rqbit 9.1.0 (plan,
/// 14.2 and the response capture), including the two that are easy to get
/// wrong: an add of a torrent it already has succeeds and reports the *old*
/// folder, and errors carry `{error_kind, human_readable, status}`.
struct RqbitClient: TorrentEngine {

    /// The user name half of the helper's Basic credentials.
    static let user = "convoy"

    let baseURL: URL
    private let authorization: String
    private let session: URLSession

    init(baseURL: URL, secret: String, configuration: URLSessionConfiguration = .cookieless) {
        self.baseURL = baseURL
        self.authorization = "Basic " + Data("\(Self.user):\(secret)".utf8).base64EncodedString()
        self.session = URLSession(configuration: configuration)
    }

    /// Cancels what is still in flight and releases the connections. Called
    /// when the helper this client talks to is retired: its requests have
    /// nowhere to go, and its connection pool is of no further use.
    func invalidate() {
        session.invalidateAndCancel()
    }

    // MARK: - TorrentEngine

    /// Whether the helper is up and accepts our credentials.
    func ping() async throws {
        _ = try await send(try request("GET", "/"))
    }

    func probe(magnet: String) async throws -> TorrentFile {
        let expected: MagnetURI
        do {
            expected = try MagnetURI(magnet)
        } catch {
            throw TorrentEngineError.rejected("The magnet link could not be read: \(error)")
        }
        // Upper bound for peer discovery; cancelling the caller ends the wait sooner.
        let data = try await send(try request("POST", "/torrents/resolve_magnet", body: Data(magnet.utf8), timeout: 120))
        let file: TorrentFile
        do {
            file = try TorrentFile(data)
        } catch {
            // Metadata comes from strangers in the swarm; a torrent that fails
            // the parser's checks is refused, not passed on.
            throw TorrentEngineError.rejected("The torrent's details could not be used: \(error)")
        }
        guard file.infoHash == expected.infoHash else {
            throw TorrentEngineError.unexpectedResponse(
                "the engine returned metadata for \(file.infoHash.hex) instead of \(expected.infoHash.hex)")
        }
        return file
    }

    func add(_ source: TorrentSource, into folder: URL, files: Set<Int>?) async throws -> TorrentDetails {
        if let files, files.isEmpty { throw TorrentEngineError.rejected("No files were selected.") }

        var query = [("output_folder", folder.path)]
        if let files { query.append(("only_files", Self.indexList(files))) }

        let body: Data
        let timeout: TimeInterval
        switch source {
        case .torrentFile(let data):
            body = data
            timeout = 15
        case .magnet(let text):
            // May wait for the swarm to supply the metadata first.
            body = Data(text.utf8)
            timeout = 120
        }

        let data = try await send(try request("POST", "/torrents", query: query, body: body, timeout: timeout))
        let added = try decode(Wire.Added.self, from: data)
        let details = try Self.details(from: added.details, outputFolder: added.outputFolder)

        // rqbit reports success for a torrent it already manages and answers
        // with the folder it already uses, whatever this request asked for.
        guard Self.samePath(details.outputFolder, folder) else {
            throw TorrentEngineError.alreadyAdded(existingFolder: details.outputFolder)
        }
        return details
    }

    func details(of torrent: TorrentInfoHash) async throws -> TorrentDetails {
        let data = try await send(try request("GET", "/torrents/\(torrent.hex)"))
        let wire = try decode(Wire.Details.self, from: data)
        return try Self.details(from: wire, outputFolder: wire.outputFolder)
    }

    func setSelectedFiles(_ files: Set<Int>, of torrent: TorrentInfoHash) async throws {
        if files.isEmpty { throw TorrentEngineError.rejected("No files were selected.") }
        let body = try JSONEncoder().encode(["only_files": files.sorted()])
        _ = try await send(try request("POST", "/torrents/\(torrent.hex)/update_only_files",
                                       body: body, contentType: "application/json"))
    }

    func snapshot(of torrent: TorrentInfoHash) async throws -> TorrentSnapshot {
        let data = try await send(try request("GET", "/torrents/\(torrent.hex)/stats/v1"))
        return Self.snapshot(from: try decode(Wire.Stats.self, from: data))
    }

    func pause(_ torrent: TorrentInfoHash) async throws {
        _ = try await send(try request("POST", "/torrents/\(torrent.hex)/pause", body: Data()))
    }

    func resume(_ torrent: TorrentInfoHash) async throws {
        _ = try await send(try request("POST", "/torrents/\(torrent.hex)/start", body: Data()))
    }

    func remove(_ torrent: TorrentInfoHash, deleteData: Bool) async throws {
        // "forget" keeps the files, "delete" removes them.
        let action = deleteData ? "delete" : "forget"
        _ = try await send(try request("POST", "/torrents/\(torrent.hex)/\(action)", body: Data()))
    }

    func pieceBitfield(of torrent: TorrentInfoHash) async -> Data? {
        guard let req = try? request("GET", "/torrents/\(torrent.hex)/haves", accept: "application/octet-stream") else {
            return nil
        }
        return try? await send(req)
    }

    // MARK: - Requests

    private func request(
        _ method: String,
        _ path: String,
        query: [(String, String)] = [],
        body: Data? = nil,
        contentType: String? = nil,
        accept: String? = nil,
        timeout: TimeInterval = 15
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw TorrentEngineError.unexpectedResponse("could not build a request URL from \(baseURL.absoluteString)")
        }
        components.path = path
        if !query.isEmpty {
            let encoded = query.map { "\($0.0)=\(Self.encode($0.1))" }
            components.percentEncodedQuery = encoded.joined(separator: "&")
        }
        guard let url = components.url else {
            throw TorrentEngineError.unexpectedResponse("could not build a request URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.translate(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TorrentEngineError.unexpectedResponse("not an HTTP answer")
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.failure(status: http.statusCode, body: data)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw TorrentEngineError.unexpectedResponse("could not read the engine's answer (\(error.localizedDescription))")
        }
    }

    // MARK: - Failures

    private static func translate(_ error: URLError) -> Error {
        switch error.code {
        case .cancelled:
            return CancellationError()
        case .timedOut:
            return TorrentEngineError.timedOut
        case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed:
            return TorrentEngineError.helperUnavailable
        default:
            return TorrentEngineError.unexpectedResponse(error.localizedDescription)
        }
    }

    private static func failure(status: Int, body: Data) -> TorrentEngineError {
        struct Body: Decodable {
            let errorKind: String?
            let humanReadable: String?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let parsed = try? decoder.decode(Body.self, from: body)
        // rqbit answers some errors with JSON and some (a body it could not
        // read, for one) with plain text. Either way its own words are the
        // reason, capped so an error page cannot become a wall of text.
        let plain = parsed == nil
            ? String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let reason = parsed?.humanReadable
            ?? plain.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
            ?? "HTTP \(status)"

        switch status {
        case 404 where parsed?.errorKind == "torrent_not_found":
            return .notFound
        case 500 where reason.contains("no such torrent"):
            // Forgetting or deleting a torrent rqbit does not have is the one
            // "not found" it reports as a bare internal error (observed on
            // 9.1.0, for both calls). Its message is the only signal, so only
            // that exact phrase is read this way; any other 500 stays unexpected.
            return .notFound
        case 500 where reason.contains("only_files contains invalid value"):
            // Choosing a file the torrent does not have is a refusal of the
            // request, which rqbit reports as a 500 on this one route.
            return .rejected(reason)
        case 400, 422:
            return .rejected(reason)
        case 401, 403:
            return .unexpectedResponse("the engine did not accept our credentials")
        default:
            return .unexpectedResponse("HTTP \(status): \(reason)")
        }
    }

    // MARK: - Encoding and comparing

    /// Unreserved characters and "/" pass through; everything else, including
    /// `+`, `&`, `#`, spaces and non-ASCII, is percent-encoded. A folder name
    /// may contain any of those and a query string gives several of them a
    /// meaning of their own.
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value
    }

    private static func indexList(_ files: Set<Int>) -> String {
        files.sorted().map(String.init).joined(separator: ",")
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    // MARK: - Wire shapes

    /// Only the fields used. Anything else rqbit sends is ignored, so a later
    /// version adding fields does not break the reading.
    private enum Wire {
        struct Added: Decodable {
            let details: Details
            let outputFolder: String
        }

        struct Details: Decodable {
            let infoHash: String
            let name: String?
            let outputFolder: String
            let files: [File]?
        }

        struct File: Decodable {
            let components: [String]
            let length: Int64
            let included: Bool
        }

        struct Stats: Decodable {
            let state: String
            let error: String?
            let progressBytes: Int64
            let uploadedBytes: Int64
            let totalBytes: Int64
            let finished: Bool
            let fileProgress: [Int64]
            let live: Live?
        }

        struct Live: Decodable {
            let snapshot: Snapshot
            let downloadSpeed: Speed
            let uploadSpeed: Speed
        }

        struct Snapshot: Decodable {
            let peerStats: PeerStats
        }

        struct PeerStats: Decodable {
            let live: Int
            let liveSeeders: Int
            let seen: Int
        }

        struct Speed: Decodable {
            /// Despite the name, mebibytes per second: rqbit prints the same
            /// number as "2.50 MiB/s" beside it.
            let mbps: Double
        }
    }

    private static let bytesPerMebibyte = 1_048_576.0

    private static func details(from wire: Wire.Details, outputFolder: String) throws -> TorrentDetails {
        guard let hash = TorrentInfoHash(hex: wire.infoHash) else {
            throw TorrentEngineError.unexpectedResponse("the engine reported an info hash that is not one")
        }
        return TorrentDetails(
            infoHash: hash,
            name: wire.name ?? hash.hex,
            outputFolder: URL(fileURLWithPath: outputFolder, isDirectory: true),
            files: (wire.files ?? []).map {
                TorrentDetails.File(path: $0.components, length: $0.length, isIncluded: $0.included)
            }
        )
    }

    private static func snapshot(from wire: Wire.Stats) -> TorrentSnapshot {
        let state: TorrentSnapshot.State
        switch wire.state {
        case "initializing": state = .initializing
        case "paused": state = .paused
        case "live": state = wire.finished ? .seeding : .downloading
        case "error": state = .error(wire.error ?? "The engine reported an error without saying what.")
        // A state this version has never seen is reported, not guessed at.
        default: state = .error("The engine reported a state this version does not know: \(wire.state)")
        }
        return TorrentSnapshot(
            state: state,
            downloadedBytes: wire.progressBytes,
            totalBytes: wire.totalBytes,
            uploadedBytes: wire.uploadedBytes,
            downloadBytesPerSecond: (wire.live?.downloadSpeed.mbps ?? 0) * bytesPerMebibyte,
            uploadBytesPerSecond: (wire.live?.uploadSpeed.mbps ?? 0) * bytesPerMebibyte,
            connectedPeers: wire.live?.snapshot.peerStats.live ?? 0,
            connectedSeeds: wire.live?.snapshot.peerStats.liveSeeders ?? 0,
            seenPeers: wire.live?.snapshot.peerStats.seen ?? 0,
            fileProgress: wire.fileProgress
        )
    }
}
