//
//  TerminalFontSettings.swift
//  SSHApp
//
//  Terminal font choices and bundled font registration.
//

import CoreText
import Foundation
import UIKit

enum TerminalFontFamily: String, CaseIterable, Identifiable, Sendable {
    case jetBrainsMono = "JetBrains Mono"
    case menlo = "Menlo"
    case courierNew = "Courier New"

    static let defaultChoice: TerminalFontFamily = .jetBrainsMono

    var id: String { rawValue }

    var displayName: String { rawValue }

    var ghosttyFontFamily: String { rawValue }

    static func resolve(_ rawValue: String?) -> TerminalFontFamily {
        guard let rawValue,
              let font = allCases.first(where: { $0.rawValue == rawValue })
        else { return defaultChoice }
        return font
    }
}

enum TerminalFontSize {
    /// Device-dependent default: 8 pt fits ~80 columns of JetBrains Mono on a
    /// standard-width iPhone; iPads have room for a larger, more legible size.
    @MainActor static var defaultValue: Double {
        UIDevice.current.userInterfaceIdiom == .pad ? 12 : 8
    }

    static let range: ClosedRange<Double> = 2 ... 48
    static let step: Double = 1

    static func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static func displayString(_ value: Double) -> String {
        "\(Int(clamped(value).rounded())) pt"
    }
}

@MainActor
enum TerminalFontRegistrar {
    private static var didRegisterBundledFonts = false

    private static let bundledFonts = [
        ("JetBrainsMono-Regular", "ttf"),
        ("JetBrainsMono-Bold", "ttf"),
        ("JetBrainsMono-Italic", "ttf"),
        ("JetBrainsMono-BoldItalic", "ttf"),
    ]

    static func registerBundledFonts(bundle: Bundle = .main) {
        guard !didRegisterBundledFonts else { return }
        didRegisterBundledFonts = true

        for font in bundledFonts {
            guard let url = bundle.url(
                forResource: font.0,
                withExtension: font.1,
                subdirectory: "Fonts"
            ) ?? bundle.url(forResource: font.0, withExtension: font.1)
            else { continue }
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
