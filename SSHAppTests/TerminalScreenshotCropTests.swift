import UIKit
import XCTest

final class TerminalScreenshotCropTests: XCTestCase {
    @MainActor
    func testVisionRecognizesSmallTextInBottomPaneSubimage() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let screenshot = UIGraphicsImageRenderer(size: CGSize(width: 440, height: 956), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 440, height: 956))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: UIColor(white: 0.8, alpha: 1)
            ]
            ("$ printf '\\n%s %s %s %04d\\n' ALPHA BOTTOM HISTORY 1" as NSString)
                .draw(at: CGPoint(x: 2, y: 360), withAttributes: attributes)
            ("ALPHA BOTTOM HISTORY 0001" as NSString)
                .draw(at: CGPoint(x: 2, y: 388), withAttributes: attributes)
        }
        let full = try XCTUnwrap(screenshot.cgImage)
        let crop = try XCTUnwrap(TerminalScreenshotCrop.imageForRecognition(
            XCTUnwrap(full.cropping(to: CGRect(x: 0, y: 1075, width: 1320, height: 677)))))
        let text = try TerminalScreenshotCrop.recognizedText(in: crop)
        XCTAssertTrue(text.contains("ALPHA BOTTOM HISTORY 0001"), "Generated bottom-pane OCR: \(text)")
    }

    func testVisionRecognizesCapturedSmallTerminalText() throws {
        // Sanitized crop: only our printf command and synthetic marker, no host,
        // login, session identity, or other application content.
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TerminalBottomPaneOCR", withExtension: "png"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        let scaled = try XCTUnwrap(TerminalScreenshotCrop.imageForRecognition(image))
        XCTAssertEqual(scaled.width, image.width * 2)
        XCTAssertEqual(scaled.height, image.height * 2)
        let text = try TerminalScreenshotCrop.recognizedText(in: scaled)
        XCTAssertTrue(text.contains("ALPHA BOTTOM HISTORY 0001"), "Captured bottom-pane OCR: \(text)")
    }

    func testVisionRecognizesFinalHistoryRowWithoutSubstitutingCharacters() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TerminalHistoryPaneOCR", withExtension: "png"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        // This capture already contains the harness's fixed 2x scale.
        let text = try TerminalScreenshotCrop.recognizedText(in: image)
        for number in 14...32 {
            XCTAssertTrue(text.contains(String(format: "ALPHA BOTTOM LINE %04d", number)), text)
        }
    }

    @MainActor
    func testNormalizationAppliesAllEightOrientationsExactlyOnceAtScaleThree() throws {
        // Raw portrait pixels, in top-to-bottom rows: RG / BY / MC.
        // Expectations are explicit raster layouts, not another UIImage draw.
        let source = try coloredPortraitImage()
        let cases: [(UIImage.Orientation, [[FixtureColor]])] = [
            (.up, [[.red, .green], [.blue, .yellow], [.magenta, .cyan]]),
            (.down, [[.cyan, .magenta], [.yellow, .blue], [.green, .red]]),
            (.left, [[.green, .yellow, .cyan], [.red, .blue, .magenta]]),
            (.right, [[.magenta, .blue, .red], [.cyan, .yellow, .green]]),
            (.upMirrored, [[.green, .red], [.yellow, .blue], [.cyan, .magenta]]),
            (.downMirrored, [[.magenta, .cyan], [.blue, .yellow], [.red, .green]]),
            (.leftMirrored, [[.red, .blue, .magenta], [.green, .yellow, .cyan]]),
            (.rightMirrored, [[.cyan, .yellow, .green], [.magenta, .blue, .red]])
        ]
        for (orientation, rows) in cases {
            let image = UIImage(cgImage: source, scale: 3, orientation: orientation)
            let normalized = try XCTUnwrap(TerminalScreenshotCrop.normalizedImage(image))
            // Each six-pixel color block occupies two logical points at 3x.
            XCTAssertEqual(image.size, CGSize(width: rows[0].count * 2, height: rows.count * 2))
            try assertPixels(normalized, rows: rows, message: "Orientation: \(orientation)")
        }
    }

    @MainActor
    func testNormalizedLandscapeScreenCropClipsOffsetAppAndExcludesNeighboringPixels() throws {
        let source = try coloredPortraitImage()
        let screenBounds = CGRect(x: 0, y: 0, width: 6, height: 4)
        let appFrame = CGRect(x: 2, y: 1, width: 4, height: 3)
        // The pane extends outside both the offset app and the screen.
        let paneFrame = CGRect(x: 0, y: 2, width: 4, height: 3)
        let cases: [(UIImage.Orientation, FixtureColor)] = [(.left, .blue), (.right, .yellow)]
        for (orientation, expectedColor) in cases {
            let screenshot = UIImage(cgImage: source, scale: 3, orientation: orientation)
            let normalized = try XCTUnwrap(TerminalScreenshotCrop.normalizedImage(screenshot))
            let rect = try XCTUnwrap(TerminalScreenshotCrop.pixelRect(
                region: paneFrame.intersection(appFrame),
                captureFrame: screenBounds,
                pixelSize: CGSize(width: normalized.width, height: normalized.height)))
            XCTAssertEqual(rect, CGRect(x: 6, y: 6, width: 6, height: 6))
            let crop = try XCTUnwrap(normalized.cropping(to: rect))
            // Every pixel must belong to this pane, not either horizontal
            // neighbor or the pane above. Both landscape directions matter.
            try assertPixels(crop, rows: [[expectedColor]], message: "Crop orientation: \(orientation)")
        }
    }

    func testBottomPaneUsesScreenOriginAndPhysicalPixelScale() {
        XCTAssertEqual(TerminalScreenshotCrop.pixelRect(
            region: CGRect(x: 0, y: 350, width: 440, height: 220),
            captureFrame: CGRect(x: 0, y: 0, width: 440, height: 956),
            pixelSize: CGSize(width: 1320, height: 2868)),
            CGRect(x: 0, y: 1050, width: 1320, height: 660))
    }

    func testLandscapeOffsetCaptureSubtractsOriginBeforeScaling() {
        XCTAssertEqual(TerminalScreenshotCrop.pixelRect(
            region: CGRect(x: 120, y: 70, width: 400, height: 100),
            captureFrame: CGRect(x: 20, y: 30, width: 800, height: 400),
            pixelSize: CGSize(width: 1600, height: 800)),
            CGRect(x: 200, y: 80, width: 800, height: 200))
    }

    func testPartiallyClippedPaneDoesNotIncludeNeighboringPixels() {
        XCTAssertEqual(TerminalScreenshotCrop.pixelRect(
            region: CGRect(x: -10, y: 150, width: 120, height: 100),
            captureFrame: CGRect(x: 0, y: 0, width: 100, height: 200),
            pixelSize: CGSize(width: 200, height: 400)),
            CGRect(x: 0, y: 300, width: 200, height: 100))
    }

    func testInvisibleOrInvalidCropNeverFallsBackToWholeCapture() {
        let capture = CGRect(x: 0, y: 0, width: 100, height: 200)
        let pixels = CGSize(width: 200, height: 400)
        for region in [CGRect.zero, CGRect(x: 0, y: 250, width: 100, height: 100),
                       CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100)] {
            XCTAssertNil(TerminalScreenshotCrop.pixelRect(region: region, captureFrame: capture, pixelSize: pixels))
        }
        XCTAssertNil(TerminalScreenshotCrop.pixelRect(region: capture, captureFrame: .zero, pixelSize: pixels))
    }

    private enum FixtureColor: UInt32 {
        case red = 0xFF0000
        case green = 0x00FF00
        case blue = 0x0000FF
        case yellow = 0xFFFF00
        case magenta = 0xFF00FF
        case cyan = 0x00FFFF

        var rgba: [UInt8] {
            [UInt8((rawValue >> 16) & 0xFF), UInt8((rawValue >> 8) & 0xFF), UInt8(rawValue & 0xFF), 255]
        }
    }

    private func coloredPortraitImage() throws -> CGImage {
        let rows: [[FixtureColor]] = [[.red, .green], [.blue, .yellow], [.magenta, .cyan]]
        var bytes: [UInt8] = []
        for y in 0..<18 {
            for x in 0..<12 {
                bytes.append(contentsOf: rows[y / 6][x / 6].rgba)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(
            width: 12, height: 18, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 12 * 4,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func assertPixels(
        _ image: CGImage,
        rows: [[FixtureColor]],
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let width = rows[0].count * 6
        let height = rows.count * 6
        XCTAssertEqual(image.width, width, message, file: file, line: line)
        XCTAssertEqual(image.height, height, message, file: file, line: line)
        guard image.width == width, image.height == height else { return }
        // Decode to a known byte layout without UIImage or any orientation
        // transform, independently of the renderer's native bitmap format.
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                XCTAssertEqual(Array(bytes[offset..<(offset + 4)]), rows[y / 6][x / 6].rgba,
                               "\(message), pixel (\(x), \(y))", file: file, line: line)
            }
        }
    }
}
