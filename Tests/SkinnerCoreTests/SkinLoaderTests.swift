import Testing
import Foundation
@testable import SkinnerCore

@Suite("SkinLoader")
struct SkinLoaderTests {

    // Path to the pre-extracted Pulsar skin directory (relative to repo root).
    private static let pulsarDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SkinnerCoreTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("skins/Plus! Pulsar")

    // A .wmz file from the collection.
    private static let sampleWMZ = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("skins/windowsmediaplayerskinscollection/activate.wmz")

    // A .wmz with a deliberately corrupted local file header on one entry
    // (anti-extraction trick); `unzip` exits non-zero but extracts the rest.
    private static let bruteforceWMZ = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("skins/windowsmediaplayerskinscollection/bruteforce.wmz")

    // Same trick, but the corrupted entry is the .wms file itself — `unzip`
    // can't extract it at all without the header repair.
    private static let splinterCellWMZ = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("skins/windowsmediaplayerskinscollection/SplinterCellWMPSkin.wmz")

    // MARK: Directory input

    @Test func loadsFromDirectory() throws {
        let bundle = try SkinLoader.load(from: Self.pulsarDir)
        #expect(bundle.wmsFile.pathExtension.lowercased() == "wms")
        #expect(FileManager.default.fileExists(atPath: bundle.wmsFile.path))
    }

    @Test func directoryBundlePreservesPath() throws {
        let bundle = try SkinLoader.load(from: Self.pulsarDir)
        #expect(bundle.directory == Self.pulsarDir)
    }

    @Test func assetURLResolvesRelativeName() throws {
        let bundle = try SkinLoader.load(from: Self.pulsarDir)
        let url = bundle.assetURL(named: "background.png")
        #expect(url.lastPathComponent == "background.png")
        #expect(url.deletingLastPathComponent() == bundle.directory)
    }

    // MARK: .wmz archive input

    @Test func loadsFromWMZ() throws {
        let bundle = try SkinLoader.load(from: Self.sampleWMZ)
        #expect(bundle.wmsFile.pathExtension.lowercased() == "wms")
        #expect(FileManager.default.fileExists(atPath: bundle.wmsFile.path))
        // Clean up temp extraction dir.
        try? FileManager.default.removeItem(at: bundle.directory)
    }

    @Test func wmzExtractsToTemp() throws {
        let bundle = try SkinLoader.load(from: Self.sampleWMZ)
        let inTemp = bundle.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path)
        #expect(inTemp)
        try? FileManager.default.removeItem(at: bundle.directory)
    }

    @Test func loadsWMZWithCorruptedLocalHeaderEntry() throws {
        let bundle = try SkinLoader.load(from: Self.bruteforceWMZ)
        #expect(bundle.wmsFile.pathExtension.lowercased() == "wms")
        #expect(FileManager.default.fileExists(atPath: bundle.wmsFile.path))
        try? FileManager.default.removeItem(at: bundle.directory)
    }

    @Test func loadsWMZWithCorruptedWMSLocalHeader() throws {
        let bundle = try SkinLoader.load(from: Self.splinterCellWMZ)
        #expect(bundle.wmsFile.lastPathComponent.lowercased() == "sc.wms")
        #expect(FileManager.default.fileExists(atPath: bundle.wmsFile.path))
        try? FileManager.default.removeItem(at: bundle.directory)
    }

    // MARK: Error cases

    @Test func throwsForMissingPath() {
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).wmz")
        #expect(throws: SkinLoaderError.self) {
            try SkinLoader.load(from: missing)
        }
    }

    @Test func throwsForDirectoryWithNoWMS() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("skinner-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        #expect(throws: SkinLoaderError.self) {
            try SkinLoader.load(from: empty)
        }
    }
}
