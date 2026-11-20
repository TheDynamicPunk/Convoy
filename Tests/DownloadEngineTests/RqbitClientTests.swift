import XCTest
@testable import DownloadEngine

/// Tests for the HTTP half of the rqbit adapter: what it sends, and how it
/// reads what comes back.
///
/// The JSON bodies below are shaped by responses captured from a real rqbit
/// 9.1.0 (plan, 14.2 and the Nov 20 capture). Where a value had to be changed
/// to exercise a case (peers, speeds, a finished torrent), only the value
/// changed, not the shape; those are marked.
final class RqbitClientTests: XCTestCase {

    private let hashA = TorrentFixtures.hashA

    override func setUp() {
        StubHelperProtocol.reset()
    }

    override func tearDown() {
        StubHelperProtocol.reset()
    }

    private func makeClient() -> RqbitClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHelperProtocol.self]
        return RqbitClient(baseURL: URL(string: "http://127.0.0.1:4999")!, secret: "s3cret", configuration: configuration)
    }

    private func respond(status: Int = 200, json: String) {
        StubHelperProtocol.route = { _ in .init(status: status, headers: ["Content-Type": "application/json"], body: Data(json.utf8)) }
    }

    private func info(_ hex: String) -> TorrentInfoHash { TorrentInfoHash(hex: hex)! }

    // MARK: - Captured shapes

    private func addedJSON(hash: String = TorrentFixtures.hashA, folder: String, topFolder: String? = nil) -> String {
        """
        {"id":0,"details":{"id":0,"info_hash":"\(hash)","name":"abc","output_folder":"\(folder)","total_pieces":1,
        "files":[{"name":"abc","components":["abc"],"length":5,"included":true,
        "attributes":{"symlink":false,"hidden":false,"padding":false,"executable":false}}]},
        "output_folder":"\(topFolder ?? folder)","seen_peers":null}
        """
    }

    private let statsLive = """
    {"state":"live","file_progress":[0],"error":null,"progress_bytes":0,"uploaded_bytes":0,"total_bytes":5,"finished":false,
    "live":{"snapshot":{"downloaded_and_checked_bytes":0,"fetched_bytes":0,"uploaded_bytes":0,"downloaded_and_checked_pieces":0,
    "total_piece_download_ms":0,"peer_stats":{"queued":0,"connecting":0,"live":0,"live_tcp":0,"live_utp":0,"live_socks":0,
    "live_seeders":0,"seen":0,"dead":0,"not_needed":0,"steals":0}},"average_piece_download_time":null,
    "download_speed":{"mbps":0.0,"human_readable":"0.00 MiB/s"},"upload_speed":{"mbps":0.0,"human_readable":"0.00 MiB/s"},
    "time_remaining":null}}
    """

    private let statsPaused = """
    {"state":"paused","file_progress":[0],"error":null,"progress_bytes":0,"uploaded_bytes":0,"total_bytes":5,"finished":false,"live":null}
    """

    // MARK: - What is sent

    func testEveryRequestCarriesTheSecretAsBasicAuth() async throws {
        respond(json: "{}")
        try await makeClient().ping()

        let sent = try XCTUnwrap(StubHelperProtocol.received.first)
        XCTAssertEqual(sent.method, "GET")
        XCTAssertEqual(sent.path, "/")
        XCTAssertEqual(sent.headers["Authorization"], "Basic " + Data("convoy:s3cret".utf8).base64EncodedString())
    }

    func testAddingPostsTheTorrentBytesAndNamesTheFolder() async throws {
        respond(json: addedJSON(folder: "/tmp/dl/a"))
        _ = try await makeClient().add(.torrentFile(TorrentFixtures.dataA), into: URL(fileURLWithPath: "/tmp/dl/a"), files: nil)

        let sent = try XCTUnwrap(StubHelperProtocol.received.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/torrents")
        XCTAssertEqual(sent.body, TorrentFixtures.dataA)
        XCTAssertEqual(sent.query("output_folder"), "/tmp/dl/a")
        XCTAssertNil(sent.query("only_files"), "no selection means every file")
    }

    func testAMagnetIsSentAsItsOwnText() async throws {
        let magnet = "magnet:?xt=urn:btih:\(hashA)&dn=Some+Name&tr=udp%3A%2F%2Ft.example%3A80"
        respond(json: addedJSON(folder: "/tmp/dl/a"))
        _ = try await makeClient().add(.magnet(magnet), into: URL(fileURLWithPath: "/tmp/dl/a"), files: nil)

        XCTAssertEqual(StubHelperProtocol.received.first?.body, Data(magnet.utf8))
    }

    func testASelectionIsSentAsSortedIndexes() async throws {
        respond(json: addedJSON(folder: "/tmp/dl/a"))
        _ = try await makeClient().add(.torrentFile(TorrentFixtures.dataA), into: URL(fileURLWithPath: "/tmp/dl/a"), files: [4, 0, 2])

        XCTAssertEqual(StubHelperProtocol.received.first?.query("only_files"), "0,2,4")
    }

    /// `&`, `+`, `#`, spaces and non-ASCII are all legal in a folder name and
    /// all mean something in a query string. The path must arrive intact.
    func testAnAwkwardFolderPathIsEncodedSoItArrivesIntact() async throws {
        let path = "/tmp/A & B + C #1 100% Ünï/sub"
        respond(json: addedJSON(folder: path))
        _ = try await makeClient().add(.torrentFile(TorrentFixtures.dataA), into: URL(fileURLWithPath: path), files: nil)

        let raw = try XCTUnwrap(StubHelperProtocol.received.first?.url.absoluteString)
        XCTAssertFalse(raw.contains(" "))
        XCTAssertFalse(raw.contains("+"), "a bare + would be read as a space by the server")
        XCTAssertEqual(StubHelperProtocol.received.first?.query("output_folder"), path)
    }

    func testAnEmptySelectionIsRefusedWithoutAskingTheEngine() async {
        do {
            _ = try await makeClient().add(.torrentFile(TorrentFixtures.dataA), into: URL(fileURLWithPath: "/tmp/dl/a"), files: [])
            XCTFail("a torrent with no files selected is not a download")
        } catch TorrentEngineError.rejected {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(StubHelperProtocol.received.isEmpty)
    }

    func testTheSelectionCanBeChangedWithAJSONBody() async throws {
        respond(json: "{}")
        try await makeClient().setSelectedFiles([1, 0], of: info(hashA))

        let sent = try XCTUnwrap(StubHelperProtocol.received.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/torrents/\(hashA)/update_only_files")
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: [Int]])
        XCTAssertEqual(body, ["only_files": [0, 1]])
    }

    func testPauseResumeAndTheTwoWaysToRemove() async throws {
        respond(json: "{}")
        let client = makeClient()
        let torrent = info(hashA)

        try await client.pause(torrent)
        try await client.resume(torrent)
        try await client.remove(torrent, deleteData: false)
        try await client.remove(torrent, deleteData: true)

        let sent = StubHelperProtocol.received
        XCTAssertEqual(sent.map(\.method), ["POST", "POST", "POST", "POST"])
        XCTAssertEqual(sent.map(\.path), ["pause", "start", "forget", "delete"].map { "/torrents/\(hashA)/\($0)" })
    }

    func testResolvingAMagnetPostsItAndParsesTheTorrentThatComesBack() async throws {
        StubHelperProtocol.route = { _ in .init(body: Data(TorrentFixtures.torrentA.utf8)) }
        let magnet = "magnet:?xt=urn:btih:\(hashA)"

        let file = try await makeClient().probe(magnet: magnet)

        XCTAssertEqual(file.infoHash.hex, hashA)
        let sent = try XCTUnwrap(StubHelperProtocol.received.first)
        XCTAssertEqual(sent.path, "/torrents/resolve_magnet")
        XCTAssertEqual(sent.body, Data(magnet.utf8))
    }

    func testResolvingAnInvalidMagnetIsRejectedWithoutCallingTheEngine() async {
        do {
            _ = try await makeClient().probe(magnet: "not-a-magnet")
            XCTFail("expected .rejected")
        } catch TorrentEngineError.rejected {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(StubHelperProtocol.received.isEmpty)
    }

    func testResolvingAMagnetRejectsMetadataForADifferentInfoHash() async {
        StubHelperProtocol.route = { _ in .init(body: Data(TorrentFixtures.torrentB.utf8)) }
        do {
            _ = try await makeClient().probe(magnet: "magnet:?xt=urn:btih:\(hashA)")
            XCTFail("expected .unexpectedResponse")
        } catch TorrentEngineError.unexpectedResponse {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testResolvingAMagnetRejectsMalformedMetadataFromTheSwarm() async {
        StubHelperProtocol.route = { _ in .init(body: Data("not bencode".utf8)) }
        do {
            _ = try await makeClient().probe(magnet: "magnet:?xt=urn:btih:\(hashA)")
            XCTFail("expected .rejected")
        } catch TorrentEngineError.rejected {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - What comes back

    func testAddReadsTheTorrentTheEngineReports() async throws {
        respond(json: addedJSON(folder: "/tmp/dl/a"))
        let details = try await makeClient().add(.torrentFile(TorrentFixtures.dataA), into: URL(fileURLWithPath: "/tmp/dl/a"), files: nil)

        XCTAssertEqual(details.infoHash.hex, hashA)
        XCTAssertEqual(details.name, "abc")
        XCTAssertEqual(details.outputFolder.path, "/tmp/dl/a")
        XCTAssertEqual(details.files, [TorrentDetails.File(path: ["abc"], length: 5, isIncluded: true)])
    }

    func testDetailsOfAMultiFileTorrentKeepEachFilesPathAndSelection() async throws {
        respond(json: """
        {"id":1,"info_hash":"\(TorrentFixtures.hashB)","name":"pack","output_folder":"/tmp/dl/b","total_pieces":1,
        "files":[{"name":"a/b.txt","components":["a","b.txt"],"length":3,"included":true,"attributes":{"symlink":false,"hidden":false,"padding":false,"executable":false}},
        {"name":"c.bin","components":["c.bin"],"length":4,"included":false,"attributes":{"symlink":false,"hidden":false,"padding":false,"executable":false}}]}
        """)
        let details = try await makeClient().details(of: info(TorrentFixtures.hashB))

        XCTAssertEqual(details.files, [
            TorrentDetails.File(path: ["a", "b.txt"], length: 3, isIncluded: true),
            TorrentDetails.File(path: ["c.bin"], length: 4, isIncluded: false),
        ])
    }

    func testDetailsWithNullNameFallsBackToInfoHash() async throws {
        respond(json: """
        {"id":1,"info_hash":"\(hashA)","name":null,"output_folder":"/tmp/dl/a","total_pieces":0,"files":null}
        """)
        let details = try await makeClient().details(of: info(hashA))

        XCTAssertEqual(details.name, hashA)
        XCTAssertTrue(details.files.isEmpty)
    }

    /// rqbit answers a repeat add with success and the torrent it already has,
    /// in the folder it already uses, and ignores the folder in the new
    /// request. Taking that at face value would mean files landing somewhere
    /// the caller never asked for.
    func testAnAddThatComesBackInAnotherFolderIsReportedNotAccepted() async throws {
        respond(json: addedJSON(folder: "/tmp/dl/old"))
        do {
            _ = try await makeClient().add(.torrentFile(TorrentFixtures.dataA), into: URL(fileURLWithPath: "/tmp/dl/new"), files: nil)
            XCTFail("expected .alreadyAdded")
        } catch TorrentEngineError.alreadyAdded(let existing) {
            XCTAssertEqual(existing.path, "/tmp/dl/old")
        }
    }

    // MARK: - Reading stats

    func testALiveTorrentWithNoPeers() async throws {
        respond(json: statsLive)
        let snapshot = try await makeClient().snapshot(of: info(hashA))

        XCTAssertEqual(snapshot, TorrentSnapshot(
            state: .downloading, downloadedBytes: 0, totalBytes: 5, uploadedBytes: 0,
            downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
            connectedPeers: 0, connectedSeeds: 0, seenPeers: 0, fileProgress: [0]))
    }

    func testAPausedTorrentHasNoLiveSection() async throws {
        respond(json: statsPaused)
        let snapshot = try await makeClient().snapshot(of: info(hashA))

        XCTAssertEqual(snapshot.state, .paused)
        XCTAssertEqual(snapshot.downloadBytesPerSecond, 0)
        XCTAssertEqual(snapshot.connectedPeers, 0)
    }

    /// Synthetic: the live capture's shape with busy values.
    func testPeersSpeedsAndProgressAreReadFromTheLiveSection() async throws {
        respond(json: """
        {"state":"live","file_progress":[1048576,0],"error":null,"progress_bytes":1048576,"uploaded_bytes":2048,"total_bytes":4194304,"finished":false,
        "live":{"snapshot":{"downloaded_and_checked_bytes":1048576,"fetched_bytes":1048576,"uploaded_bytes":2048,"downloaded_and_checked_pieces":4,
        "total_piece_download_ms":10,"peer_stats":{"queued":1,"connecting":2,"live":7,"live_tcp":7,"live_utp":0,"live_socks":0,
        "live_seeders":2,"seen":30,"dead":3,"not_needed":0,"steals":0}},"average_piece_download_time":null,
        "download_speed":{"mbps":2.5,"human_readable":"2.50 MiB/s"},"upload_speed":{"mbps":0.25,"human_readable":"0.25 MiB/s"},"time_remaining":null}}
        """)
        let snapshot = try await makeClient().snapshot(of: info(hashA))

        XCTAssertEqual(snapshot.state, .downloading)
        XCTAssertEqual(snapshot.downloadedBytes, 1_048_576)
        XCTAssertEqual(snapshot.totalBytes, 4_194_304)
        XCTAssertEqual(snapshot.uploadedBytes, 2048)
        XCTAssertEqual(snapshot.fileProgress, [1_048_576, 0])
        XCTAssertEqual(snapshot.connectedPeers, 7)
        XCTAssertEqual(snapshot.connectedSeeds, 2)
        XCTAssertEqual(snapshot.seenPeers, 30)
        // rqbit's own text says MiB/s ("2.50 MiB/s") beside the number.
        XCTAssertEqual(snapshot.downloadBytesPerSecond, 2.5 * 1_048_576)
        XCTAssertEqual(snapshot.uploadBytesPerSecond, 0.25 * 1_048_576)
    }

    /// Synthetic: a finished torrent that is still being served.
    func testAFinishedLiveTorrentIsSeeding() async throws {
        respond(json: statsLive.replacingOccurrences(of: "\"finished\":false", with: "\"finished\":true")
            .replacingOccurrences(of: "\"progress_bytes\":0", with: "\"progress_bytes\":5"))
        let snapshot = try await makeClient().snapshot(of: info(hashA))

        XCTAssertEqual(snapshot.state, .seeding)
        XCTAssertEqual(snapshot.downloadedBytes, 5)
    }

    /// Synthetic, from the disk-full case in 14.6: the message ends with the
    /// system's own words.
    func testAnErroredTorrentCarriesTheEnginesMessage() async throws {
        respond(json: """
        {"state":"error","file_progress":[0],"error":"error writing: ENOSPC: No space left on device","progress_bytes":0,
        "uploaded_bytes":0,"total_bytes":5,"finished":false,"live":null}
        """)
        let snapshot = try await makeClient().snapshot(of: info(hashA))

        XCTAssertEqual(snapshot.state, .error("error writing: ENOSPC: No space left on device"))
    }

    func testAStateThisVersionDoesNotKnowIsAnErrorNotASilentGuess() async throws {
        respond(json: statsLive.replacingOccurrences(of: "\"state\":\"live\"", with: "\"state\":\"teleporting\""))
        let snapshot = try await makeClient().snapshot(of: info(hashA))

        guard case .error(let message) = snapshot.state else { return XCTFail("expected .error, got \(snapshot.state)") }
        XCTAssertTrue(message.contains("teleporting"))
    }

    func testAnInitialisingTorrent() async throws {
        respond(json: statsPaused.replacingOccurrences(of: "\"state\":\"paused\"", with: "\"state\":\"initializing\""))
        let snapshot = try await makeClient().snapshot(of: info(hashA))

        XCTAssertEqual(snapshot.state, .initializing)
    }

    // MARK: - Failures

    func testAnUnknownTorrentIsNotFound() async {
        respond(status: 404, json: """
        {"error_kind":"torrent_not_found","human_readable":"torrent not found 99","status":404,"status_text":"404 Not Found","id":99}
        """)
        do {
            _ = try await makeClient().snapshot(of: info(hashA))
            XCTFail("expected .notFound")
        } catch {
            XCTAssertEqual(error as? TorrentEngineError, .notFound)
        }
    }

    /// Captured from rqbit 9.1.0: unlike every other call, removing a torrent it
    /// does not have answers with a generic 500, and the message is the only
    /// thing that says so.
    func testRemovingATorrentTheEngineDoesNotHaveIsNotFoundDespiteTheStatus() async {
        for (deleteData, message) in [(false, "error forgetting torrent: no such torrent in db"),
                                      (true, "error deleting torrent with files: no such torrent in db")] {
            respond(status: 500, json: """
            {"error_kind":"internal_error","human_readable":"\(message)","status":500,"status_text":"500 Internal Server Error"}
            """)
            do {
                try await makeClient().remove(info(hashA), deleteData: deleteData)
                XCTFail("expected .notFound")
            } catch {
                XCTAssertEqual(error as? TorrentEngineError, .notFound, "deleteData: \(deleteData)")
            }
        }
    }

    /// Any other 500 is something unexpected, not a missing torrent.
    func testAnyOther500IsStillUnexpected() async {
        respond(status: 500, json: """
        {"error_kind":"internal_error","human_readable":"error forgetting torrent: disk on fire","status":500,"status_text":"500 Internal Server Error"}
        """)
        do {
            try await makeClient().remove(info(hashA), deleteData: false)
            XCTFail("expected an error")
        } catch TorrentEngineError.unexpectedResponse {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// Captured from rqbit 9.1.0: `update_only_files` names a file the torrent
    /// does not have with a 500, which is the engine refusing the request, not
    /// failing.
    func testASelectionNamingAFileThatDoesNotExistIsRejected() async {
        respond(status: 500, json: """
        {"error_kind":"internal_error","human_readable":"error updating only_files: only_files contains invalid value 7","status":500,"status_text":"500 Internal Server Error"}
        """)
        do {
            try await makeClient().setSelectedFiles([0, 7], of: info(hashA))
            XCTFail("expected .rejected")
        } catch TorrentEngineError.rejected(let reason) {
            XCTAssertTrue(reason.contains("invalid value 7"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// Captured from rqbit 9.1.0: a body it cannot read (here a negative index)
    /// gets a 422 whose text is plain, not JSON. Its own words are the reason.
    func testABodyTheEngineCannotReadIsRejectedWithItsOwnWords() async {
        let text = "Failed to deserialize the JSON body into the target type: only_files[0]: invalid value: integer `-1`, expected usize at line 1 column 18"
        StubHelperProtocol.route = { _ in .init(status: 422, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8)) }
        do {
            try await makeClient().setSelectedFiles([-1], of: info(hashA))
            XCTFail("expected .rejected")
        } catch TorrentEngineError.rejected(let reason) {
            XCTAssertEqual(reason, text)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAPlainTextReasonIsKeptButNotWithoutLimit() async {
        StubHelperProtocol.route = { _ in .init(status: 400, body: Data(String(repeating: "x", count: 5000).utf8)) }
        do {
            try await makeClient().pause(info(hashA))
            XCTFail("expected .rejected")
        } catch TorrentEngineError.rejected(let reason) {
            XCTAssertEqual(reason.count, 300, "an engine's error page must not become a wall of text")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testARefusalCarriesTheEnginesReason() async {
        respond(status: 400, json: """
        {"error_kind":"internal_error","human_readable":"error adding torrent: error creating a new file (because allow_overwrite = false) \\"/tmp/x/abc\\": File exists (os error 17)","status":400,"status_text":"400 Bad Request"}
        """)
        do {
            _ = try await makeClient().add(.torrentFile(TorrentFixtures.dataA), into: URL(fileURLWithPath: "/tmp/x"), files: nil)
            XCTFail("expected .rejected")
        } catch TorrentEngineError.rejected(let reason) {
            XCTAssertTrue(reason.contains("File exists"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testWrongCredentialsAndServerErrorsAreUnexpectedNotRejections() async {
        for status in [401, 403, 500] {
            respond(status: status, json: "{}")
            do {
                _ = try await makeClient().snapshot(of: info(hashA))
                XCTFail("HTTP \(status) should fail")
            } catch TorrentEngineError.unexpectedResponse {
                // expected
            } catch {
                XCTFail("HTTP \(status) threw \(error)")
            }
        }
    }

    func testAnAnswerThatIsNotWhatWasExpectedIsReportedAsSuch() async {
        respond(json: "{\"nonsense\":true}")
        do {
            _ = try await makeClient().snapshot(of: info(hashA))
            XCTFail("expected an error")
        } catch TorrentEngineError.unexpectedResponse {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAHelperThatCannotBeReachedIsUnavailableAndATimeoutIsATimeout() async {
        StubHelperProtocol.failure = URLError(.cannotConnectToHost)
        do {
            try await makeClient().ping()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TorrentEngineError, .helperUnavailable)
        }

        StubHelperProtocol.failure = URLError(.timedOut)
        do {
            try await makeClient().ping()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TorrentEngineError, .timedOut)
        }
    }

    /// Cancelling the task that is waiting on a magnet must stop the wait, not
    /// turn into an engine error somebody has to interpret.
    func testCancellingTheCallerIsCancellationNotAnEngineError() async {
        StubHelperProtocol.failure = URLError(.cancelled)
        do {
            try await makeClient().ping()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }
}
