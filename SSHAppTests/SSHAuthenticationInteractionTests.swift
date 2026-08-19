import Darwin
import Foundation
import os
import XCTest
@testable import SSHApp

final class SSHAuthenticationTextTests: XCTestCase {
    func testSanitizeStripsTerminalControlsButPreservesReadableContent() {
        let input = "Header\r\n"
            + "\u{1B}[31mred\u{1B}[0m "
            + "\u{1B}]8;;https://attacker.invalid\u{7}safe link\u{1B}]8;;\u{1B}\\"
            + "\u{009B}2J"
            + "\u{0000}\u{0007}\u{007F} café\t✅"

        XCTAssertEqual(
            SSHAuthenticationText.sanitize(input),
            "Header\nred safe link café\t✅"
        )
    }

    func testTerminalTextNormalizesAllLineEndingsToCRLF() {
        XCTAssertEqual(
            SSHAuthenticationText.terminalText("one\rtwo\r\nthree\nfour"),
            "one\r\ntwo\r\nthree\r\nfour"
        )
    }

    func testUnterminatedOperatingSystemCommandCannotLeakPayload() {
        XCTAssertEqual(
            SSHAuthenticationText.sanitize("before\u{1B}]0;malicious title"),
            "before"
        )
    }

    func testSanitizeConsumesAllTerminalControlStringFamilies() {
        let input = "start"
            + "\u{1B}Pdevice-control\u{1B}\\"
            + "\u{1B}Xsos\u{009C}"
            + "\u{1B}^privacy\u{1B}\\"
            + "\u{1B}_application\u{1B}\\"
            + "\u{0090}c1-dcs\u{009C}"
            + "\u{0098}c1-sos\u{009C}"
            + "\u{009E}c1-pm\u{009C}"
            + "\u{009F}c1-apc\u{009C}end"

        XCTAssertEqual(SSHAuthenticationText.sanitize(input), "startend")
    }

    func testUnterminatedDeviceControlStringCannotLeakPayload() {
        XCTAssertEqual(
            SSHAuthenticationText.sanitize("before\u{1B}Pmalicious payload"),
            "before"
        )
    }
}

final class SSHAuthenticationNoticeTests: XCTestCase {
    func testNativeAuthenticationClockMatchesSwiftUptimeClock() {
        let swiftBefore = DispatchTime.now().uptimeNanoseconds
        let native = sshapp_uptime_nanoseconds()
        let swiftAfter = DispatchTime.now().uptimeNanoseconds

        XCTAssertGreaterThanOrEqual(native, swiftBefore)
        XCTAssertLessThanOrEqual(native, swiftAfter)
    }

    func testExpiredDeadlineDoesNotStartStoredCredentialAuthorization() async {
        let result = await BiometricCredentialAuthorizer.authorizeStoredCredentialUse(
            reason: "Test authentication deadline",
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )

        XCTAssertEqual(result, .timedOut)
    }

    func testNoticeDecodesExplicitByteRangesAndLanguage() {
        let notice = SSHAuthenticationNotice(
            messageBytes: Data([0x68, 0x69, 0x00, 0xFF]),
            languageBytes: Data("en-US".utf8)
        )

        XCTAssertEqual(notice.message, "hi\0�")
        XCTAssertEqual(notice.languageTag, "en-US")
    }

    func testEmptyNoticeLanguageBecomesNil() {
        let notice = SSHAuthenticationNotice(
            messageBytes: Data("Authenticate in your browser".utf8),
            languageBytes: Data()
        )

        XCTAssertNil(notice.languageTag)
    }

    func testDeduplicatorSuppressesRecentExactNoticesWithinBoundedCapacity() {
        var deduplicator = SSHAuthenticationNoticeDeduplicator(capacity: 2)
        let first = SSHAuthenticationNotice(message: "first", languageTag: nil)
        let second = SSHAuthenticationNotice(message: "second", languageTag: nil)
        let third = SSHAuthenticationNotice(message: "third", languageTag: nil)

        XCTAssertTrue(deduplicator.shouldDisplay(first))
        XCTAssertTrue(deduplicator.shouldDisplay(second))
        XCTAssertFalse(deduplicator.shouldDisplay(first))
        XCTAssertTrue(deduplicator.shouldDisplay(third))
        XCTAssertTrue(
            deduplicator.shouldDisplay(first),
            "A bounded deduplication window must eventually evict old notices"
        )
    }

