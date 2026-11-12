import SwiftUI
import ImageIO

struct CaptureFileInfo: Identifiable {
    var id: String { url.path }
    let url: URL
    let rows: [(String, String)]
    static func read(_ url: URL) -> CaptureFileInfo {
        var rows: [(String, String)] = [("File", url.lastPathComponent)]
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let bytes = values.fileSize {
            rows.append(("File size", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return CaptureFileInfo(url: url, rows: rows)
        }
        if let type = CGImageSourceGetType(source) { rows.append(("Container", type as String)) }
        let w = (p[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let h = (p[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        if w > 0 && h > 0 {
            rows.append(("Actual dimensions", "\(w) × \(h)"))
            rows.append(("Actual resolution", String(format: "%.2f MP", Double(w) * Double(h) / 1_000_000)))
        }
        if let depth = p[kCGImagePropertyDepth as String] { rows.append(("Reported component depth", "\(depth) bit")) }
        let exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        func add(_ title: String, _ key: CFString, _ values: [String: Any]) {
            if let v = values[key as String] { rows.append((title, String(describing: v))) }
        }
        add("Capture time", kCGImagePropertyExifDateTimeOriginal, exif)
        add("Subsecond time", kCGImagePropertyExifSubsecTimeOriginal, exif)
        add("Camera", kCGImagePropertyTIFFModel, tiff)
        add("Lens", kCGImagePropertyExifLensModel, exif)
        add("ISO", kCGImagePropertyExifISOSpeedRatings, exif)
        if let duration = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue, duration > 0 {
            rows.append(("Actual exposure", duration >= 1 ? String(format: "%.3f s", duration) : String(format: "1/%.1f s", 1 / duration)))
        }
        if let f = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue {
            rows.append(("Actual aperture", String(format: "f/%.2f", f)))
        }
        add("Exposure bias", kCGImagePropertyExifExposureBiasValue, exif)
        add("Focal length (mm)", kCGImagePropertyExifFocalLength, exif)
        add("35 mm equivalent", kCGImagePropertyExifFocalLenIn35mmFilm, exif)
        add("Color space", kCGImagePropertyExifColorSpace, exif)
        if let location = MediaLibrary.photoLocation(url) {
            rows.append(("GPS latitude", String(format: "%.6f", location.coordinate.latitude)))
            rows.append(("GPS longitude", String(format: "%.6f", location.coordinate.longitude)))
        }
        return CaptureFileInfo(url: url, rows: rows)
    }
}

struct CaptureMetadataView: View {
    let item: MediaItem
    @ObservedObject var library: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var files: [CaptureFileInfo] = []
    var body: some View {
        NavigationStack {
            List {
                if item.pairID != nil {
                    Section {
                        Text("Paired shutter capture. Each original has its own real exposure time and native metadata. These are consecutive exposures.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(files) { file in
                    Section(file.url.pathExtension.uppercased()) {
                        ForEach(Array(file.rows.enumerated()), id: \.offset) { _, row in
                            LabeledContent(row.0, value: row.1).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Original file metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                let urls = library.pairResources(for: item)
                files = await Task.detached(priority: .utility) { urls.map(CaptureFileInfo.read) }.value
            }
        }
    }
}
