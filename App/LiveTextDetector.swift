import Vision
import CoreImage

final class LiveTextDetector: @unchecked Sendable {
    func recognize(_ buffer: CVPixelBuffer) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.025
        do {
            // CaptureEngine already delivers portrait-oriented video buffers.
            // Rotating them again makes upright viewfinder text sideways to OCR.
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .filter { !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
        } catch { return [] }
    }
}
