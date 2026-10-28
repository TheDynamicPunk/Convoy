import XCTest
@testable import DownloadEngine

/// The two fields download categories add to a task: whether the person chose
/// the folder, and which category (if any) routed the file.
///
/// The test that matters most is the first one. `PersistedDownloadTask`
/// treats a snapshot it cannot decode as "the whole list is unreadable" and
/// sets downloads.json aside, so a field added carelessly as required would
/// make every existing user's download list disappear on the first launch of
/// the update. Both fields must therefore stay optional on disk.
@MainActor
final class CategoryPersistenceTests: XCTestCase {

    private let sampleID = "6F0C1B6E-1C2D-4C9A-9B1E-2D3F4A5B6C7D"
    private let categoryID = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"

    /// A snapshot exactly as a build from before categories wrote it: none of
    /// the new keys, and only the fields that have always been required.
    private var legacySnapshot: Data {
        Data("""
        [{
          "id": "\(sampleID)",
          "url": "https://example.invalid/song.mp3",
          "destinationPath": "/Users/test/Downloads/song.mp3",
          "originalName": "song.mp3",
          "priorityRaw": 1,
          "segmentCount": 8,
          "kind": "active",
          "totalBytes": 1000,
          "downloadedBytes": 250
        }]
        """.utf8)
    }

    private func makeTask(
        folderIsExplicit: Bool? = nil,
        categoryID: UUID? = nil
    ) -> DownloadTask {
        if let folderIsExplicit {
            return DownloadTask(
                url: URL(string: "https://example.invalid/song.mp3")!,
                destinationURL: URL(fileURLWithPath: "/tmp/song.mp3"),
                originalName: "song.mp3",
                folderIsExplicit: folderIsExplicit,
                categoryID: categoryID
            )
        }
        return DownloadTask(
            url: URL(string: "https://example.invalid/song.mp3")!,
            destinationURL: URL(fileURLWithPath: "/tmp/song.mp3"),
            originalName: "song.mp3"
        )
    }

    // MARK: - downloads.json

    func testSnapshotWrittenBeforeCategoriesStillDecodes() throws {
        let decoded = try JSONDecoder().decode([PersistedDownloadTask].self, from: legacySnapshot)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].destinationPath, "/Users/test/Downloads/song.mp3")
        XCTAssertNil(decoded[0].folderIsExplicit)
        XCTAssertNil(decoded[0].categoryID)
    }

    func testCategoryFieldsSurviveEncodeAndDecode() throws {
        let json = Data("""
        [{
          "id": "\(sampleID)",
          "url": "https://example.invalid/song.mp3",
          "destinationPath": "/Users/test/Music/song.mp3",
          "originalName": "song.mp3",
          "priorityRaw": 1,
          "segmentCount": 8,
          "kind": "completed",
          "folderIsExplicit": true,
          "categoryID": "\(categoryID)",
          "totalBytes": 1000,
          "downloadedBytes": 1000
        }]
        """.utf8)

        let first = try JSONDecoder().decode([PersistedDownloadTask].self, from: json)
        XCTAssertEqual(first[0].folderIsExplicit, true)
        XCTAssertEqual(first[0].categoryID, UUID(uuidString: categoryID))

        // Through the encoder and back, as a save followed by a relaunch does.
        let again = try JSONDecoder().decode(
            [PersistedDownloadTask].self,
            from: try JSONEncoder().encode(first)
        )
        XCTAssertEqual(again[0].folderIsExplicit, true)
        XCTAssertEqual(again[0].categoryID, UUID(uuidString: categoryID))
        XCTAssertEqual(again[0].destinationPath, "/Users/test/Music/song.mp3")
    }

    // MARK: - The task

    func testNewTaskHasNoExplicitFolderAndNoCategory() {
        let task = makeTask()
        XCTAssertFalse(task.folderIsExplicit)
        XCTAssertNil(task.categoryID)
    }

    func testTaskKeepsWhatItWasCreatedWith() {
        let id = UUID()
        let task = makeTask(folderIsExplicit: true, categoryID: id)
        XCTAssertTrue(task.folderIsExplicit)
        XCTAssertEqual(task.categoryID, id)
    }

    func testFolderChoiceIsIndependentOfFilenameProvenance() {
        // The New Download window passes a folder the person picked together
        // with a name that came from the URL. Those are two separate facts.
        let task = DownloadTask(
            url: URL(string: "https://example.invalid/song.mp3")!,
            destinationURL: URL(fileURLWithPath: "/tmp/song.mp3"),
            originalName: "song.mp3",
            filenameSource: .originalURL,
            folderIsExplicit: true
        )
        XCTAssertEqual(task.filenameSource, .originalURL)
        XCTAssertFalse(task.userProvidedDestinationName)
        XCTAssertTrue(task.folderIsExplicit)
    }

    // MARK: - The duplicate sheet

    func testDuplicateConflictCarriesTheFolderChoice() {
        let existing = makeTask()
        func conflict(explicit: Bool?) -> DuplicateDownloadConflict {
            let url = URL(string: "https://example.invalid/song.mp3")!
            let dest = URL(fileURLWithPath: "/tmp/song.mp3")
            if let explicit {
                return DuplicateDownloadConflict(
                    incomingURL: url, incomingHeaders: [:], incomingReferrer: nil,
                    incomingDestination: dest, incomingFilenameSource: .originalURL,
                    existingTask: existing, suggestedAlternativeName: "song (1).mp3",
                    resolvingTaskID: nil, incomingFolderIsExplicit: explicit
                )
            }
            return DuplicateDownloadConflict(
                incomingURL: url, incomingHeaders: [:], incomingReferrer: nil,
                incomingDestination: dest, incomingFilenameSource: .originalURL,
                existingTask: existing, suggestedAlternativeName: "song (1).mp3",
                resolvingTaskID: nil
            )
        }

        // "Save as separate" and "Restart" rebuild the download from this, so
        // a picked folder must not decay into a suggestion on the way through.
        XCTAssertTrue(conflict(explicit: true).incomingFolderIsExplicit)
        XCTAssertFalse(conflict(explicit: false).incomingFolderIsExplicit)
        XCTAssertFalse(conflict(explicit: nil).incomingFolderIsExplicit)
    }
}
