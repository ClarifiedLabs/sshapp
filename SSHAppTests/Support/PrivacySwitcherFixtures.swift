import UIKit
import XCTest

/// App-switcher captures sanitized to the selected privacy snapshot plus the
/// full OS icon and its 2px measurement halo. ALL other screen pixels are
/// replaced by black. Keep the halo's real 0/1 background variation.
/// Mini retains only integral pixel rects (918,238,428,651), (1100,857,64,64);
/// Pro retains only (1276,290,616,821), (1552,1079,64,64). No personal card/title.
/// These measured constants belong only to regression fixtures, never detection.
enum PrivacySwitcherFixtures {
    struct Fixture {
        let name: String
        let display: CGRect
        let snapshot: CGRect
        let icon: CGRect // full-screenshot pixels
        let lockHeight: CGFloat
        func image() throws -> CGImage { try PrivacySwitcherFixtures.load(name) }
    }
    static let recorded: [Fixture] = [
        Fixture(name: "PrivacySwitcherMini", display: CGRect(x: 0, y: 0, width: 744, height: 1133),
            snapshot: CGRect(x: 459.032186419317, y: 119, width: 213.74404236540158, height: 325.5),
            icon: CGRect(x: 1102, y: 859, width: 60, height: 60), lockHeight: 25),
        Fixture(name: "PrivacySwitcherPro", display: CGRect(x: 0, y: 0, width: 1032, height: 1376),
            snapshot: CGRect(x: 638.0635901162823, y: 145, width: 307.875, height: 410.5),
            icon: CGRect(x: 1554, y: 1081, width: 60, height: 60), lockHeight: 25)
    ]
    static func load(_ name: String) throws -> CGImage {
        let url = try XCTUnwrap(Bundle(for: SystemPrivacyPixelGateTests.self)
            .url(forResource: name, withExtension: "png"))
        return try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
    }
    static func grayPixel(_ image: CGImage, x: Int, y: Int) throws -> Int {
        let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var gray: UInt8 = 0
        try withUnsafeMutablePointer(to: &gray) { pointer in
            let context = try XCTUnwrap(CGContext(data: pointer, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 1, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Int(gray)
    }
    static func painting(_ image: CGImage, rect: CGRect, color: UIColor) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: image.width, height: image.height), format: format)
            .image { context in
                UIImage(cgImage: image).draw(at: .zero)
                color.setFill(); context.fill(rect)
            }.cgImage)
    }
}
