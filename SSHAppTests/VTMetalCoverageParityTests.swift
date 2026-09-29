import Metal
import UIKit
import XCTest
@testable import GhosttyVT

/// The Metal renderer stores monochrome glyphs as coverage tinted per cell and
/// color glyphs as RGBA. CoreText composites colored text with a color-
/// dependent adjustment that no color-independent mask reproduces exactly
/// (verified against 8- and 16-bit coverage), so antialiased edge pixels may
/// differ by one 8-bit step; everything else, and all color glyphs, match.
@MainActor
final class VTMetalCoverageParityTests: XCTestCase {
    private let font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)

    private struct Difference: CustomStringConvertible {
        var changedPixels = 0
        var maximumChannelError = 0
        var totalPixels = 0
        var description: String { "changed=\(changedPixels)/\(totalPixels) maxError=\(maximumChannelError)" }
    }

    func testColdBackgroundOnlyFrameAndEmptyFrameAfterTextMatchCoreText() async throws {
        let renderer = try VTMetalRasterizer()
        defer { renderer.releaseResources() }
        let blank = try await frame("\u{1B}[?25l\u{1B}[48;2;12;40;90m\u{1B}[2J", scale: 3, smoothing: true)
        let cold = try await compare(blank, renderer: renderer)
        XCTAssertEqual(cold.changedPixels, 0)
        XCTAssertEqual(renderer.peakVertexBytes, 0, "A background-only frame needs no quad buffer")
        let text = try await frame("\u{1B}[?25lText", scale: 3, smoothing: true)
        _ = try await compare(text, renderer: renderer)
        let reused = try await compare(blank, renderer: renderer)
        XCTAssertEqual(reused.changedPixels, 0)
        XCTAssertEqual(renderer.peakVertexBytes, 0)
    }

    func testColoredStyledAndFaintTextMatchesCoreText() async throws {
        let text = "\u{1B}[?25l"
            + (0..<48).map { "\u{1B}[38;2;\(40 + $0 * 4);\(250 - $0 * 5);\(90 + $0 * 3)mW" }.joined()
            + "\r\n\u{1B}[1;38;2;255;80;0mBold \u{1B}[3;38;2;0;160;255mItalic\u{1B}[0m"
            + "\r\n\u{1B}[2;38;2;255;255;255mFaint \u{1B}[0;38;2;255;255;0mag|jy{}"
            + "\r\n\u{1B}[48;2;250;250;245;38;2;20;20;30m Light theme text \u{1B}[48;2;0;90;160;38;2;255;210;0m on blue \u{1B}[0m"
        for smoothing in [true, false] {
            for scale in [1.0, 2, 3] {
                let value = try await frame(text, scale: scale, smoothing: smoothing)
                let difference = try await compare(value)
                print("VT_COVERAGE_PARITY text smoothing=\(smoothing) scale=\(scale) \(difference)")
                XCTAssertLessThanOrEqual(difference.maximumChannelError, 1, "\(difference)")
                XCTAssertLessThan(Double(difference.changedPixels) / Double(difference.totalPixels), 0.02, "\(difference)")
            }
        }
    }

    func testEmojiUseColorPixelsAndMatchCoreText() async throws {
        let value = try await frame("\u{1B}[?25l\u{1B}[38;2;255;0;0mA🙂B🚀", scale: 2, smoothing: true)
        let renderer = try VTMetalRasterizer()
        defer { renderer.releaseResources() }
        let difference = try await compare(value, renderer: renderer)
        print("VT_COVERAGE_PARITY emoji \(difference)")
        XCTAssertEqual(difference.changedPixels, 0, "Color glyphs keep their exact RGBA pixels")
        XCTAssertGreaterThan(renderer.atlasBytes,
                             VTMetalRasterizer.initialAtlasSide * VTMetalRasterizer.initialAtlasSide,
                             "Emoji must allocate the color page")
    }

    private func compare(_ value: VTFrameValue, renderer: VTMetalRasterizer? = nil) async throws -> Difference {
        let cpu = try cpuPixels(value)
        let metal = try await metalPixels(value, renderer: renderer)
        XCTAssertEqual(cpu.count, metal.count)
        var difference = Difference(totalPixels: cpu.count / 4)
        for pixel in 0..<(cpu.count / 4) {
            let offset = pixel * 4
            var changed = false
            for channel in 0..<4 {
                let error = abs(Int(cpu[offset + channel]) - Int(metal[offset + channel]))
                if error > 0 { changed = true }
                difference.maximumChannelError = max(difference.maximumChannelError, error)
            }
            if changed { difference.changedPixels += 1 }
        }
        return difference
    }

    private func frame(_ text: String, scale: Double, smoothing: Bool) async throws -> VTFrameValue {
        let layout = try VTLayout(generation: 1, width: 600, height: 96, cellWidth: 12, cellHeight: 24,
                                  scale: scale, padding: 0)
        let terminal = try VTTerminal(layout: layout)
        var configuration = VTTerminalConfiguration()
        configuration.paint.fontSmoothing = smoothing
        _ = try await terminal.configure(configuration)
        _ = try await terminal.ingest(Data(text.utf8))
        let frame = try await terminal.snapshot()
        _ = try await terminal.retire()
        return frame
    }

    private func cpuPixels(_ frame: VTFrameValue) throws -> [UInt8] {
        let width = Int(frame.layout.viewportWidth * frame.layout.scale)
        let height = Int(frame.layout.viewportHeight * frame.layout.scale)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: frame.layout.scale, y: -frame.layout.scale)
            VTCoreTextRenderer.draw(frame, font: font, context: context,
                bounds: CGRect(x: 0, y: 0, width: frame.layout.viewportWidth, height: frame.layout.viewportHeight),
                cache: VTGlyphCache())
        }
        return bytes
    }

    private func metalPixels(_ frame: VTFrameValue, renderer: VTMetalRasterizer?) async throws -> [UInt8] {
        let renderer = try renderer ?? VTMetalRasterizer()
        _ = try await renderer.render(frame, font: font)
        let texture = try XCTUnwrap(renderer.output)
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }
}
