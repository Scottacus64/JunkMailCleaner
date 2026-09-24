import XCTest
@testable import JunkMailCleaner

final class BitcoinDetectionTests: XCTestCase {
    func testBitcoinInSubjectBecomesCandidate() {
        assertRejected(subject: "Your Bitcoin payment is ready")
    }

    func testBitCoinInBodyBecomesCandidate() {
        assertRejected(body: "Send the requested amount using bit coin today.")
    }

    func testBitcoinInSenderDisplayNameBecomesCandidate() {
        assertRejected(senderDisplayName: "Bitcoin Support")
    }

    func testBitcoinInSenderAddressBecomesCandidate() {
        assertRejected(fromAddress: "bitcoin-notice@example.com")
    }

    private func assertRejected(
        senderDisplayName: String = "Example Sender",
        fromAddress: String = "sender@example.com",
        subject: String = "Ordinary subject",
        body: String = "Ordinary message"
    ) {
        let analysis = MessageContentAnalyzer.analyze(
            senderDisplayName: senderDisplayName,
            fromAddress: fromAddress,
            replyTo: "",
            subject: subject,
            body: body
        )

        XCTAssertEqual(analysis.score, 100)
        XCTAssertEqual(analysis.riskLevel, .high)
        XCTAssertTrue(analysis.isAutoDeleteCandidate)
        XCTAssertEqual(analysis.reason, "Contains Bitcoin reference")
    }
}