    func testDeduplicatorResetAllowsNoticeAgain() {
        var deduplicator = SSHAuthenticationNoticeDeduplicator()
        let notice = SSHAuthenticationNotice(message: "notice", languageTag: "en")

        XCTAssertTrue(deduplicator.shouldDisplay(notice))
        XCTAssertFalse(deduplicator.shouldDisplay(notice))
        deduplicator.reset()
        XCTAssertTrue(deduplicator.shouldDisplay(notice))
    }

    func testNoticeInboxDrainsInCallbackOrderExactlyOnce() {
        let inbox = SSHAuthenticationNoticeInbox()
        let first = SSHAuthenticationNotice(message: "first", languageTag: "en")
        let second = SSHAuthenticationNotice(message: "second", languageTag: nil)

        inbox.append(first)
        inbox.append(second)

        XCTAssertEqual(inbox.drain(), [first, second])
        XCTAssertTrue(inbox.drain().isEmpty)
    }

    func testRelayCopiesBorrowedBannerBytesBeforeDelivery() {
        let received = OSAllocatedUnfairLock<SSHAuthenticationNotice?>(initialState: nil)
        let relay = SSHAuthenticationNoticeRelay(waitPolicy: .interactive) { notice in
            received.withLock { $0 = notice }
        }
        var message = Array("Continue at https://login.example.test/verify".utf8)
        var language = Array("en".utf8)

        message.withUnsafeMutableBufferPointer { messageBuffer in
            language.withUnsafeMutableBufferPointer { languageBuffer in
                relay.receive(
                    message: messageBuffer.baseAddress,
                    messageLength: messageBuffer.count,
                    language: languageBuffer.baseAddress,
                    languageLength: languageBuffer.count
                )
            }
        }
        message = Array(repeating: 0, count: message.count)
        language = Array(repeating: 0, count: language.count)

        XCTAssertEqual(
            received.withLock { $0 },
            SSHAuthenticationNotice(
                message: "Continue at https://login.example.test/verify",
                languageTag: "en"
            )
        )
    }

    func testRelayRejectsInvalidBorrowedRanges() {
        let deliveryCount = OSAllocatedUnfairLock(initialState: 0)
        let relay = SSHAuthenticationNoticeRelay(waitPolicy: .interactive) { _ in
            deliveryCount.withLock { $0 += 1 }
        }

        relay.receive(message: nil, messageLength: 1, language: nil, languageLength: 0)
        relay.receive(message: nil, messageLength: -1, language: nil, languageLength: 0)

        XCTAssertEqual(deliveryCount.withLock { $0 }, 0)
    }
}

final class SSHAuthenticationWaitTests: XCTestCase {
    func testInteractiveNoticeStartsAuthenticationWait() {
        let stream = SSHNetworkStream(ioTimeout: 0.01)
        let relay = SSHAuthenticationNoticeRelay(
            waitPolicy: .interactive,
            waitDuration: 1
        )
        relay.setStream(stream)
        stream.beginAuthenticationOperation()

        relay.beginAuthenticationInteraction()

        XCTAssertTrue(stream.isWaitingForAuthenticationInteraction)
        XCTAssertEqual(stream.finishAuthenticationOperation(), .completed)
    }

    func testNonInteractiveNoticeDoesNotExtendAuthenticationWait() {
        let stream = SSHNetworkStream(ioTimeout: 0.01)
        let relay = SSHAuthenticationNoticeRelay(
            waitPolicy: .nonInteractive,
            waitDuration: 1
        )
        relay.setStream(stream)
        stream.beginAuthenticationOperation()

        relay.beginAuthenticationInteraction()

        XCTAssertFalse(stream.isWaitingForAuthenticationInteraction)
        XCTAssertEqual(stream.finishAuthenticationOperation(), .completed)
    }

    func testInteractiveDeadlineIsBoundedAndCannotBeExtended() {
        let stream = SSHNetworkStream(ioTimeout: 1)
        stream.beginAuthenticationOperation()
        stream.beginAuthenticationWait(maximumDuration: 0.01)
        Thread.sleep(forTimeInterval: 0.03)
        stream.beginAuthenticationWait(maximumDuration: 0.2)

        var byte: UInt8 = 0
        let startedAt = Date()
        let result = withUnsafeMutableBytes(of: &byte) { buffer in
            stream.receive(into: buffer.baseAddress!, count: buffer.count)
        }
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(result, -Int(ETIMEDOUT))
        XCTAssertLessThan(elapsed, 0.1, "A later banner/challenge must not reset the first deadline")
        XCTAssertEqual(
            stream.finishAuthenticationOperation(),
            .timedOut(waitingForInteraction: true)
        )
    }

