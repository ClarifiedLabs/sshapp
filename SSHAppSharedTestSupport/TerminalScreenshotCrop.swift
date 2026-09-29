import CoreImage
import Foundation
import UIKit
import Vision

/// Maps screen-coordinate pane bounds into an upright composited screen capture.
/// Never fall back to a whole-app OCR result when a pane was requested, since
/// that could accept another pane.
enum TerminalScreenshotCrop {
    /// UIImage carries orientation separately from its underlying CG pixels.
    /// Normalize the full screen before cropping in accessibility coordinates.
    @MainActor
    static func normalizedImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up { return image.cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }

    /// Vision on device missed small terminal text in a sparse pane crop, despite
    /// the pixels being present. A fixed 2x image scale preserves every glyph;
    /// no character substitution, expected-string hint, or OCR fallback is used.
    static func imageForRecognition(_ image: CGImage) -> CGImage? {
        let scaled = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 2, y: 2))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    /// Fixed recognizer for the harness's ASCII terminal markers. The accurate
    /// model synthesized Cyrillic characters in an otherwise clear final row on
    /// device. Fast recognition keeps these glyph fixtures literal; tests cover
    /// sparse output and all rows of a dense capture. Never repair its output.
    static func recognizedText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = false
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return TerminalOCRReadingOrder.text(from: (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return .init(text: text, boundingBox: observation.boundingBox)
        })
    }

    static func pixelRect(region: CGRect, captureFrame: CGRect, pixelSize: CGSize) -> CGRect? {
        guard [region.minX, region.minY, region.width, region.height,
               captureFrame.minX, captureFrame.minY, captureFrame.width, captureFrame.height,
               pixelSize.width, pixelSize.height].allSatisfy(\.isFinite),
              captureFrame.width > 0, captureFrame.height > 0,
              pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let visible = region.intersection(captureFrame)
        guard !visible.isNull, !visible.isEmpty else { return nil }
        let scaleX = pixelSize.width / captureFrame.width
        let scaleY = pixelSize.height / captureFrame.height
        return CGRect(x: (visible.minX - captureFrame.minX) * scaleX,
                      y: (visible.minY - captureFrame.minY) * scaleY,
                      width: visible.width * scaleX, height: visible.height * scaleY)
            .integral.intersection(CGRect(origin: .zero, size: pixelSize))
    }
}
