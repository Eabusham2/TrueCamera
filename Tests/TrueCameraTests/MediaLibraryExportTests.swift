import XCTest
import Photos
@testable import TrueCamera

final class MediaLibraryExportTests: XCTestCase {
    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrueCamera-ExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    private func file(_ name: String, in directory: URL) throws -> URL {
        let result = directory.appendingPathComponent(name)
        try Data("original resource: \(name)".utf8).write(to: result, options: .atomic)
        return result
    }

    func testRAWMasterUsesDNGAsPrimaryAndKeepsProcessedCompanion() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = MediaItem(filename: "companion.heic", rawFilename: "master.dng", isVideo: false, summary: "RAW master")
        let resources = PhotoExportResource.resources(for: item, in: folder)
        XCTAssertEqual(resources.map(\.type), [.photo, .alternatePhoto])
        XCTAssertEqual(resources.map { $0.url.lastPathComponent }, ["master.dng", "companion.heic"])
        XCTAssertEqual(resources.first?.uniformTypeIdentifier, "com.adobe.raw-image")
        XCTAssertTrue(resources.allSatisfy { $0.url.deletingLastPathComponent() == folder })
    }

    func testBayerLiveKeepsProcessedStillAndMotionPairedWithRAWAlternate() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = MediaItem(filename: "live.heic", liveFilename: "live.mov", rawFilename: "sensor.dng",
                             isVideo: false, summary: "Bayer Live")
        let resources = PhotoExportResource.resources(for: item, in: folder)
        XCTAssertEqual(resources.map(\.type), [.photo, .pairedVideo, .alternatePhoto])
        XCTAssertEqual(resources.map { $0.url.lastPathComponent }, ["live.heic", "live.mov", "sensor.dng"])
        XCTAssertEqual(resources.last?.uniformTypeIdentifier, "com.adobe.raw-image")
    }

    func testSingleOriginalsAndLiveCompanionsRetainTheirResourceRoles() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let live = MediaItem(filename: "still.heic", liveFilename: "motion.mov", isVideo: false, summary: "Live")
        XCTAssertEqual(PhotoExportResource.resources(for: live, in: folder).map(\.type), [.photo, .pairedVideo])
        let rawOnly = MediaItem(filename: "recovered.dng", isVideo: false, summary: "Recovered RAW")
        let rawResources = PhotoExportResource.resources(for: rawOnly, in: folder)
        XCTAssertEqual(rawResources.map(\.type), [.photo])
        XCTAssertEqual(rawResources.first?.uniformTypeIdentifier, "com.adobe.raw-image")
        let movie = MediaItem(filename: "clip.mov", isVideo: true, summary: "Video")
        XCTAssertEqual(PhotoExportResource.resources(for: movie, in: folder).map(\.type), [.video])
    }

    @MainActor func testExportReservesCurrentSnapshotThroughPermissionAndSave() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let authorizationStarted = expectation(description: "Authorization requested")
        let exportStarted = expectation(description: "Photos export requested")
        var authorization: CheckedContinuation<PHAuthorizationStatus, Never>?
        var export: CheckedContinuation<Void, Error>?
        var authorizationCalls = 0
        var exportCalls = 0
        var exportedItem: MediaItem?
        var exportedResources: [PhotoExportResource] = []
        let library = MediaLibrary(directory: folder, requestPhotosAuthorization: {
            authorizationCalls += 1
            return await withCheckedContinuation { continuation in
                authorization = continuation
                authorizationStarted.fulfill()
            }
        }, exportPhotoResources: { item, resources in
            exportCalls += 1
            exportedItem = item
            exportedResources = resources
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                export = continuation
                exportStarted.fulfill()
            }
        })
        let processed = try file("companion.heic", in: folder)
        let raw = try file("master.dng", in: folder)
        await library.add(MediaDraft(url: processed, raw: raw, summary: "Current capture"), saveToPhotos: false)
        let current = try XCTUnwrap(library.items.first)
        var staleSnapshot = current
        staleSnapshot.rawFilename = "obsolete.dng"
        staleSnapshot.summary = "Old detail-view snapshot"
        staleSnapshot.created = .distantPast

        let firstExport = Task { @MainActor in await library.exportToPhotos(staleSnapshot) }
        await fulfillment(of: [authorizationStarted], timeout: 2)
        await library.exportToPhotos(current)
        library.deleteLocal(staleSnapshot)
        XCTAssertEqual(authorizationCalls, 1)
        XCTAssertEqual(exportCalls, 0)
        XCTAssertEqual(library.items.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: processed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path))

        try XCTUnwrap(authorization).resume(returning: .authorized)
        await fulfillment(of: [exportStarted], timeout: 2)
        await library.exportToPhotos(staleSnapshot)
        library.deleteLocal(current)
        XCTAssertEqual(authorizationCalls, 1)
        XCTAssertEqual(exportCalls, 1)
        XCTAssertEqual(exportedItem, current)
        XCTAssertEqual(exportedResources.map(\.url), [raw, processed])
        XCTAssertEqual(library.items.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path))

        try XCTUnwrap(export).resume(returning: ())
        await firstExport.value
        XCTAssertEqual(library.items.first?.savedToPhotos, true)
        await library.exportToPhotos(staleSnapshot)
        XCTAssertEqual(authorizationCalls, 1, "A stale unsaved snapshot must not export again.")
        XCTAssertEqual(exportCalls, 1)

        library.deleteLocal(staleSnapshot)
        XCTAssertTrue(library.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: processed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path), "Deletion must also use the current record, not stale filenames.")
        await library.exportToPhotos(staleSnapshot)
        XCTAssertEqual(authorizationCalls, 1, "A removed capture must not request Photos access.")
        XCTAssertEqual(exportCalls, 1)
    }

    @MainActor func testDeniedAuthorizationReleasesReservationAndPreservesFiles() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var authorizationCalls = 0
        var exportCalls = 0
        let library = MediaLibrary(directory: folder, requestPhotosAuthorization: {
            authorizationCalls += 1
            return authorizationCalls == 1 ? .denied : .authorized
        }, exportPhotoResources: { _, _ in exportCalls += 1 })
        let original = try file("still.heic", in: folder)
        let originalBytes = try Data(contentsOf: original)
        await library.add(MediaDraft(url: original), saveToPhotos: false)
        let item = try XCTUnwrap(library.items.first)
        await library.exportToPhotos(item)
        XCTAssertEqual(library.items.first?.savedToPhotos, false)
        XCTAssertEqual(exportCalls, 0)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        await library.exportToPhotos(item)
        XCTAssertEqual(authorizationCalls, 2)
        XCTAssertEqual(exportCalls, 1)
        XCTAssertEqual(library.items.first?.savedToPhotos, true)
    }

    @MainActor func testFailedPhotosTransactionCanRetryWithoutLosingOriginals() async throws {
        enum ExportFailure: Error { case rejected }
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var exportCalls = 0
        let library = MediaLibrary(directory: folder, requestPhotosAuthorization: { .authorized }, exportPhotoResources: { _, _ in
            exportCalls += 1
            if exportCalls == 1 { throw ExportFailure.rejected }
        })
        let original = try file("still.heic", in: folder)
        let originalBytes = try Data(contentsOf: original)
        await library.add(MediaDraft(url: original), saveToPhotos: false)
        let item = try XCTUnwrap(library.items.first)
        await library.exportToPhotos(item)
        XCTAssertEqual(library.items.first?.savedToPhotos, false)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        await library.exportToPhotos(item)
        XCTAssertEqual(exportCalls, 2)
        XCTAssertEqual(library.items.first?.savedToPhotos, true)
    }
}