    func testInteractionDeadlineCarriesAcrossAuthenticationOperations() {
        let stream = SSHNetworkStream(ioTimeout: 1)
        let relay = SSHAuthenticationNoticeRelay(
            waitPolicy: .interactive,
            waitDuration: 0.01
        )
        relay.setStream(stream)
        stream.beginAuthenticationOperation()
        relay.beginAuthenticationInteraction()
        let deadline = relay.interactionDeadlineUptimeNanoseconds
        XCTAssertNotNil(deadline)
        XCTAssertEqual(stream.finishAuthenticationOperation(), .completed)

        Thread.sleep(forTimeInterval: 0.03)
        stream.beginAuthenticationOperation(
            interactionDeadlineUptimeNanoseconds: deadline
        )
        var byte: UInt8 = 0
        let result = withUnsafeMutableBytes(of: &byte) { buffer in
            stream.receive(into: buffer.baseAddress!, count: buffer.count)
        }

        XCTAssertEqual(result, -Int(ETIMEDOUT))
        XCTAssertEqual(
            stream.finishAuthenticationOperation(),
            .timedOut(waitingForInteraction: true)
        )
    }

    func testExpiredInteractionDeadlineRejectsSendBeforeNetworkTransmission() {
        let stream = SSHNetworkStream(ioTimeout: 10)
        stream.beginAuthenticationOperation()
        stream.beginAuthenticationWait(
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        var byte: UInt8 = 0x41

        XCTAssertEqual(stream.send(&byte, count: 1), -Int(ETIMEDOUT))
        XCTAssertEqual(
            stream.finishAuthenticationOperation(),
            .timedOut(waitingForInteraction: true)
        )
    }

    func testMonotonicInteractionTimerWakesBlockedSend() {
        let stream = SSHNetworkStream(ioTimeout: 10)
        stream.beginAuthenticationOperation()
        stream.beginAuthenticationWait(maximumDuration: 0.01)
        var byte: UInt8 = 0x41

        XCTAssertEqual(stream.send(&byte, count: 1), -Int(ETIMEDOUT))
        XCTAssertEqual(
            stream.finishAuthenticationOperation(),
            .timedOut(waitingForInteraction: true)
        )
    }

    func testInheritedInteractionDeadlineWakesSubsequentOperation() {
        let stream = SSHNetworkStream(ioTimeout: 10)
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000
        stream.beginAuthenticationOperation(
            interactionDeadlineUptimeNanoseconds: deadline
        )
        var byte: UInt8 = 0x41

        XCTAssertEqual(stream.send(&byte, count: 1), -Int(ETIMEDOUT))
        XCTAssertEqual(
            stream.finishAuthenticationOperation(),
            .timedOut(waitingForInteraction: true)
        )
    }

    func testStandardAuthenticationTimeoutIsNotReportedAsInteractionWait() {
        let stream = SSHNetworkStream(ioTimeout: 0.01)
        stream.beginAuthenticationOperation()

        var byte: UInt8 = 0
        let result = withUnsafeMutableBytes(of: &byte) { buffer in
            stream.receive(into: buffer.baseAddress!, count: buffer.count)
        }

        XCTAssertEqual(result, -Int(ETIMEDOUT))
        XCTAssertEqual(
            stream.finishAuthenticationOperation(),
            .timedOut(waitingForInteraction: false)
        )
    }

    func testStandardDeadlineDoesNotResetAcrossNativeCallbacks() {
        let stream = SSHNetworkStream(ioTimeout: 0.01)
        stream.beginAuthenticationOperation()
        stream.setBlocking(false)
        var byte: UInt8 = 0x41

        XCTAssertEqual(stream.send(&byte, count: 1), -Int(EAGAIN))
        usleep(20_000)
        XCTAssertEqual(stream.send(&byte, count: 1), -Int(ETIMEDOUT))
        XCTAssertEqual(
            stream.finishAuthenticationOperation(),
            .timedOut(waitingForInteraction: false)
        )
    }

    func testCancellationWinsOverAuthenticationTimeoutState() {
        let stream = SSHNetworkStream(ioTimeout: 0.01)
        stream.beginAuthenticationOperation()
        stream.beginAuthenticationWait(maximumDuration: 1)

        stream.cancel()

        XCTAssertEqual(stream.finishAuthenticationOperation(), .cancelled)
    }
}

final class SSHKeyboardInteractiveRoundTests: XCTestCase {
    func testRoundDecodesCompleteExplicitLengthPayload() {
        let round = SSHKeyboardInteractiveRound(
            nameBytes: Data([0x50, 0x41, 0x4D, 0x00, 0x58]),
            instructionBytes: Data("Enter both factors".utf8),
            promptBytes: [
                (text: Data("Password: ".utf8), echo: false),
                (text: Data("Verification code: ".utf8), echo: true),
            ]
        )

        XCTAssertEqual(round.name, "PAM\0X")
        XCTAssertEqual(round.instruction, "Enter both factors")
        XCTAssertNil(round.languageTag, "libssh2's callback ABI does not expose RFC 4256 language")
        XCTAssertEqual(
            round.prompts,
            [
                SSHKeyboardInteractivePrompt(text: "Password: ", echo: false),
                SSHKeyboardInteractivePrompt(text: "Verification code: ", echo: true),
            ]
        )
    }

