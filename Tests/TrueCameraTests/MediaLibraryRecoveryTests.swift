import XCTest
import CoreGraphics
import ImageIO
@testable import TrueCamera

final class MediaLibraryRecoveryTests: XCTestCase {
    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrueCamera-RecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    /// An encoded, readable image rather than an arbitrary file with a photo suffix.
    private func photo(_ name: String, in directory: URL) throws -> URL {
        let pixels = Data([UInt8](repeating: 128, count: 4 * 4 * 3))
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 24,
            bytesPerRow: 12, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return url
    }

    @MainActor func testCorruptManifestRecoversOriginalAndPreservesDamagedIndex() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try photo("original.jpg", in: folder)
        let originalBytes = try Data(contentsOf: original)
        let manifest = folder.appendingPathComponent("library.json")
        let damagedIndex = Data("{\"unfinished\": [".utf8)
        try damagedIndex.write(to: manifest)

        let library = MediaLibrary(directory: folder)
        XCTAssertEqual(library.items.count, 1)
        let recovered = try XCTUnwrap(library.items.first)
        XCTAssertEqual(recovered.filename, original.lastPathComponent)
        XCTAssertFalse(recovered.isVideo)
        XCTAssertNil(recovered.liveFilename, "Recovery must not invent a Live Photo pairing.")
        XCTAssertNil(recovered.rawFilename)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertNotNil(library.message)

        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("library-corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), damagedIndex)
        XCTAssertEqual(try JSONDecoder().decode([MediaItem].self, from: Data(contentsOf: manifest)), [recovered])

        let reopened = MediaLibrary(directory: folder)
        XCTAssertEqual(reopened.items, [recovered], "Reopening must retain the recovered identity without duplicating it.")
        XCTAssertNil(reopened.message)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    }

    @MainActor func testUnreadableIndexStillAllowsOriginalRecoveryWithoutOverwritingIndex() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try photo("original.jpg", in: folder)
        let originalBytes = try Data(contentsOf: original)
        let manifest = folder.appendingPathComponent("library.json", isDirectory: true)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)

        let library = MediaLibrary(directory: folder)
        XCTAssertEqual(library.items.map(\.filename), [original.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertNotNil(library.message)
        XCTAssertTrue(try manifest.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("library-corrupt-") }
        XCTAssertTrue(backups.isEmpty, "A read failure is not proof that an index is corrupt.")
    }

    @MainActor func testOrphanRecoveryKeepsKnownCompanionRolesAndPersistsRecoveredIdentity() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let still = try photo("paired.jpg", in: folder)
        let orphan = try photo("orphan.jpg", in: folder)
        let originalBytes = try Data(contentsOf: orphan)
        let raw = folder.appendingPathComponent("master.dng")
        let movie = folder.appendingPathComponent("motion.mov")
        try Data("untouched RAW resource".utf8).write(to: raw)
        try Data("untouched paired movie resource".utf8).write(to: movie)
        let known = MediaItem(created: Date(timeIntervalSince1970: 1_700_000_000),
            filename: still.lastPathComponent, liveFilename: movie.lastPathComponent,
            rawFilename: raw.lastPathComponent, isVideo: false, summary: "Existing Live and RAW",
            savedToPhotos: true, pairID: UUID())
        try JSONEncoder().encode([known]).write(to: folder.appendingPathComponent("library.json"))

        let library = MediaLibrary(directory: folder)
        XCTAssertEqual(library.items.count, 2, "Known RAW and Live resources must not become duplicate captures.")
        XCTAssertEqual(library.items.first(where: { $0.id == known.id }), known)
        let recovered = try XCTUnwrap(library.items.first(where: { $0.filename == orphan.lastPathComponent }))
        XCTAssertEqual(try Data(contentsOf: orphan), originalBytes)
        XCTAssertNil(library.message)
        let reopened = MediaLibrary(directory: folder)
        XCTAssertEqual(reopened.items, library.items)
        XCTAssertEqual(reopened.items.first(where: { $0.filename == orphan.lastPathComponent })?.id, recovered.id)
        XCTAssertEqual(try Data(contentsOf: raw), Data("untouched RAW resource".utf8))
        XCTAssertEqual(try Data(contentsOf: movie), Data("untouched paired movie resource".utf8))
    }
}
