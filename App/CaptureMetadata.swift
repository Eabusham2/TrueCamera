import Foundation
import ImageIO
import CoreImage
import AVFoundation
import UniformTypeIdentifiers
import CoreLocation

enum CaptureMetadata {
    static func photo(_ settings: CameraSettings, base: [String: Any] = [:],
                      location: CLLocation? = CaptureLocation.shared.current()) -> [String: Any] {
        var metadata = base
        if settings.customMetadataEnabled {
            var tiff: [String: Any] = (metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
            tiff[kCGImagePropertyTIFFSoftware as String] = "TrueCamera"
            if !settings.metadataAuthor.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { tiff[kCGImagePropertyTIFFArtist as String]=settings.metadataAuthor }
            if !settings.metadataCopyright.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { tiff[kCGImagePropertyTIFFCopyright as String]=settings.metadataCopyright }
            let description=settings.metadataDescription.isEmpty ? settings.metadataTitle : settings.metadataDescription
            if !description.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { tiff[kCGImagePropertyTIFFImageDescription as String]=description }
            if !tiff.isEmpty { metadata[kCGImagePropertyTIFFDictionary as String]=tiff }
            var iptc:[String:Any]=(metadata[kCGImagePropertyIPTCDictionary as String] as? [String:Any]) ?? [:]
            if !settings.metadataTitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { iptc[kCGImagePropertyIPTCObjectName as String]=settings.metadataTitle }
            if !settings.metadataAuthor.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { iptc[kCGImagePropertyIPTCByline as String]=settings.metadataAuthor }
            if !settings.metadataCopyright.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { iptc[kCGImagePropertyIPTCCopyrightNotice as String]=settings.metadataCopyright }
            if !settings.metadataDescription.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { iptc[kCGImagePropertyIPTCCaptionAbstract as String]=settings.metadataDescription }
            let keywords=settings.metadataKeywords.split(separator:",").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
            if !keywords.isEmpty { iptc[kCGImagePropertyIPTCKeywords as String]=keywords }
            if !iptc.isEmpty { metadata[kCGImagePropertyIPTCDictionary as String]=iptc }
        }
        if settings.includeLocationMetadata, let location {
            metadata[kCGImagePropertyGPSDictionary as String]=CaptureLocation.gpsDictionary(location)
        }
        if !base.isEmpty {
            metadata[kCGImagePropertyOrientation as String]=1
            metadata.removeValue(forKey:kCGImagePropertyPixelWidth as String)
            metadata.removeValue(forKey:kCGImagePropertyPixelHeight as String)
        }
        return metadata
    }

    /// Use the displayed frame's host timestamp, not the later shutter/save time.
    /// A stale or unknown preview must not become a falsely dated video still.
    static func frameCaptureDate(hostTime: Double?, hostNow: Double, wallNow: Date,
                                 maximumAge: TimeInterval = 2) -> Date? {
        guard let hostTime, hostTime.isFinite, hostNow.isFinite,
              wallNow.timeIntervalSince1970.isFinite, maximumAge.isFinite, maximumAge >= 0 else { return nil }
        let age = hostNow - hostTime
        guard age >= 0, age <= maximumAge else { return nil }
        return wallNow.addingTimeInterval(-age)
    }

    static func encodeProcessed(_ image: CIImage, renderer: ImageRenderer, efficient: Bool, settings: CameraSettings, sourceData: Data? = nil,
                                depthData: AVDepthData? = nil, portraitEffectsMatte: AVPortraitEffectsMatte? = nil,
                                captureDate: Date? = nil, location: CLLocation? = CaptureLocation.shared.current(),
                                maximumQuality: Bool = false) -> (Data, String)? {
        guard let cg = renderer.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: renderer.colorSpace) else { return nil }
        let data = NSMutableData()
        let type = efficient ? UTType.heic.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }

        var base: [String:Any] = [:]
        if let sourceData, let source = CGImageSourceCreateWithData(sourceData as CFData,nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] {
            base = properties
        }
        // Write TIFF/EXIF/IPTC as properties of this image. Destination-wide
        // properties and hand-written XMP aliases do not reliably preserve them.
        var properties = photo(settings,base:base,location:location)
        properties[kCGImageDestinationLossyCompressionQuality as String] = maximumQuality ? 1.0 : (efficient ? 0.98 : 0.96)
        properties[kCGImagePropertyOrientation as String] = 1
        properties[kCGImagePropertyPixelWidth as String] = cg.width
        properties[kCGImagePropertyPixelHeight as String] = cg.height
        // The rendered pixels are already upright and cropped; old sensor-size
        // and orientation tags must not describe the new processed image.
        var tiff = (properties[kCGImagePropertyTIFFDictionary as String] as? [String:Any]) ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        var exif = (properties[kCGImagePropertyExifDictionary as String] as? [String:Any]) ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = cg.width
        exif[kCGImagePropertyExifPixelYDimension as String] = cg.height
        if let captureDate {
            guard captureDate.timeIntervalSince1970.isFinite else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let timestamp = formatter.string(from: captureDate)
            tiff[kCGImagePropertyTIFFDateTime as String] = timestamp
            exif[kCGImagePropertyExifDateTimeOriginal as String] = timestamp
            exif[kCGImagePropertyExifOffsetTimeOriginal as String] = "+00:00"
            formatter.dateFormat = "SSS"
            exif[kCGImagePropertyExifSubsecTimeOriginal as String] = formatter.string(from: captureDate)
            // There is no per-frame sensor EXIF in this preview. Do not fill
            // exposure, ISO, aperture or lens tags from later UI/device values.
        }
        properties[kCGImagePropertyTIFFDictionary as String] = tiff
        properties[kCGImagePropertyExifDictionary as String] = exif
        if !settings.includeLocationMetadata {
            properties.removeValue(forKey:kCGImagePropertyGPSDictionary as String)
        }
        CGImageDestinationAddImage(destination,cg,properties as CFDictionary)
        if let depthData {
            var type: NSString?
            if let dictionary = depthData.dictionaryRepresentation(forAuxiliaryDataType:&type), let type {
                CGImageDestinationAddAuxiliaryDataInfo(destination,type as CFString,dictionary as CFDictionary)
            }
        }
        if let portraitEffectsMatte {
            var type: NSString?
            if let dictionary = portraitEffectsMatte.dictionaryRepresentation(forAuxiliaryDataType:&type), let type {
                CGImageDestinationAddAuxiliaryDataInfo(destination,type as CFString,dictionary as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, efficient ? "heic" : "jpg")
    }
}
