import XCTest
@testable import DownloadEngine

/// What a file is, for its icon. These pin the table so a screen cannot grow
/// its own opinion about what a JSON or a PNG file is.
final class FileKindTests: XCTestCase {

    // MARK: - The reason this exists

    func testJSONAndOtherDeveloperFilesAreCode() {
        for name in ["Tamtaro-All-Templates-for-AIOStreams.json", "config.yaml", "config.yml",
                     "Cargo.toml", "main.swift", "app.py", "index.ts", "styles.scss", "setup.sh",
                     "schema.sql", "Info.plist", "page.html"] {
            XCTAssertEqual(FileKind(filename: name), .code, name)
        }
    }

    func testDotfilesWithARealExtensionStillCount() {
        XCTAssertEqual(FileKind(filename: ".eslintrc.json"), .code)
    }

    // MARK: - Each kind

    func testEachKindClaimsItsOwnFiles() {
        XCTAssertEqual(FileKind(filename: "clip.mp4"), .video)
        XCTAssertEqual(FileKind(filename: "song.flac"), .audio)
        XCTAssertEqual(FileKind(filename: "photo.png"), .image)
        XCTAssertEqual(FileKind(filename: "report.pdf"), .document)
        XCTAssertEqual(FileKind(filename: "novel.epub"), .book)
        XCTAssertEqual(FileKind(filename: "bundle.zip"), .archive)
        XCTAssertEqual(FileKind(filename: "Installer.pkg"), .program)
    }

    func testDiskImagesAreProgramsNotArchives() {
        XCTAssertEqual(FileKind(filename: "App.dmg"), .program)
        XCTAssertEqual(FileKind(filename: "ubuntu.iso"), .program)
    }

    func testTSIsTypeScriptNotVideo() {
        XCTAssertEqual(FileKind(filename: "index.ts"), .code)
    }

    // MARK: - How the name is read

    func testCaseDoesNotMatter() {
        XCTAssertEqual(FileKind(filename: "PHOTO.PNG"), .image)
        XCTAssertEqual(FileKind(filename: "Data.JSON"), .code)
    }

    func testOnlyTheLastExtensionCounts() {
        XCTAssertEqual(FileKind(filename: "backup.tar.gz"), .archive)
        XCTAssertEqual(FileKind(filename: "song.mp3.zzzzqq"), .other)
    }

    func testNoExtensionIsOther() {
        XCTAssertEqual(FileKind(filename: "README"), .other)
        XCTAssertEqual(FileKind(filename: "download"), .other)
        XCTAssertEqual(FileKind(filename: ""), .other)
    }

    func testAFileThatIsOnlyAnExtensionIsOther() {
        XCTAssertEqual(FileKind(filename: ".json"), .other)
    }

    // MARK: - The system's type database

    func testAnExtensionOutsideTheTableAsksTheTypeSystem() {
        // Not in the table, but a movie to the system.
        XCTAssertEqual(FileKind(filename: "clip.wmv"), .video)
    }

    func testAnExtensionNobodyKnowsIsOther() {
        XCTAssertEqual(FileKind(filename: "mystery.zzzzqq"), .other)
    }

    // MARK: - The table itself

    func testNoExtensionBelongsToTwoKinds() {
        var owner: [String: FileKind] = [:]
        for (kind, list) in FileKind.extensions {
            for ext in list {
                if let first = owner[ext] {
                    XCTFail("\"\(ext)\" is claimed by both \(first) and \(kind)")
                }
                owner[ext] = kind
            }
        }
    }

    func testExtensionsAreStoredLowercaseWithoutADot() {
        for (kind, list) in FileKind.extensions {
            for ext in list {
                XCTAssertEqual(ext, ext.lowercased(), "\(kind): \(ext)")
                XCTAssertFalse(ext.hasPrefix("."), "\(kind): \(ext)")
                XCTAssertFalse(ext.contains("."), "\(kind): \(ext)")
            }
        }
    }

    func testEveryKindButOtherListsExtensions() {
        for kind in FileKind.allCases where kind != .other {
            XCTAssertFalse(FileKind.extensions[kind, default: []].isEmpty, "\(kind)")
        }
        XCTAssertNil(FileKind.extensions[.other])
    }
}