    func testInformationalZeroPromptRoundIsPreserved() {
        let round = SSHKeyboardInteractiveRound(
            nameBytes: Data("Security notice".utf8),
            instructionBytes: Data("Approve the request on your other device.".utf8),
            promptBytes: []
        )

        XCTAssertEqual(round.name, "Security notice")
        XCTAssertEqual(round.instruction, "Approve the request on your other device.")
        XCTAssertTrue(round.prompts.isEmpty)
        XCTAssertEqual(SSHKeyboardInteractiveResult.responses([]), .responses([]))
        XCTAssertEqual(SSHKeyboardInteractiveResult.timedOut, .timedOut)
    }
}

@MainActor
final class SSHAuthenticationPromptTests: XCTestCase {
    func testCancellingTerminalPromptUnblocksWaitAndRestoresInputMode() async {
        let session = SSHSession()
        var output = Data()
        session.onDataReceived = { output.append($0) }
        let promptTask = Task {
            await session.promptForCancellableInput(
                "\u{1B}[31mVerification code:\u{1B}[0m ",
                echo: true
            )
        }
        await Task.yield()

        XCTAssertEqual(session.inputMode, .captureInteractive)
        promptTask.cancel()

        let result = await promptTask.value
        XCTAssertNil(result)
        XCTAssertEqual(session.inputMode, .normal)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "Verification code: ")
    }

    func testExpiredAuthenticationDeadlineEndsTerminalPrompt() async {
        let session = SSHSession()

        let response = await session.promptForCancellableInput(
            "Password: ",
            echo: false,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )

        XCTAssertNil(response)
        XCTAssertEqual(session.inputMode, .normal)
    }

    func testSubmittingTerminalPromptReturnsExactResponse() async {
        let session = SSHSession()
        let promptTask = Task {
            await session.promptForCancellableInput("Password: ", echo: false)
        }
        await Task.yield()

        XCTAssertEqual(session.inputMode, .capturePassword)
        session.submitAuthInput("päss\0word")

        let result = await promptTask.value
        XCTAssertEqual(result, "päss\0word")
        XCTAssertEqual(session.inputMode, .normal)
    }

    func testOnlyAuthenticationRejectionAllowsFallback() {
        XCTAssertNoThrow(
            try SSHSession().rethrowAuthenticationInfrastructureFailure(
                SSH2Error.authFailed("rejected")
            )
        )

        for error in [
            SSH2Error.authenticationTimedOut(waitingForInteraction: false),
            SSH2Error.authenticationTimedOut(waitingForInteraction: true),
            SSH2Error.keyboardInteractiveBridgeFailed("invalid round"),
            SSH2Error.socketFailed("connection reset"),
            SSH2Error.disconnected,
        ] {
            XCTAssertThrowsError(
                try SSHSession().rethrowAuthenticationInfrastructureFailure(error)
            ) { thrown in
                XCTAssertEqual(thrown as? SSH2Error, error)
            }
        }
    }
}
