import Foundation
import XCTest

/// Small standalone source contracts for the UIKit-to-VT boundary. Runtime
/// mode/byte behavior is covered by VTTerminalInputRouterTests.
final class UIKitVTInputContractTests: XCTestCase {
    private func source(_ file: String) throws -> String {
        try readSourceFile("Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/" + file)
    }

    func testZoomAndCompositionAreInterceptedBeforeNativeKeyDelivery() throws {
        let text = try source("UIKit/UITerminalView+Keyboard.swift")
        let send = try XCTUnwrap(text.range(of: "_ = surface.sendKey("))
        for interception in ["if let handled = handleLocalHardwareKey",
                             "guard !inputHandler.hasMarkedText else { return false }"] {
            let range = try XCTUnwrap(text.range(of: interception))
            XCTAssertLessThan(range.lowerBound, send.lowerBound)
        }
        let localActions = try source("UIKit/TerminalLocalKeyActions.swift")
        XCTAssertTrue(localActions.contains("if action == .release"))
        XCTAssertTrue(localActions.contains("else if held.action.repeats"))
        XCTAssertTrue(text.contains("hid: UInt16(key.keyCode.rawValue)"))
        XCTAssertTrue(text.contains("nativeInteraction.hardwareModifiersChanged(to: filteredModifierFlags)"))
        XCTAssertTrue(text.contains("self.handleKeyPress(key, action: .repeatPress)"))
        XCTAssertTrue(text.contains("case .repeatPress, .release:"))
    }

    func testExplicitPasteUsesSynchronousAdmissionAndUnsafeConfirmation() throws {
        let text = try source("UIKit/UITerminalView+InputAccessory.swift")
        let enqueue = try XCTUnwrap(text.range(of: "surface.session.enqueueInput(.paste(text, allowUnsafe: allowUnsafe))"))
        let task = try XCTUnwrap(text.range(of: "Task { @MainActor"))
        XCTAssertLessThan(enqueue.lowerBound, task.lowerBound)
        XCTAssertTrue(text.contains("catch VTError.unsafePaste"))
        XCTAssertTrue(text.contains("self.confirmUnsafePaste(text)"))
        XCTAssertTrue(text.contains("UIAlertAction(title: \"Cancel\""))
        XCTAssertTrue(text.contains("self.enqueuePastedText(text, allowUnsafe: true)"))
        XCTAssertTrue(text.contains("reportPasteFailure("))
        XCTAssertTrue(text.contains("self.surface === originalSurface"))
    }

    func testIMEKeepsUTF16StateAndSoftwareInputSuppression() throws {
        let handler = try source("UIKit/TerminalTextInputHandler@UIKit.swift")
        XCTAssertTrue(handler.contains("markedTextState.setMarkedText(text, selectedRange: selectedRange)"))
        XCTAssertTrue(handler.contains("view.surface?.preedit(text)"))
        XCTAssertTrue(handler.contains("view.surface?.sendText(committedText)"))
        let input = try source("UIKit/UITerminalView+UITextInput.swift")
        XCTAssertTrue(input.contains("hardwareTextInputSuppressedKeyCodes.isEmpty"))
        XCTAssertTrue(input.contains("inputHandler.deleteBackwardInMarkedText()"))
        XCTAssertTrue(input.contains("action: .release"))
    }

    func testHardwareKeysUseVTAdmission() throws {
        let keyboard = try source("UIKit/UITerminalView+Keyboard.swift")
        XCTAssertTrue(keyboard.contains("_ = surface.sendKey("))
        XCTAssertTrue(keyboard.contains("hid: UInt16(key.keyCode.rawValue)"))
        let surface = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Surface/TerminalSurface.swift"
        )
        XCTAssertTrue(surface.contains("session.enqueueInput(.key(VTKey("))
    }
}
