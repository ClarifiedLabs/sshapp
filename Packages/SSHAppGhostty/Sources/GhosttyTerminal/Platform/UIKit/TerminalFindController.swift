#if canImport(UIKit)
import GhosttyVT
import UIKit

/// A local text field, never connected to terminal text input or the remote encoder.
@MainActor
final class TerminalFindTextField: UITextField {
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let bindings: [(String, UIKeyModifierFlags, Selector)] = [
            ("f", .command, #selector(focusQuery)),
            ("g", .command, #selector(nextMatch)),
            ("g", [.command, .shift], #selector(previousMatch)),
            ("\r", [], #selector(nextMatch)),
            ("\r", .shift, #selector(previousMatch)),
            (UIKeyCommand.inputEscape, [], #selector(closeFind)),
        ]
        return bindings.map { input, modifiers, action in
            let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc func focusQuery() { becomeFirstResponder(); selectAll(nil) }
    @objc func nextMatch() { if markedTextRange == nil { onNext?() } }
    @objc func previousMatch() { if markedTextRange == nil { onPrevious?() } }
    @objc func closeFind() { onClose?() }
}

/// Owns only Sendable resources, so implicit UIKit teardown can cancel the
/// pump and admit FIFO cleanup synchronously without accessing a dying view.
private final class TerminalFindCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private let session: VTTerminalSession
    private let owner: UUID
    private var pump: Task<Void, Never>?
    private var ended = false

    init(session: VTTerminalSession, owner: UUID) {
        self.session = session
        self.owner = owner
    }

    func setPump(_ task: Task<Void, Never>) {
        lock.withLock {
            if ended { task.cancel() }
            else { pump = task }
        }
    }

    @discardableResult
    func end() -> Bool {
        lock.withLock {
            guard !ended else { return false }
            ended = true
            pump?.cancel()
            pump = nil
            // Admitted search operations are not cancelled. End follows them
            // even when UIKit skips explicit surface-detach callbacks.
            return session.enqueueEndSearch(owner: owner) != nil
        }
    }

    deinit { end() }
}

@MainActor
final class TerminalFindController: NSObject, UITextFieldDelegate {
    static let height: CGFloat = 88
    static let maximumQueryBytes = 4096
    let bar = UIView()
    let field = TerminalFindTextField()
    let status = UILabel()
    let previousButton = UIButton(type: .system)
    let nextButton = UIButton(type: .system)
    let owner: UUID
    let session: VTTerminalSession
    let restoresFocus: Bool
    weak var host: UITerminalView?
    private(set) var generation: UInt64 = 1
    private(set) var isClosed = false
    private(set) var query = ""
    private var submittedGeneration: UInt64?
    private(set) var failedGeneration: UInt64?
    private var pendingBegin: Task<Void, Error>?
    private var hasBegunSearch = false
    private var editDeadline = ContinuousClock.now
    private var direction = 0
    private(set) var canRestoreFocus = false
    private let cleanup: TerminalFindCleanup
    private var disabledGestures: [UIGestureRecognizer] = []

    init(host: UITerminalView, session: VTTerminalSession) {
        self.host = host
        self.session = session
        let owner = UUID()
        self.owner = owner
        cleanup = TerminalFindCleanup(session: session, owner: owner)
        restoresFocus = host.isFirstResponder
        super.init()
        bar.backgroundColor = .secondarySystemBackground
        bar.accessibilityIdentifier = "terminalFindBar"
        field.placeholder = "Find in terminal"
        field.accessibilityLabel = "Find in terminal"
        field.accessibilityIdentifier = "terminalFindQuery"
        field.borderStyle = .roundedRect
        field.clearButtonMode = .whileEditing
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.returnKeyType = .search
        field.delegate = self
        field.addTarget(self, action: #selector(queryEdited), for: .editingChanged)
        field.onNext = { [weak self] in self?.navigate(1) }
        field.onPrevious = { [weak self] in self?.navigate(-1) }
        field.onClose = { [weak host] in
            host?.findKeyCodes.insert(UIKeyboardHIDUsage.keyboardEscape.rawValue)
            host?.dismissFind()
        }
        status.font = .preferredFont(forTextStyle: .caption1)
        status.adjustsFontSizeToFitWidth = true
        status.minimumScaleFactor = 0.7
        status.accessibilityIdentifier = "terminalFindStatus"
        status.text = "Enter text to search"
        previousButton.setImage(UIImage(systemName: "chevron.up"), for: .normal)
        previousButton.accessibilityLabel = "Previous match"
        previousButton.addAction(UIAction { [weak self] _ in self?.navigate(-1) }, for: .touchUpInside)
        nextButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        nextButton.accessibilityLabel = "Next match"
        nextButton.addAction(UIAction { [weak self] _ in self?.navigate(1) }, for: .touchUpInside)
        setNavigationEnabled(false)
        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.addAction(UIAction { [weak host] _ in host?.dismissFind() }, for: .touchUpInside)
        let controls = UIStackView(arrangedSubviews: [status, previousButton, nextButton, done])
        controls.spacing = 8
        for button in [previousButton, nextButton, done] {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        let stack = UIStackView(arrangedSubviews: [field, controls])
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -4),
            field.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    func start() {
        guard let host, let begin = session.enqueueBeginSearch(owner: owner) else {
            host?.dismissFind(restoringFocus: false)
            return
        }
        disabledGestures = (host.gestureRecognizers ?? []).filter(\.isEnabled)
        disabledGestures.forEach { $0.isEnabled = false }
        host.addSubview(bar)
        // Keep the persisted terminal suppression policy unchanged, including
        // when Find is opened from a hardware shortcut with the keyboard hidden.
        field.inputView = host.suppressesSoftwareKeyboard ? host.inputView : nil
        host.setNeedsLayout()
        host.layoutIfNeeded()
        field.becomeFirstResponder()
        pendingBegin = begin
        cleanup.setPump(Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.advance() else { return }
                do { try await Task.sleep(for: delay) }
                catch { return }
            }
        })
    }

    @objc func queryEdited() {
        guard !isClosed else { return }
        generation &+= 1
        query = field.text ?? ""
        failedGeneration = nil
        setNavigationEnabled(false)
        direction = 0
        editDeadline = .now.advanced(by: .milliseconds(150))
        if query.utf8.count > Self.maximumQueryBytes {
            status.text = "Query exceeds 4096 UTF-8 bytes"
            status.textColor = .systemRed
        } else {
            status.text = query.isEmpty ? "Enter text to search" : "Searching…"
            status.textColor = .secondaryLabel
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        navigate(1)
        return false
    }

    func navigate(_ direction: Int) {
        guard !isClosed, nextButton.isEnabled, !query.isEmpty,
              query.utf8.count <= Self.maximumQueryBytes,
              field.markedTextRange == nil else { return }
        // Coalesce navigation while native work is outstanding; never queue an
        // unbounded number of actor operations from keyboard repeat.
        self.direction = direction
        editDeadline = .now
    }

    /// Exactly one admission is awaited at a time. Edits invalidate result UI
    /// immediately; the FIFO still completes old work before the newer query.
    private func advance() async -> Duration? {
        guard !isClosed, let host, host.findController === self,
              host.surface?.session === session else { return nil }
        guard host.findHostIsVisible else {
            host.dismissFind(restoringFocus: false)
            return nil
        }
        let requestedGeneration = generation
        // Failed native state is never stepped again. A query edit alone admits
        // a new generation, allowing recovery without a native retry loop.
        do {
            if failedGeneration == requestedGeneration {
                try await checkSessionAvailable()
                return .milliseconds(250)
            }
            return try await performAdvance(generation: requestedGeneration)
        } catch {
            if error as? VTError == .retired {
                if host.findController === self { host.dismissFind(restoringFocus: false) }
                return nil
            }
            searchFailed(error, generation: requestedGeneration)
            return .milliseconds(250)
        }
    }

    private func performAdvance(generation requestedGeneration: UInt64) async throws -> Duration {
        if !hasBegunSearch {
            let begin = pendingBegin ?? session.enqueueBeginSearch(owner: owner)
            pendingBegin = nil
            guard let begin else { throw VTError.retired }
            try await begin.value
            hasBegunSearch = true
            guard !isClosed, generation == requestedGeneration else { return .milliseconds(16) }
        }
        let isNewQuery = submittedGeneration != generation
        if isNewQuery, ContinuousClock.now < editDeadline { return .milliseconds(16) }
        let tooLong = query.utf8.count > Self.maximumQueryBytes
        let operation: Task<VTSearchResult, Error>?
        if isNewQuery {
            // Clearing native search also removes a stale highlight on an invalid query.
            operation = session.enqueueSearch(query: tooLong ? "" : query,
                owner: owner, generation: requestedGeneration)
            submittedGeneration = requestedGeneration
        } else if query.isEmpty || tooLong {
            try await checkSessionAvailable()
            return .milliseconds(250)
        } else {
            operation = session.enqueueSearchStep(owner: owner,
                generation: requestedGeneration, direction: direction)
            direction = 0
        }
        guard let operation else { throw VTError.retired }
        let value = try await operation.value
        guard !isClosed, host?.findController === self,
              requestedGeneration == generation else { return .milliseconds(16) }
        if !tooLong, !query.isEmpty {
            showResult(totalMatches: value.totalMatches, selectedIndex: value.selectedIndex,
                isComplete: value.isComplete)
        }
        // The session publishes frames only when selection/viewport changed.
        // Passive completed searches must not force a redraw every 250 ms.
        return value.isComplete && direction == 0 ? .milliseconds(250) : .milliseconds(16)
    }

    /// Empty/invalid/failed queries have no native work to step, but must still
    /// notice session retirement. This FIFO probe neither extracts nor redraws.
    private func checkSessionAvailable() async throws {
        guard let operation = session.enqueueInputQuery({ _ in () }) else { throw VTError.retired }
        try await operation.value
    }

    private func setNavigationEnabled(_ enabled: Bool) {
        previousButton.isEnabled = enabled
        nextButton.isEnabled = enabled
    }

    func showResult(totalMatches: Int, selectedIndex: Int?, isComplete: Bool) {
        if totalMatches == 0 {
            status.text = isComplete ? "No matches" : "Searching…"
        } else {
            let selected = selectedIndex.map { String($0 + 1) } ?? "0"
            status.text = "\(selected) of \(totalMatches)\(isComplete ? "" : "+")"
        }
        status.textColor = .secondaryLabel
        setNavigationEnabled(totalMatches > 0)
    }

    func searchFailed(_ error: Error, generation requestedGeneration: UInt64) {
        guard !isClosed, requestedGeneration == generation else { return }
        failedGeneration = requestedGeneration
        direction = 0
        setNavigationEnabled(false)
        // GHOSTTY_LIMIT_EXCEEDED in the pinned Ghostty VT types.h is -6.
        switch error as? VTError {
        case .native(-6): status.text = "Search memory limit reached. Edit the query to retry."
        case .searchQueryTooLong: status.text = "Query exceeds 4096 UTF-8 bytes"
        default: status.text = "Search failed. Edit the query to retry."
        }
        status.textColor = .systemRed
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        canRestoreFocus = cleanup.end()
        field.resignFirstResponder()
        bar.removeFromSuperview()
        disabledGestures.forEach { $0.isEnabled = true }
        disabledGestures.removeAll()
    }
}
#endif
