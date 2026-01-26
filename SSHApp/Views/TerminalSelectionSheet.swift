import UIKit
import GhosttyTerminal

/// Presents libghostty's long-press text-selection request as a sheet.
///
/// On touch iOS, libghostty only exposes selectable text through the
/// `TerminalSurfaceTextSelectionRequestDelegate`. We render the viewport
/// snapshot in a selectable `UITextView` (pre-selected to the long-pressed
/// word) so the user can adjust the selection and copy via the standard iOS
/// edit menu — mirroring the package's example app.
extension UITerminalView {
    func presentSelectionSheet(_ request: TerminalTextSelectionRequest) {
        guard let presenter = owningViewController else { return }

        let selectionVC = TerminalSelectionViewController(
            text: request.text,
            anchorRange: request.anchorRange
        )
        selectionVC.onDone = { [weak self] in
            _ = self?.becomeFirstResponder()
        }

        let nav = UINavigationController(rootViewController: selectionVC)
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        presenter.present(nav, animated: true)
    }

    /// Walk the responder chain to find the nearest view controller, then the
    /// top-most presented controller to present from.
    private var owningViewController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let vc = next as? UIViewController {
                var top = vc
                while let presented = top.presentedViewController {
                    top = presented
                }
                return top
            }
            responder = next
        }
        return nil
    }
}

final class TerminalSelectionViewController: UIViewController {
    private let pendingText: String
    private let pendingAnchorRange: NSRange?

    var onDone: (() -> Void)?

    private lazy var textView: UITextView = {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.accessibilityIdentifier = "terminal.selectionTextView"
        view.alwaysBounceVertical = true
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.backgroundColor = .clear
        view.textColor = .label
        view.textContainerInset = .init(top: 12, left: 12, bottom: 12, right: 12)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    init(text: String, anchorRange: NSRange?) {
        pendingText = text
        pendingAnchorRange = anchorRange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        textView.text = pendingText
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(handleDone)
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "terminal.selectionDoneButton"
        navigationItem.title = "Select Text"
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()

        let nsText = textView.text as NSString
        if let range = pendingAnchorRange, NSMaxRange(range) <= nsText.length {
            textView.selectedRange = range
            textView.scrollRangeToVisible(range)
        } else {
            textView.selectAll(nil)
        }
    }

    @objc private func handleDone() {
        dismiss(animated: true) { [weak self] in
            self?.onDone?()
        }
    }
}
