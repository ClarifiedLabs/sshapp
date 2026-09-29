import Metal
import UIKit
import XCTest
@testable import GhosttyVT

/// Renderer-only glyph workload: scrolling output rendered straight through
/// VTMetalRasterizer, isolating glyph rasterization, shaping and atlas cost
/// from display pacing. Compare runs before and after a renderer change on the
/// same physical device in Release; simulator numbers are only a smoke check.
@MainActor
final class VTGlyphAtlasBenchmarkTests: XCTestCase {
    private enum Workload: String, CaseIterable {
        case monochrome, sevenColor, truecolor

        func batch(_ iteration: Int) -> Data {
            let rows = (0..<32).map { row -> String in
                let text = "row-\(iteration)-\(row) 0123456789 abcdefghijklmnopqrstuvwxyz"
                switch self {
                case .monochrome:
                    return text
                case .sevenColor:
                    return "\u{1B}[\(31 + (iteration + row) % 7)m\(text)\u{1B}[0m"
                case .truecolor:
                    // Every glyph a different color, like syntax highlighting.
                    return text.enumerated().map { index, character in
                        let hue = (iteration * 7 + row * 13 + index * 29) % 256
                        return "\u{1B}[38;2;\(hue);\(255 - hue);\((hue * 3) % 256)m\(character)"
                    }.joined() + "\u{1B}[0m"
                }
            }
            return Data((rows.joined(separator: "\r\n") + "\r\n").utf8)
        }
    }

    func testGlyphAtlasWorkloads() async throws {
        let scale = UIScreen.main.scale
        let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let cell = CGSize(width: ceil(("M" as NSString).size(withAttributes: [.font: font]).width * scale) / scale,
                          height: ceil(font.lineHeight * scale) / scale)
        for workload in Workload.allCases {
            let layout = try VTLayout(generation: 1, width: 390, height: 600, cellWidth: cell.width,
                                      cellHeight: cell.height, scale: scale, padding: 0)
            let terminal = try VTTerminal(layout: layout)
            let renderer = try VTMetalRasterizer()
            var workerMilliseconds: [Double] = []
            var passes: [Int] = []
            // Warm the pipeline so shader compilation is not measured.
            _ = try await terminal.ingest(workload.batch(0))
            _ = try await renderer.render(try await terminal.snapshot(), font: font)
            for iteration in 1...120 {
                _ = try await terminal.ingest(workload.batch(iteration))
                let timing = try await renderer.render(try await terminal.snapshot(), font: font)
                workerMilliseconds.append(timing.workerCPUMilliseconds)
                passes.append(timing.renderPasses)
            }
            let sorted = workerMilliseconds.sorted()
            let report: [String: Any] = [
                "workload": workload.rawValue, "scale": scale, "frames": sorted.count,
                "workerCPUMedianMs": sorted[sorted.count / 2],
                "workerCPUp95Ms": sorted[Int(Double(sorted.count) * 0.95) - 1],
                "workerCPUTotalMs": sorted.reduce(0, +),
                "maxRenderPasses": passes.max() ?? 0,
                "cachedGlyphs": renderer.cachedGlyphs, "shapedGlyphs": renderer.shapedGlyphs,
                "shapingMisses": renderer.shapingMisses,
                "atlasBytes": renderer.atlasBytes, "retainedTextureBytes": renderer.retainedTextureBytes,
            ]
            let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("VT_GLYPH_ATLAS_BENCHMARK \(String(decoding: json, as: UTF8.self))")
            let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
            attachment.name = "vt-glyph-atlas-\(workload.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
            renderer.releaseResources()
            _ = try await terminal.retire()
        }
    }
}
