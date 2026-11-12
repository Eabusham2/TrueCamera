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
    @Published private(set) var items: [MediaItem] = []
    @Published var message: String?
    private var manifest: URL { MediaFiles.directory.appendingPathComponent("library.json") }
    init() {
        do {
            try FileManager.default.createDirectory(at: MediaFiles.directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifest.path) {
                items = try JSONDecoder().decode([MediaItem].self, from: Data(contentsOf: manifest))
                items = items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            }
            // Recover any capture whose app was interrupted before the manifest write.
            let known = Set(items.flatMap { [$0.filename, $0.liveFilename, $0.rawFilename].compactMap { $0 } })
            let disk = try FileManager.default.contentsOfDirectory(at: MediaFiles.directory, includingPropertiesForKeys: nil)
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
        if item.savedToPhotos { message = "This capture is already saved to Photos."; return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            message = "Saved in the app. Photos permission was not granted; Share still works."; return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = item.created
                request.location = Self.photoLocation(item.url)
                let options = PHAssetResourceCreationOptions(); options.shouldMoveFile = false
                request.addResource(with: item.isVideo ? .video : .photo, fileURL: item.url, options: options)
                if let live = item.liveURL {
                    request.addResource(with: .pairedVideo, fileURL: live, options: options)
                }
                if let raw = item.rawURL {
                    let rawOptions = PHAssetResourceCreationOptions(); rawOptions.uniformTypeIdentifier = "com.adobe.raw-image"
                    request.addResource(with: .alternatePhoto, fileURL: raw, options: rawOptions)
                }
            }
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].savedToPhotos = true }
            persist(); message = nil
        } catch { message = "Saved in the app, but Photos export failed: \(error.localizedDescription)" }
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
        return group.flatMap { [$0.url, $0.rawURL, $0.liveURL].compactMap { $0 } }
    }

    func deleteLocal(_ item: MediaItem) {
        do {
            for url in [item.url, item.liveURL, item.rawURL].compactMap({ $0 }) {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            items.removeAll { $0.id == item.id }; persist()
            message = nil
        } catch { message = error.localizedDescription }
    }
    private func persist() {
        do { try JSONEncoder().encode(items).write(to: manifest, options: .atomic) }
        catch { message = "Capture exists, but the library index could not be saved: \(error.localizedDescription)" }
    }
}
