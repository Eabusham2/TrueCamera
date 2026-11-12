import Foundation
import Photos
import Combine
import ImageIO
import CoreLocation

struct MediaDraft {
    let url: URL
    var liveMovie: URL? = nil
    var raw: URL? = nil
    var isVideo = false
    var summary = ""
    var created: Date = Date()
    var pairID: UUID? = nil
}
struct MediaItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var created = Date()
    let filename: String
    var liveFilename: String?
    var rawFilename: String?
    let isVideo: Bool
    var summary: String
    var savedToPhotos = false
    var pairID: UUID? = nil
    var url: URL { MediaFiles.directory.appendingPathComponent(filename) }
    var liveURL: URL? { liveFilename.map { MediaFiles.directory.appendingPathComponent($0) } }
    var rawURL: URL? { rawFilename.map { MediaFiles.directory.appendingPathComponent($0) } }
}

/// File roles passed to PhotoKit, kept separate from its asynchronous transaction.
struct PhotoExportResource: Equatable {
    let type: PHAssetResourceType
    let url: URL
    var uniformTypeIdentifier: String? = nil

    static func resources(for item: MediaItem, in directory: URL = MediaFiles.directory) -> [PhotoExportResource] {
        let original = directory.appendingPathComponent(item.filename)
        if item.isVideo { return [PhotoExportResource(type: .video, url: original)] }
        let raw = item.rawFilename.map { directory.appendingPathComponent($0) }
        let live = item.liveFilename.map { directory.appendingPathComponent($0) }
        if let raw, live == nil {
            // A RAW master is the asset's original, with its encoded companion
            // retained as the alternate representation.
            return [PhotoExportResource(type: .photo, url: raw, uniformTypeIdentifier: "com.adobe.raw-image"),
                    PhotoExportResource(type: .alternatePhoto, url: original)]
        }
        var result = [PhotoExportResource(type: .photo, url: original,
            uniformTypeIdentifier: original.pathExtension.lowercased() == "dng" ? "com.adobe.raw-image" : nil)]
        if let live { result.append(PhotoExportResource(type: .pairedVideo, url: live)) }
        if let raw {
            // Bayer RAW can accompany a Live Photo in one exposure. Its processed
            // still owns the Live pairing metadata, so keep that still primary and
            // its movie paired; the DNG remains the untouched alternate resource.
            result.append(PhotoExportResource(type: .alternatePhoto, url: raw, uniformTypeIdentifier: "com.adobe.raw-image"))
        }
        return result
    }
}

enum MediaFiles {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
    }
    static func newURL(extension suffix: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
    }
    static func requireSpace() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Do not impose an arbitrary free-space quota. Native capture/writes
        // surface real storage errors and retain any completed original.
    }
}
@MainActor final class MediaLibrary: ObservableObject {
    typealias PhotosAuthorizationRequest = @MainActor () async -> PHAuthorizationStatus
    typealias PhotosResourceExport = @MainActor (MediaItem, [PhotoExportResource]) async throws -> Void

    @Published private(set) var items: [MediaItem] = []
    @Published var message: String?
    private let directory: URL
    private let requestPhotosAuthorization: PhotosAuthorizationRequest
    private let exportPhotoResources: PhotosResourceExport
    private var exportsInProgress: Set<UUID> = []
    private var manifest: URL { directory.appendingPathComponent("library.json") }

