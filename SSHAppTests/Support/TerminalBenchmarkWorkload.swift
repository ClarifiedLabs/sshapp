import UIKit

/// Image replacement payloads for retained-pane memory tests and benchmarks.
/// Payloads are built once, before the process baseline, and shared across panes.
struct TerminalGraphicsMemoryWorkload: Sendable {
    static let identifier = "image-replacement-retained-lifecycle-v1"
    let side: Int
    let payloads: [Data]
    var imageBytes: Int { side * side * 4 }

    init(side: Int) {
        precondition((1...1_024).contains(side))
        self.side = side
        payloads = [UInt8(64), UInt8(192)].map { level in
            var pixels = Data(repeating: level, count: side * side * 4)
            pixels.withUnsafeMutableBytes { storage in
                let bytes = storage.bindMemory(to: UInt8.self)
                for alpha in stride(from: 3, to: bytes.count, by: 4) { bytes[alpha] = 255 }
            }
            // Two placements share one image; replacements reuse protocol ID 1
            // while creating fresh native generations. Keep the sample point
            // in row 2 clear of text for the baseline IOSurface pixel check.
            let encoded = pixels.base64EncodedData()
            var image = Data()
            image.reserveCapacity(encoded.count + encoded.count / 100)
            for offset in stride(from: 0, to: encoded.count, by: 4_096) {
                let end = min(offset + 4_096, encoded.count)
                let more = end < encoded.count ? 1 : 0
                let controls = offset == 0
                    ? "a=T,f=32,s=\(side),v=\(side),i=1,p=1,c=8,r=4,z=-1,C=1,q=2,m=\(more)"
                    : "m=\(more)"
                image.append(Data("\u{1B}_G\(controls);".utf8))
                image.append(encoded[offset..<end])
                image.append(Data("\u{1B}\\".utf8))
            }
            let reuse = "\u{1B}_Ga=p,i=1,p=2,c=4,r=4,x=0,w=\(max(1, side / 2)),z=-1,C=1,q=2\u{1B}\\"
            var result = Data("\u{1B}[?25l\u{1B}[Hgraphics-gray-\(level)\u{1B}[K\u{1B}[2;1H".utf8)
            result.append(image)
            result.append(Data(("\u{1B}[2;13H" + reuse).utf8))
            return result
        }
    }

    func payload(_ index: Int) -> Data { payloads[index % payloads.count] }
    func level(_ index: Int) -> UInt8 { index % 2 == 0 ? 64 : 192 }
    static let enterAlternate = Data("\u{1B}[?1049h".utf8)
    static let leaveAlternate = Data("\u{1B}[?1049l".utf8)
}

/// Fixed benchmark workload. Keep the offered bytes, font, cell geometry,
/// resize sequence and clock deadlines unchanged so reports stay comparable.
@MainActor
enum TerminalBenchmarkWorkload {
    static let identifier = "matched-menlo-20hz-v2"
    static let scrollbackBytes = 10_000_000
    static let fontFamily = "Menlo"
    static let ghosttyFontPoints: Float = 10
    // 10 typographic points at 96 logical DPI, expressed in UIKit points.
    static let font = UIFont(name: "Menlo-Regular", size: 40.0 / 3.0)!
    static let intervalMilliseconds = 50
    static let shortSamples = 20
    static let sustainedSamples = 1_200
    static let batch = Data((0..<128).map {
        "\u{1B}[\(31 + $0 % 7)mrow-\($0) 0123456789 abcdefghijklmnopqrstuvwxyz\u{1B}[0m\r\n"
    }.joined().utf8)

    /// Every run measures the same fully visible 390×600 canvas.
    /// Compact windows cannot supply this workload without clipping it.
    static func canvasOrigin(in safeArea: CGRect) -> CGPoint? {
        guard safeArea.width >= 390, safeArea.height >= 600 else { return nil }
        return CGPoint(x: safeArea.midX - 195, y: safeArea.midY - 300)
    }

    static func cellSize(scale: CGFloat) -> CGSize {
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: (width * scale).rounded() / scale,
                      height: (font.lineHeight * scale).rounded() / scale)
    }

    static func width(after sample: Int) -> CGFloat {
        // Resize after samples 10, 30, 50, ...; the next sample sees the new grid.
        sample < 10 || ((sample - 10) / 20) % 2 != 0 ? 390 : 350
    }

    static func wait(for sample: Int, from start: ContinuousClock.Instant) async throws -> Double {
        let deadline = start.advanced(by: .milliseconds(intervalMilliseconds * sample))
        try await ContinuousClock().sleep(until: deadline, tolerance: .milliseconds(1))
        let late = deadline.duration(to: .now).components
        return max(0, Double(late.seconds) * 1_000 + Double(late.attoseconds) / 1e15)
    }

    static func metadata(scale: CGFloat, samples: Int) -> [String: Any] {
        let cell = cellSize(scale: scale)
        return ["id": identifier, "fontName": font.fontName, "coreTextFontPoints": font.pointSize,
                "ghosttyFontPoints": ghosttyFontPoints, "cellWidthPixels": Int((cell.width * scale).rounded()),
                "cellHeightPixels": Int((cell.height * scale).rounded()), "paddingPixels": 0,
                "intervalMilliseconds": intervalMilliseconds, "samples": samples, "scrollbackBytes": scrollbackBytes,
                "batchBytes": batch.count, "bytesPerPane": batch.count * samples]
    }
}
