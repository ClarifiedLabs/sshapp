import UIKit
import XCTest

/// Pure pixel/fixture replay for the physical app-switcher privacy gate. These
/// need no device UI, so they run in the app-hosted unit target instead of the
/// UI-test runner (whose iOS CPU limit killed it during these native raster
/// loops, and whose relaunch then crashed SpringBoard on iPadOS 27).
///
/// The raster work takes minutes of CPU. Every test is a `@concurrent` async
/// method so it runs on the cooperative pool, never on the unit-test host's
/// main thread (which it previously blocked for ~200 s, flooding HangTracer).
final class SystemPrivacyPixelGateTests: XCTestCase {
    @concurrent func testPrivacyPixelGateRejectsBlankUncoveredMonochromeAndStaleInitialText() async throws {
        let symbol = try XCTUnwrap(SystemPrivacyPixelGate.productionSymbol)
        let size = CGSize(width: 320, height: 480)
        func fixture(text: String? = nil, lock: Bool = false, light: Bool = false) throws -> CGImage {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                (light ? UIColor.white : UIColor.black).setFill(); context.fill(CGRect(origin: .zero, size: size))
                if lock {
                    symbol.withTintColor(.gray, renderingMode: .alwaysOriginal).draw(in: CGRect(
                        x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2,
                        width: symbol.size.width, height: symbol.size.height))
                }
                if let text {
                    (text as NSString).draw(at: CGPoint(x: 8, y: size.height / 2), withAttributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: UIColor.white])
                }
            }
            return try XCTUnwrap(image.cgImage)
        }
        for light in [false, true] {
            XCTAssertTrue(SystemPrivacyPixelGate.containsProductionLock(in: try fixture(lock: true, light: light), expectedHeight: symbol.size.height))
            XCTAssertFalse(SystemPrivacyPixelGate.containsProductionLock(in: try fixture(light: light), expectedHeight: symbol.size.height))
        }
        for text in ["ALPHA BRAVO CHARLIE DELTA ECHO", "user@host:~$ ls -la", "LIFE SYS ACDEFG ONE"] {
            XCTAssertFalse(SystemPrivacyPixelGate.containsProductionLock(in: try fixture(text: text), expectedHeight: symbol.size.height), text)
        }
    }

    @concurrent func testPrivacyCoverRejectsCenteredLockWithColoredOrTextLeaksAtEveryEdge() async throws {
        let symbol = try XCTUnwrap(SystemPrivacyPixelGate.productionSymbol)
        let size = CGSize(width: 320, height: 480)
        let leaks = [CGRect(x: 2, y: 210, width: 12, height: 40),
                     CGRect(x: 306, y: 210, width: 12, height: 40),
                     CGRect(x: 130, y: 2, width: 60, height: 12),
                     CGRect(x: 130, y: 466, width: 60, height: 12)]
        for light in [false, true] {
            for leak in [CGRect.null] + leaks {
                for colored in [false, true] {
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                        (light ? UIColor.white : UIColor.black).setFill(); context.fill(CGRect(origin: .zero, size: size))
                        symbol.withTintColor(.gray, renderingMode: .alwaysOriginal).draw(in: CGRect(
                            x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2,
                            width: symbol.size.width, height: symbol.size.height))
                        if !leak.isNull {
                            if colored { UIColor.red.setFill(); context.fill(leak) }
                            else {
                                ("ls" as NSString).draw(at: leak.origin, withAttributes: [
                                    .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                                    .foregroundColor: light ? UIColor.black : UIColor.white])
                            }
                        }
                    }
                    let raster = try XCTUnwrap(image.cgImage)
                    XCTAssertTrue(SystemPrivacyPixelGate.containsProductionLock(in: raster, expectedHeight: symbol.size.height))
                    XCTAssertEqual(SystemPrivacyPixelGate.isOpaquePrivacyCover(in: raster, expectedHeight: symbol.size.height), leak.isNull,
                                   "light=\(light), colored=\(colored), edge=\(leak)")
                }
            }
        }
    }

    @concurrent func testPrivacyCoverExcludesOnlyMeasuredOSIconNotAdjacentBottomPixels() async throws {
        let symbol = try XCTUnwrap(SystemPrivacyPixelGate.productionSymbol)
        let size = CGSize(width: 320, height: 480)
        let snapshot = CGRect(origin: .zero, size: size)
        let icon = CGRect(x: 140, y: 460, width: 40, height: 40)
        let exclusions = SystemPrivacyPixelGate.iconPixelBounds([icon], snapshot: snapshot,
            display: snapshot, pixelSize: size)
        XCTAssertEqual(exclusions, [icon.insetBy(dx: -1, dy: -1)])
        for leak in [CGRect.null, CGRect(x: 133, y: 470, width: 4, height: 8),
                     CGRect(x: 184, y: 470, width: 4, height: 8)] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.black.setFill(); context.fill(snapshot)
                symbol.withTintColor(.gray, renderingMode: .alwaysOriginal).draw(in: CGRect(
                    x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2,
                    width: symbol.size.width, height: symbol.size.height))
                // An OS icon's high-contrast glyph is not exposed terminal text.
                UIColor.white.setFill(); context.fill(icon)
                if !leak.isNull { UIColor.red.setFill(); context.fill(leak) }
            }
            let raster = try XCTUnwrap(image.cgImage)
            XCTAssertFalse(SystemPrivacyPixelGate.isOpaquePrivacyCover(in: raster, expectedHeight: symbol.size.height),
                           "The retained physical failure had an empty icon AX exclusion list")
            XCTAssertEqual(SystemPrivacyPixelGate.isOpaquePrivacyCover(in: raster, expectedHeight: symbol.size.height,
                excludedRects: exclusions), leak.isNull, "Pixels immediately beside the icon remain covered by the gate")
        }
        let rejected = [icon.offsetBy(dx: 50, dy: 0), icon.offsetBy(dx: 0, dy: -50),
                        CGRect(x: 0, y: 460, width: 320, height: 40)]
        XCTAssertTrue(SystemPrivacyPixelGate.iconPixelBounds(rejected, snapshot: snapshot,
            display: snapshot, pixelSize: size).isEmpty)
    }

    @concurrent func testPrivacyIconCoordinatesUseIntegralCaptureOriginNotRoundedCropScale() async {
        let display = CGRect(x: 0, y: 0, width: 744, height: 1133)
        let snapshot = CGRect(x: 459.032186419317, y: 119, width: 213.74404236540158, height: 325.5)
        let icon = CGRect(x: snapshot.midX - 15, y: snapshot.maxY - 15, width: 30, height: 30)
        let result = SystemPrivacyPixelGate.iconPixelBounds([icon], snapshot: snapshot, display: display,
            pixelSize: CGSize(width: 1488, height: 2266))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.minX ?? -1, icon.minX * 2 - 918 - 1, accuracy: 0.000001)
        XCTAssertEqual(result.first?.minY, 620)
        XCTAssertEqual(result.first?.width, 62)
        XCTAssertEqual(result.first?.height, 62)
    }

    @concurrent func testPrivacySnapshotBoundsPreserveEdgesAndExcludeOnlyTrailingOSTitle() async throws {
        // Measured full-window aspect in both retained 1488x2266 iPad captures.
        let card = CGRect(x: 918, y: 238, width: 428, height: 728)
        let snapshot = try XCTUnwrap(SystemPrivacyPixelGate.snapshotBounds(card: card,
            window: CGRect(x: 0, y: 0, width: 744, height: 1133)))
        XCTAssertEqual(snapshot.minX, card.minX)
        XCTAssertEqual(snapshot.minY, card.minY)
        XCTAssertEqual(snapshot.width, card.width)
        XCTAssertEqual(snapshot.height, 651.79, accuracy: 0.1)
        XCTAssertGreaterThan(snapshot.height / card.height, 0.89)
        XCTAssertNil(SystemPrivacyPixelGate.snapshotBounds(card: CGRect(x: 0, y: 0, width: 300, height: 100),
            window: CGRect(x: 0, y: 0, width: 744, height: 1133)))
    }

    @concurrent func testPrivacyArtworkMatcherReplaysFractionalMiniAndProWithoutAX() async throws {
        let artwork = try PrivacySwitcherFixtures.load("AppIcon")
        for fixture in PrivacySwitcherFixtures.recorded {
            let image = try fixture.image()
            let pixelSize = CGSize(width: image.width, height: image.height)
            let evidence = SystemPrivacyIconMatcher.measure(in: image, snapshot: fixture.snapshot,
                display: fixture.display, artwork: artwork)
            XCTAssertEqual(evidence.bounds, fixture.icon, evidence.description)
            let icon = SystemPrivacyIconMatcher.displayBounds(try XCTUnwrap(evidence.bounds),
                imageSize: pixelSize, display: fixture.display)
            let envelope = SystemPrivacyPixelGate.iconPixelBounds([icon], snapshot: fixture.snapshot,
                display: fixture.display, pixelSize: pixelSize)
            let exclusions = SystemPrivacyPixelGate.iconPixelExclusions(evidence, snapshot: fixture.snapshot,
                display: fixture.display, pixelSize: pixelSize)
            XCTAssertFalse(exclusions.isEmpty, evidence.description)
            let cropBounds = try XCTUnwrap(TerminalScreenshotCrop.pixelRect(region: fixture.snapshot,
                captureFrame: fixture.display, pixelSize: pixelSize))
            XCTAssertEqual(envelope, [fixture.icon.offsetBy(dx: -cropBounds.minX, dy: -cropBounds.minY)
                .insetBy(dx: -1, dy: -1)])
            let region = try XCTUnwrap(image.cropping(to: cropBounds))
            XCTAssertTrue(SystemPrivacyPixelGate.containsProductionLock(in: region, expectedHeight: fixture.lockHeight),
                SystemPrivacyPixelGate.lockEvidence(in: region, expectedHeight: fixture.lockHeight))
            XCTAssertFalse(SystemPrivacyPixelGate.isOpaquePrivacyCover(in: region, expectedHeight: fixture.lockHeight,
                roundedCornerRadius: CGFloat(region.width) * 0.06), "The original missing-AX false negative")
            XCTAssertTrue(SystemPrivacyPixelGate.isOpaquePrivacyCover(in: region, expectedHeight: fixture.lockHeight,
                roundedCornerRadius: CGFloat(region.width) * 0.06, excludedRects: exclusions))
        }
    }

    @concurrent func testPrivacyArtworkMatcherRejectsMissingWrongClippedInternalAndGlyphOnlyEvidence() async throws {
        let artwork = try PrivacySwitcherFixtures.load("AppIcon")
        for fixture in PrivacySwitcherFixtures.recorded {
            let image = try fixture.image(), icon = fixture.icon
            let missing = try PrivacySwitcherFixtures.painting(image, rect: icon, color: .black)
            let wrong = try PrivacySwitcherFixtures.painting(image, rect: icon.insetBy(dx: 10, dy: 10), color: .white)
            // Keep all in-card artwork, destroy only the informative external half.
            let external = CGRect(x: icon.minX, y: fixture.snapshot.maxY * 2,
                                  width: icon.width, height: icon.maxY - fixture.snapshot.maxY * 2)
            let noExternal = try PrivacySwitcherFixtures.painting(image, rect: external, color: .black)
            // Shipped glyphs without a full independent OS boundary cannot grant an exclusion.
            let noBoundary = try PrivacySwitcherFixtures.painting(image,
                rect: CGRect(x: icon.minX, y: icon.maxY - 2, width: icon.width, height: 2), color: .black)
            for (reason, candidate) in [("missing", missing), ("wrong", wrong),
                                         ("no external artwork", noExternal), ("glyph only", noBoundary)] {
                let evidence = SystemPrivacyIconMatcher.measure(in: candidate, snapshot: fixture.snapshot,
                    display: fixture.display, artwork: artwork)
                XCTAssertNil(evidence.bounds, "\(fixture.name) \(reason): \(evidence.description)")
            }
            let clippedHeight = icon.maxY - 4
            let clipped = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: clippedHeight)))
            let clippedDisplay = CGRect(x: 0, y: 0, width: fixture.display.width, height: clippedHeight / 2)
            XCTAssertNil(SystemPrivacyIconMatcher.measure(in: clipped, snapshot: fixture.snapshot,
                display: clippedDisplay, artwork: artwork).bounds)
            var internalSnapshot = fixture.snapshot
            internalSnapshot.size.height = icon.maxY / 2 + 4 - internalSnapshot.minY
            XCTAssertNil(SystemPrivacyIconMatcher.measure(in: image, snapshot: internalSnapshot,
                display: fixture.display, artwork: artwork).bounds, "A wholly internal terminal lookalike is not an OS icon")
        }
        let duplicate = SystemPrivacyIconMatcher.Evidence(matches: [CGRect(x: 10, y: 20, width: 30, height: 30),
            CGRect(x: 10, y: 21, width: 30, height: 30)], scores: [])
        XCTAssertNil(duplicate.bounds, "Even overlapping candidate fits are ambiguous; never pick the best fit")
    }

    @concurrent func testPrivacyArtworkMatcherRejectsAmbiguousBoundaryFixture() async throws {
        let artwork = try PrivacySwitcherFixtures.load("AppIcon")
        let display = CGRect(x: 0, y: 0, width: 500, height: 600)
        let card = CGRect(x: 20, y: 20, width: 460, height: 480)
        let inner = CGRect(x: 211, y: 461, width: 78, height: 78)
        let outer = inner.insetBy(dx: -1, dy: -1)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = try XCTUnwrap(UIGraphicsImageRenderer(size: display.size, format: format).image { context in
            UIColor.black.setFill(); context.fill(display)
            UIColor(white: 0.08, alpha: 1).setFill(); context.fill(card)
            context.cgContext.interpolationQuality = .high
            UIImage(cgImage: artwork).draw(in: inner)
            // Two independently plausible boundaries around the same artwork.
            // Both match well; selecting just the best would conceal ambiguity.
            UIColor(white: 0.04, alpha: 1).setFill()
            for x in [outer.minX, outer.maxX - 1] {
                context.fill(CGRect(x: x, y: outer.minY, width: 1, height: 39))
            }
            UIColor(white: 0.25, alpha: 1).setFill()
            for rect in [inner, outer] {
                for y in [rect.minY, rect.maxY - 1] {
                    context.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: 1))
                }
            }
        }.cgImage)
        let evidence = SystemPrivacyIconMatcher.measure(in: image, snapshot: card, display: display, artwork: artwork)
        XCTAssertGreaterThan(evidence.matches.count, 1, evidence.description)
        XCTAssertNil(evidence.bounds, evidence.description)
    }

    @concurrent func testPrivacyArtworkExclusionStillRejectsAdjacentAndEveryEdgeLeaks() async throws {
        let artwork = try PrivacySwitcherFixtures.load("AppIcon")
        for fixture in PrivacySwitcherFixtures.recorded {
            let image = try fixture.image(), icon = fixture.icon
            let pixels = CGSize(width: image.width, height: image.height)
            let cropBounds = try XCTUnwrap(TerminalScreenshotCrop.pixelRect(region: fixture.snapshot,
                captureFrame: fixture.display, pixelSize: pixels))
            let leaks = [CGRect(x: icon.minX - 5, y: icon.minY + 10, width: 2, height: 5),
                         CGRect(x: icon.maxX + 3, y: icon.minY + 10, width: 2, height: 5),
                         CGRect(x: icon.midX, y: icon.minY - 5, width: 5, height: 2),
                         CGRect(x: cropBounds.minX + 3, y: cropBounds.midY, width: 2, height: 5),
                         CGRect(x: cropBounds.maxX - 5, y: cropBounds.midY, width: 2, height: 5),
                         CGRect(x: cropBounds.midX, y: cropBounds.minY + 3, width: 5, height: 2),
                         CGRect(x: icon.maxX + 10, y: cropBounds.maxY - 5, width: 5, height: 2)]
            for color in [UIColor.red, UIColor.white] {
                for leak in leaks {
                    let candidate = try PrivacySwitcherFixtures.painting(image, rect: leak, color: color)
                    let evidence = SystemPrivacyIconMatcher.measure(in: candidate, snapshot: fixture.snapshot,
                        display: fixture.display, artwork: artwork)
                    XCTAssertEqual(evidence.bounds, icon, "No expansion toward adjacent leak \(leak)")
                    let exclusions = SystemPrivacyPixelGate.iconPixelExclusions(evidence, snapshot: fixture.snapshot,
                        display: fixture.display, pixelSize: pixels)
                    XCTAssertFalse(exclusions.isEmpty, evidence.description)
                    let region = try XCTUnwrap(candidate.cropping(to: cropBounds))
                    XCTAssertFalse(SystemPrivacyPixelGate.isOpaquePrivacyCover(in: region, expectedHeight: fixture.lockHeight,
                        roundedCornerRadius: CGFloat(region.width) * 0.06, excludedRects: exclusions), "Leak \(leak)")
                }
            }
        }
    }

    @concurrent func testPrivacyExteriorBaselineRequiresFiveFlatFullyExternalSamples() async {
        let samples = [0, 0, 1, 1, 0]
        XCTAssertEqual(SystemPrivacyIconMatcher.exteriorBaseline(samples, firstRow: 907,
            cardBottom: 889, imageHeight: 2266), 0)
        XCTAssertEqual(SystemPrivacyIconMatcher.exteriorBaseline([1, 1, 1, 1, 1], firstRow: 889,
            cardBottom: 889, imageHeight: 2266), 1)
        for invalid in [[], [0, 0, 0, 0], [0, 0, 0, 0, 0, 0], [0, 0, 2, 0, 0],
                        [0, 1, 2, 1, 0], [-1, 0, 0, 0, 0], [256, 256, 256, 256, 256]] {
            XCTAssertNil(SystemPrivacyIconMatcher.exteriorBaseline(invalid, firstRow: 907,
                cardBottom: 889, imageHeight: 2266), "No fallback for bad sample evidence \(invalid)")
        }
        for firstRow in [-1, 887, 888, 2263, Int.max] {
            XCTAssertNil(SystemPrivacyIconMatcher.exteriorBaseline(samples, firstRow: firstRow,
                cardBottom: 888.9999999999999, imageHeight: 2266), "All five pixels must be fully exterior and visible")
        }
        XCTAssertNil(SystemPrivacyIconMatcher.exteriorBaseline(samples, firstRow: 907,
            cardBottom: .nan, imageHeight: 2266))
    }

    @concurrent func testPrivacyExteriorBaselineAcceptsOneLevelNoiseWithRealFixtureHalo() async throws {
        let artwork = try PrivacySwitcherFixtures.load("AppIcon")
        for fixture in PrivacySwitcherFixtures.recorded {
            let image = try fixture.image(), icon = fixture.icon
            // Mini's real reference (1163,909) was erased by the old fixture.
            if fixture.name == "PrivacySwitcherMini" {
                XCTAssertEqual(try PrivacySwitcherFixtures.grayPixel(image, x: 1163, y: 909), 1)
                XCTAssertEqual(try PrivacySwitcherFixtures.grayPixel(image, x: 1160, y: 909), 4)
            }
            let actual = SystemPrivacyIconMatcher.measure(in: image, snapshot: fixture.snapshot,
                display: fixture.display, artwork: artwork)
            XCTAssertEqual(actual.bounds, icon)
            XCTAssertFalse(actual.opaqueRows.isEmpty, actual.description)
            let x = Int(icon.maxX) + 1, y = Int(icon.maxY) - 10
            let flat = try PrivacySwitcherFixtures.painting(image,
                rect: CGRect(x: x, y: y - 2, width: 1, height: 5), color: .black)
            let noisy = try PrivacySwitcherFixtures.painting(flat,
                rect: CGRect(x: x, y: y, width: 1, height: 1), color: UIColor(white: 1.0 / 255, alpha: 1))
            XCTAssertEqual(try PrivacySwitcherFixtures.grayPixel(flat, x: x, y: y), 0)
            XCTAssertEqual(try PrivacySwitcherFixtures.grayPixel(noisy, x: x, y: y), 1)
            let reference = SystemPrivacyIconMatcher.measure(in: flat, snapshot: fixture.snapshot,
                display: fixture.display, artwork: artwork)
            let measured = SystemPrivacyIconMatcher.measure(in: noisy, snapshot: fixture.snapshot,
                display: fixture.display, artwork: artwork)
            XCTAssertEqual(measured.bounds, reference.bounds)
            XCTAssertEqual(measured.opaqueRows, reference.opaqueRows)
            XCTAssertFalse(measured.opaqueRows.isEmpty)
        }
    }

    @concurrent func testPrivacyExteriorBaselineRejectsNonuniformFieldWithoutFallback() async throws {
        let artwork = try PrivacySwitcherFixtures.load("AppIcon")
        for fixture in PrivacySwitcherFixtures.recorded {
            let image = try fixture.image(), icon = fixture.icon
            let original = SystemPrivacyIconMatcher.measure(in: image, snapshot: fixture.snapshot,
                display: fixture.display, artwork: artwork)
            for gray in [CGFloat(2) / 255, 0.25, 1] {
                let changed = try PrivacySwitcherFixtures.painting(image,
                    rect: CGRect(x: icon.maxX + 1, y: icon.maxY - 1, width: 1, height: 1),
                    color: UIColor(white: gray, alpha: 1))
                let evidence = SystemPrivacyIconMatcher.measure(in: changed, snapshot: fixture.snapshot,
                    display: fixture.display, artwork: artwork)
                XCTAssertEqual(evidence.bounds, original.bounds)
                XCTAssertEqual(evidence.scores, original.scores)
                XCTAssertTrue(evidence.opaqueRows.isEmpty, "A median alone must not hide nonuniform exterior evidence")
                XCTAssertTrue(SystemPrivacyPixelGate.iconPixelExclusions(evidence, snapshot: fixture.snapshot,
                    display: fixture.display, pixelSize: CGSize(width: image.width, height: image.height)).isEmpty)
            }
        }
    }

    @concurrent func testPrivacyIconExclusionRejectsMissingIndependentExternalContour() async throws {
        let artwork = try PrivacySwitcherFixtures.load("AppIcon")
        for fixture in PrivacySwitcherFixtures.recorded {
            let image = try fixture.image(), icon = fixture.icon
            let original = SystemPrivacyIconMatcher.measure(in: image, snapshot: fixture.snapshot,
                display: fixture.display, artwork: artwork)
            // Erase only the external lower-left rim, not the reference glyphs,
            // central bottom highlight, or any pixel inside the selected card.
            let corner = CGRect(x: icon.minX, y: icon.maxY - icon.height / 4,
                                width: icon.width / 4, height: icon.height / 4)
            XCTAssertGreaterThan(corner.minY, fixture.snapshot.maxY * 2)
            let mutated = try PrivacySwitcherFixtures.painting(image, rect: corner, color: .black)
            let evidence = SystemPrivacyIconMatcher.measure(in: mutated, snapshot: fixture.snapshot,
                display: fixture.display, artwork: artwork)
            XCTAssertEqual(evidence.bounds, original.bounds)
            XCTAssertEqual(evidence.scores, original.scores)
            XCTAssertTrue(evidence.opaqueRows.isEmpty, "Artwork bounds alone cannot exclude a bounding square")
            XCTAssertTrue(SystemPrivacyPixelGate.iconPixelExclusions(evidence, snapshot: fixture.snapshot,
                display: fixture.display, pixelSize: CGSize(width: image.width, height: image.height)).isEmpty)
        }
    }

    @concurrent func testPrivacyRoundedIconCornersRejectExposedBrightDarkAndColoredLeaks() async throws {
        let artwork = try PrivacySwitcherFixtures.load("AppIcon")
        for fixture in PrivacySwitcherFixtures.recorded {
            let image = try fixture.image(), icon = fixture.icon
            let size = CGSize(width: image.width, height: image.height)
            let cropBounds = try XCTUnwrap(TerminalScreenshotCrop.pixelRect(region: fixture.snapshot,
                captureFrame: fixture.display, pixelSize: size))
            let baseline = SystemPrivacyIconMatcher.measure(in: image, snapshot: fixture.snapshot,
                display: fixture.display, artwork: artwork)
            let exclusions = SystemPrivacyPixelGate.iconPixelExclusions(baseline, snapshot: fixture.snapshot,
                display: fixture.display, pixelSize: size)
            XCTAssertFalse(exclusions.isEmpty, baseline.description)
            let region = try XCTUnwrap(image.cropping(to: cropBounds))
            XCTAssertTrue(SystemPrivacyPixelGate.isOpaquePrivacyCover(in: region, expectedHeight: fixture.lockHeight,
                roundedCornerRadius: CGFloat(region.width) * 0.06, excludedRects: exclusions),
                "The legitimate opaque icon artwork must still pass")
            // P1 repro: mini (1103,860), Pro (1555,1082), plus the other upper corner.
            // All three colors are below the artwork binary threshold, so the
            // original bounding-box matcher would accept the exact same match.
            let colors = [UIColor(white: 80.0 / 255, alpha: 1), UIColor.black,
                          UIColor(red: 80.0 / 255, green: 0, blue: 0, alpha: 1)]
            for x in [icon.minX + 1, icon.maxX - 5] {
                let leak = CGRect(x: x, y: icon.minY + 1, width: 4, height: 4)
                let witness = CGPoint(x: x + 0.5 - cropBounds.minX,
                                      y: leak.minY + 0.5 - cropBounds.minY)
                XCTAssertFalse(exclusions.contains { $0.contains(witness) }, "Exposed corner must be checked")
                for color in colors {
                    let mutated = try PrivacySwitcherFixtures.painting(image, rect: leak, color: color)
                    let evidence = SystemPrivacyIconMatcher.measure(in: mutated, snapshot: fixture.snapshot,
                        display: fixture.display, artwork: artwork)
                    XCTAssertEqual(evidence.bounds, baseline.bounds)
                    XCTAssertEqual(evidence.scores, baseline.scores)
                    XCTAssertEqual(evidence.opaqueRows, baseline.opaqueRows,
                        "The exclusion is measured outside the card, never from leaking pixels")
                    let mutatedExclusions = SystemPrivacyPixelGate.iconPixelExclusions(evidence,
                        snapshot: fixture.snapshot, display: fixture.display, pixelSize: size)
                    XCTAssertEqual(mutatedExclusions, exclusions)
                    let mutatedRegion = try XCTUnwrap(mutated.cropping(to: cropBounds))
                    XCTAssertFalse(SystemPrivacyPixelGate.isOpaquePrivacyCover(in: mutatedRegion,
                        expectedHeight: fixture.lockHeight, roundedCornerRadius: CGFloat(region.width) * 0.06,
                        excludedRects: mutatedExclusions), "Exposed rounded-corner leak \(fixture.name): \(leak), \(color)")
                }
            }
        }
    }

    @concurrent func testPrivacyArtworkMatcherMeasuresDifferentSizesAndLightBackground() async throws {
        let artwork = try PrivacySwitcherFixtures.load("AppIcon")
        // Different screenshot scales and non-recorded sizes prove no 60px/30pt fallback.
        for scale in [CGFloat(1), 3] {
            for size in [CGFloat(36), 78] {
                for light in [false, true] {
                    let canvas = CGSize(width: 500, height: 600)
                    let card = CGRect(x: 20, y: 20, width: 460, height: 480)
                    let icon = CGRect(x: card.midX - size / 2, y: card.maxY - size / 2, width: size, height: size)
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                    let image = try XCTUnwrap(UIGraphicsImageRenderer(size: canvas, format: format).image { context in
                        UIColor.black.setFill(); context.fill(CGRect(origin: .zero, size: canvas))
                        UIColor(white: light ? 0.92 : 0.08, alpha: 1).setFill(); context.fill(card)
                        context.cgContext.interpolationQuality = .high
                        UIImage(cgImage: artwork).draw(in: icon)
                        // Low-luminance OS-like boundary, separate from the white artwork.
                        UIColor(white: light ? 0 : 0.25, alpha: 1).setFill()
                        context.fill(CGRect(x: icon.minX, y: icon.minY, width: size, height: 1))
                        UIColor(white: 0.25, alpha: 1).setFill()
                        context.fill(CGRect(x: icon.minX, y: icon.maxY - 1, width: size, height: 1))
                    }.cgImage)
                    let display = CGRect(x: 0, y: 0, width: canvas.width / scale, height: canvas.height / scale)
                    let snapshot = card.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
                    let evidence = SystemPrivacyIconMatcher.measure(in: image, snapshot: snapshot, display: display, artwork: artwork)
                    XCTAssertEqual(evidence.bounds, icon, "scale=\(scale), light=\(light): \(evidence.description)")
                }
            }
        }
    }

    @concurrent func testPrivacyCardIdentityRejectsOtherSameLabelSceneAndMalformedBundle() async {
        let scene = "0C67C849-0C2F-4AF1-A617-A6C5B49F163B"
        XCTAssertTrue(SystemPrivacyIconMatcher.matchesSceneIdentifier("card:dev.sshapp.devicetests.SSHApp:sceneID:dev.sshapp.devicetests.SSHApp-" + scene, sceneID: scene))
        for identifier in ["card:personal:sceneID:personal-OTHER", "card:a:sceneID:b-" + scene,
                           "card::sceneID:-" + scene, "other:a:sceneID:a-" + scene] {
            XCTAssertFalse(SystemPrivacyIconMatcher.matchesSceneIdentifier(identifier, sceneID: scene))
        }
    }

    @concurrent func testPrivacyPhoneGeometryRecentersRetainedRightClipAndMirroredLeftClip() async throws {
        let display = CGRect(x: 0, y: 0, width: 440, height: 956)
        let right = CGRect(x: 337.1, y: 134.6, width: 307.2, height: 667.4)
        let left = CGRect(x: display.width - right.maxX, y: right.minY, width: right.width, height: right.height)
        for card in [right, left] {
            let drag = try XCTUnwrap(PhonePrivacyCardGeometry.drag(card: card, display: display))
            XCTAssertTrue(card.intersection(display).contains(drag.start))
            XCTAssertTrue(display.contains(drag.end))
            XCTAssertEqual(drag.start.y, drag.end.y, "Never a vertical dismissal")
            let centered = card.offsetBy(dx: drag.end.x - drag.start.x, dy: 0)
            XCTAssertTrue(display.contains(centered))
            XCTAssertEqual(centered.midX, display.midX, accuracy: 0.001)
            XCTAssertTrue(PhonePrivacyCardGeometry.madeProgress(from: card, to: centered, display: display))
            XCTAssertNil(PhonePrivacyCardGeometry.drag(card: centered, display: display))
            let shift = CGVector(dx: 83, dy: 41)
            let moved = try XCTUnwrap(PhonePrivacyCardGeometry.drag(card: card.offsetBy(dx: shift.dx, dy: shift.dy),
                display: display.offsetBy(dx: shift.dx, dy: shift.dy)))
            XCTAssertEqual(moved.start.x, drag.start.x + shift.dx, accuracy: 0.001)
            XCTAssertEqual(moved.end.x, drag.end.x + shift.dx, accuracy: 0.001)
            XCTAssertEqual(moved.start.y, drag.start.y + shift.dy, accuracy: 0.001)
        }
    }

    @concurrent func testPrivacyPhoneGeometryRejectsInvalidOversizedVerticalAndNoProgress() async {
        let display = CGRect(x: 0, y: 0, width: 440, height: 956)
        let card = CGRect(x: 337.1, y: 134.6, width: 307.2, height: 667.4)
        let invalid = [CGRect.zero, .null, .infinite,
            CGRect(x: CGFloat.nan, y: 134, width: 307, height: 667),
            CGRect(x: 10, y: 100, width: -307, height: 667),
            CGRect(x: 10, y: 100, width: 441, height: 667),
            CGRect(x: 10, y: 100, width: 307, height: 957),
            card.offsetBy(dx: 0, dy: -135), card.offsetBy(dx: 0, dy: 200),
            card.offsetBy(dx: 440, dy: 0)]
        for frame in invalid {
            XCTAssertFalse(PhonePrivacyCardGeometry.valid(card: frame, display: display), "\(frame)")
            XCTAssertNil(PhonePrivacyCardGeometry.drag(card: frame, display: display))
            XCTAssertFalse(PhonePrivacyCardGeometry.madeProgress(from: card, to: frame, display: display))
        }
        for invalidDisplay in [CGRect.zero, .null, .infinite, CGRect(x: CGFloat.nan, y: 0, width: 440, height: 956)] {
            XCTAssertNil(PhonePrivacyCardGeometry.drag(card: card, display: invalidDisplay))
        }
        XCTAssertFalse(PhonePrivacyCardGeometry.madeProgress(from: card, to: card, display: display))
        XCTAssertFalse(PhonePrivacyCardGeometry.madeProgress(from: card, to: card.offsetBy(dx: 5, dy: 0), display: display))
        XCTAssertFalse(PhonePrivacyCardGeometry.madeProgress(from: card, to: card.offsetBy(dx: -0.5, dy: 0), display: display))
    }

    /// Releases each case's large rasters before the next case allocates more.
    private func privacyRasterCase(_ body: () throws -> Void) rethrows {
        XCTAssertFalse(Thread.isMainThread, "Raster replay must not block the unit-test host's main thread")
        try autoreleasepool(invoking: body)
    }

    /// Snapshot crop sizes from a recorded iPhone simulator and iPhone device.
    private static let phoneCropSizes = [CGSize(width: 828, height: 1798), CGSize(width: 904, height: 1964)]

    private func phoneCover(size: CGSize, light: Bool = true, leak: CGRect = .null,
                            leakColor: UIColor = .red) throws -> CGImage {
        let symbol = try XCTUnwrap(SystemPrivacyPixelGate.productionSymbol)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return try XCTUnwrap(UIGraphicsImageRenderer(size: size, format: format).image { context in
            (light ? UIColor.white : UIColor.black).setFill(); context.fill(CGRect(origin: .zero, size: size))
            symbol.withTintColor(.gray, renderingMode: .alwaysOriginal).draw(in: CGRect(
                x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2,
                width: symbol.size.width, height: symbol.size.height))
            if !leak.isNull { leakColor.setFill(); context.fill(leak) }
        }.cgImage)
    }

    @concurrent func testPrivacyPhoneHasNoIconExclusionsAndRejectsAllEdgeAndIconPositionLeaks() async throws {
        let symbol = try XCTUnwrap(SystemPrivacyPixelGate.productionSymbol)
        let size = Self.phoneCropSizes[0]
        let leaks = [CGRect.null, CGRect(x: 2, y: 800, width: 4, height: 8),
            CGRect(x: 822, y: 800, width: 4, height: 8), CGRect(x: 410, y: 2, width: 8, height: 4),
            CGRect(x: 410, y: 1792, width: 8, height: 4), CGRect(x: 399, y: 1768, width: 30, height: 30)]
        for light in [false, true] {
            for colored in [false, true] {
                for leak in leaks {
                    try privacyRasterCase {
                        let image = try phoneCover(size: size, light: light, leak: leak,
                            leakColor: colored ? .red : (light ? .black : .white))
                        XCTAssertEqual(SystemPrivacyPixelGate.isOpaquePhonePrivacyCover(in: image,
                            expectedHeight: symbol.size.height), leak.isNull, "Phone never grants an icon exclusion: \(leak)")
                    }
                }
            }
        }
    }

    /// Per-row first opaque card pixel traced from recorded simulator (828x1798)
    /// and device (904x1964) captures. Rows past each table are straight sides.
    private static let recordedCornerInsets: [(size: CGSize, insets: [Int], side: Int)] = [
        (CGSize(width: 828, height: 1798), [
            414, 183, 141, 123, 113, 106, 100, 95, 91, 88, 84, 81, 79, 76, 74, 71, 69, 67, 65, 64,
            62, 60, 59, 57, 56, 54, 53, 51, 50, 49, 48, 46, 45, 44, 43, 42, 41, 40, 39, 38,
            37, 36, 35, 34, 33, 32, 31, 31, 30, 29, 28, 27, 27, 26, 25, 25, 24, 23, 23, 22,
            21, 21, 20, 20, 19, 18, 18, 17, 17, 16, 16, 15, 15, 15, 14, 14, 13, 13, 13, 12,
            12, 11, 11, 11, 10, 10, 10, 10, 9, 9, 9, 8, 8, 8, 8, 7, 7, 7, 7, 7,
            6, 6, 6, 6, 6, 6, 5, 5, 5, 5, 5, 5, 5, 4, 4, 4, 4, 4, 4, 4,
            4, 4, 4, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
            3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
            2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
            2, 2], 1),
        (CGSize(width: 904, height: 1964), [
            191, 144, 124, 113, 106, 100, 95, 91, 87, 84, 81, 78, 75, 73, 71, 69, 67, 65, 63, 61,
            59, 58, 56, 55, 53, 52, 51, 49, 48, 47, 46, 45, 43, 42, 41, 40, 39, 38, 37, 36,
            35, 34, 33, 32, 32, 31, 30, 29, 28, 27, 27, 26, 25, 24, 24, 23, 22, 22, 21, 20,
            20, 19, 19, 18, 18, 17, 17, 16, 16, 15, 15, 14, 14, 13, 13, 12, 12, 12, 11, 11,
            11, 10, 10, 10, 9, 9, 9, 8, 8, 8, 8, 7, 7, 7, 7, 6, 6, 6, 6, 6,
            5, 5, 5, 5, 5, 5, 4, 4, 4, 4, 4, 4, 4, 3, 3, 3, 3, 3, 3, 3,
            3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
            2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1, 1], 0),
    ]

    @concurrent func testPrivacyPhoneContourNeverSamplesOutsideRecordedCardShape() async {
        for recorded in Self.recordedCornerInsets {
            let width = Int(recorded.size.width), height = Int(recorded.size.height)
            for row in 0..<(height / 2) {
                let inset = row < recorded.insets.count ? recorded.insets[row] : recorded.side
                for x in 0..<inset {
                    for (px, py) in [(x, row), (width - 1 - x, row), (x, height - 1 - row), (width - 1 - x, height - 1 - row)] {
                        XCTAssertFalse(PhonePrivacySnapshotGeometry.includes(x: px, y: py, width: width, height: height),
                                       "Pixel (\(px),\(py)) is outside the recorded \(width)x\(height) card")
                    }
                }
            }
        }
    }

    @concurrent func testPrivacyPhoneContourRejectsSinglePixelLeaksAtEdgesAndCorners() async throws {
        let symbol = try XCTUnwrap(SystemPrivacyPixelGate.productionSymbol)
        // Straight edges just inside the margin, plus a diagonal point just
        // inside each rounded corner.
        for (size, corner) in zip(Self.phoneCropSizes, [56, 60]) {
            let width = Int(size.width), height = Int(size.height)
            let points = [(2, height / 2), (width - 3, height / 2), (width / 2, 2), (width / 2, height - 3),
                          (corner, corner), (width - 1 - corner, corner),
                          (corner, height - 1 - corner), (width - 1 - corner, height - 1 - corner)]
            let baseline = try phoneCover(size: size)
            XCTAssertTrue(SystemPrivacyPixelGate.isOpaquePhonePrivacyCover(in: baseline, expectedHeight: symbol.size.height))
            for (x, y) in points {
                XCTAssertTrue(PhonePrivacySnapshotGeometry.includes(x: x, y: y, width: width, height: height),
                              "(\(x),\(y)) must be checked at \(width)x\(height)")
                for color in [UIColor.red, UIColor.black] {
                    try privacyRasterCase {
                        let image = try phoneCover(size: size, leak: CGRect(x: x, y: y, width: 1, height: 1), leakColor: color)
                        XCTAssertFalse(SystemPrivacyPixelGate.isOpaquePhonePrivacyCover(in: image,
                            expectedHeight: symbol.size.height), "Single-pixel leak at (\(x),\(y)), \(width)x\(height)")
                    }
                }
            }
        }
    }

    @concurrent func testPrivacyPhoneGeometryAcceptsAnyFullScreenPhoneAndRejectsInvalidGeometry() async throws {
        for (display, scale) in [(CGRect(x: 0, y: 0, width: 402, height: 874), CGFloat(3)),
                                 (CGRect(x: 0, y: 0, width: 440, height: 956), 3),
                                 (CGRect(x: 0, y: 0, width: 375, height: 667), 2)] {
            let capture = CGSize(width: display.width * scale, height: display.height * scale)
            // Same aspect formula as snapshotBounds, so the card is exactly its snapshot.
            let cardWidth = display.width * 0.68
            let card = CGRect(x: display.width * 0.16, y: display.height * 0.15,
                              width: cardWidth, height: cardWidth * display.height / display.width)
            let snapshot = try XCTUnwrap(SystemPrivacyPixelGate.snapshotBounds(card: card, window: display))
            func valid(window: CGRect? = nil, card rawCard: CGRect? = nil, pixels: CGSize? = nil) -> Bool {
                let raw = rawCard ?? card
                guard let normalized = SystemPrivacyPixelGate.snapshotBounds(card: raw, window: window ?? display) else { return false }
                return PhonePrivacySnapshotGeometry.valid(display: display, window: window ?? display, card: raw,
                                                          snapshot: normalized, captureSize: pixels ?? capture)
            }
            XCTAssertEqual(snapshot, card)
            XCTAssertTrue(valid(), "\(display)")
            XCTAssertFalse(valid(window: display.insetBy(dx: 1, dy: 1)))
            XCTAssertFalse(valid(card: .null))
            XCTAssertFalse(valid(card: card.offsetBy(dx: display.width, dy: 0)), "Clipped card")
            XCTAssertFalse(valid(pixels: CGSize(width: capture.width, height: capture.height * 0.9)))
            XCTAssertFalse(valid(pixels: CGSize(width: CGFloat.nan, height: capture.height)))
            for extraHeight in [CGFloat(0.1), 0.5, 0.9] {
                var taller = card
                taller.size.height += extraHeight
                XCTAssertEqual(SystemPrivacyPixelGate.snapshotBounds(card: taller, window: display), card,
                    "Aspect normalization conceals the raw card's extra height")
                XCTAssertFalse(valid(card: taller), "Reject raw geometry before normalization can crop away a leak")
            }
        }
    }
}
