import Foundation
import UIKit

/// Validates and opens web links requested by a terminal surface.
///
/// Terminal output is untrusted and OSC 8 hyperlinks can name arbitrary
/// schemes, so the app deliberately limits external activation to HTTP(S).
@MainActor
enum TerminalLinkOpener {
    static func httpURL(from value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    @discardableResult
    static func open(
        _ value: String,
        using opener: (URL) -> Void = { url in
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    ) -> Bool {
        guard let url = httpURL(from: value) else { return false }
        opener(url)
        return true
    }
}