    init(directory: URL = MediaFiles.directory,
         requestPhotosAuthorization: @escaping PhotosAuthorizationRequest = { await PHPhotoLibrary.requestAuthorization(for: .addOnly) },
         exportPhotoResources: PhotosResourceExport? = nil) {
        self.directory = directory
        self.requestPhotosAuthorization = requestPhotosAuthorization
        self.exportPhotoResources = exportPhotoResources ?? Self.writePhotosResources
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifest.path) {
                items = try JSONDecoder().decode([MediaItem].self, from: Data(contentsOf: manifest))
                items = items.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.filename).path) }
            }
            // Recover any capture whose app was interrupted before the manifest write.
            let known = Set(items.flatMap { [$0.filename, $0.liveFilename, $0.rawFilename].compactMap { $0 } })
            let disk = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for url in disk where !known.contains(url.lastPathComponent) && ["mov","heic","jpg","dng"].contains(url.pathExtension.lowercased()) {
                items.append(MediaItem(filename: url.lastPathComponent, isVideo: url.pathExtension == "mov", summary: "Recovered local capture"))
            }
            items.sort { $0.created > $1.created }
        } catch { message = "Local library: \(error.localizedDescription)" }
    }
    func add(_ draft: MediaDraft, saveToPhotos: Bool) async {
        let item = MediaItem(created: draft.created, filename: draft.url.lastPathComponent, liveFilename: draft.liveMovie?.lastPathComponent,
                             rawFilename: draft.raw?.lastPathComponent, isVideo: draft.isVideo, summary: draft.summary, pairID: draft.pairID)
        items.insert(item, at: 0)
        persist()
        if saveToPhotos { await exportToPhotos(item) }
        else { message = nil }
    }
    func exportToPhotos(_ item: MediaItem) async {
        // The view may hold an older value. Resolve its ID before checking state
        // or retaining an immutable export snapshot across either suspension.
        guard let current = items.first(where: { $0.id == item.id }) else {
            message = "This capture is no longer in the local library."; return
        }
        if current.savedToPhotos { message = "This capture is already saved to Photos."; return }
        guard exportsInProgress.insert(current.id).inserted else {
            message = "This capture is already being saved to Photos."; return
        }
        defer { exportsInProgress.remove(current.id) }
        let resources = PhotoExportResource.resources(for: current, in: directory)
        let status = await requestPhotosAuthorization()
        guard status == .authorized || status == .limited else {
            message = "Saved in the app. Photos permission was not granted; Share still works."; return
        }
        do {
            try await exportPhotoResources(current, resources)
            if let index = items.firstIndex(where: { $0.id == current.id }) { items[index].savedToPhotos = true }
            persist(); message = nil
        } catch { message = "Saved in the app, but Photos export failed: \(error.localizedDescription)" }
    }

    private static func writePhotosResources(_ item: MediaItem, _ resources: [PhotoExportResource]) async throws {
        let metadataURL = resources.first(where: { $0.url.lastPathComponent == item.filename })?.url
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = item.created
            request.location = metadataURL.flatMap { Self.photoLocation($0) }
            for resource in resources {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                options.uniformTypeIdentifier = resource.uniformTypeIdentifier
                request.addResource(with: resource.type, fileURL: resource.url, options: options)
            }
        }
    }
    nonisolated static func photoLocation(_ url: URL) -> CLLocation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any],
              var lat = (gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue,
              var lon = (gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue,
              lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" { lat = -lat }
        if (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" { lon = -lon }
        return CLLocation(latitude: lat, longitude: lon)
    }
    func pairResources(for item: MediaItem) -> [URL] {
        let group = item.pairID.map { id in items.filter { $0.pairID == id } } ?? [item]
        return group.flatMap { value in
            [value.filename, value.rawFilename, value.liveFilename].compactMap { $0 }
                .map { directory.appendingPathComponent($0) }
        }
    }

    func deleteLocal(_ item: MediaItem) {
        guard let current = items.first(where: { $0.id == item.id }) else {
            message = "This capture is no longer in the local library."; return
        }
        guard !exportsInProgress.contains(current.id) else {
            message = "Wait for this capture to finish saving to Photos before deleting its local copy."; return
        }
        do {
            let filenames = [current.filename, current.liveFilename, current.rawFilename].compactMap { $0 }
            for url in filenames.map({ directory.appendingPathComponent($0) }) {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            items.removeAll { $0.id == current.id }; persist()
            message = nil
        } catch { message = error.localizedDescription }
    }
    private func persist() {
        do { try JSONEncoder().encode(items).write(to: manifest, options: .atomic) }
        catch { message = "Capture exists, but the library index could not be saved: \(error.localizedDescription)" }
    }
}
