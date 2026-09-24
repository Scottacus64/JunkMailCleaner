import Foundation
import XCTest
@testable import JunkMailCleaner

final class SpamHeuristicsIntegrationTests: XCTestCase {
    func testPayPalInvoiceScamFromFreeMailScoresOneHundredWithoutAutoDelete() {
        let message = makeMessage(
            senderName: "Jacob Bernice",
            senderAddress: "jacob2bernice080@icloud.com",
            subject: "Re: Thank You for Buying—Your Package Is Set",
            body: """
            PayPal Invoice
            This transaction shows an amount paid of $1248 and your account has been debited.
            Merchant: Amazon.com
            If you did not authorize this purchase, contact customer support at (888) 555-1212
            to request a refund.
            """
        )

        XCTAssertEqual(message.combinedAnalysis.score, 100)
        XCTAssertEqual(
            message.combinedAnalysis.reason,
            "Invoice/payment message from free-mail account; "
                + "Financial brand/domain mismatch: PayPal; "
                + "Payment message directs recipient to support phone number"
        )
        XCTAssertFalse(message.combinedAnalysis.isAutoDeleteCandidate)
    }

    func testRealWorldExamplesProduceExpectedScoresAndReasons() {
        let trimRX = makeMessage(
            senderName: "TrimRX",
            senderAddress: "health@dailyupgrade.space",
            subject: "A New Season. A New Goal."
        )
        XCTAssertEqual(trimRX.combinedAnalysis.score, 25)
        XCTAssertEqual(trimRX.combinedAnalysis.reason, "Generic promotional sender domain")
        XCTAssertFalse(trimRX.combinedAnalysis.isAutoDeleteCandidate)

        let edbauer = makeMessage(
            senderName: "Edbauer Shannon",
            senderAddress: "zvhdhssg@gmail.com",
            subject: "Submitted Information Has Been Processed"
        )
        XCTAssertEqual(edbauer.combinedAnalysis.score, 30)
        XCTAssertEqual(edbauer.combinedAnalysis.reason, "Random-looking free-mail username")
        XCTAssertFalse(edbauer.combinedAnalysis.isAutoDeleteCandidate)

        let aarp = makeMessage(
            senderName: "AARP Opportunity",
            senderAddress: "member@salesurge.shop",
            subject: "Refresh your routine with AARP membership"
        )
        XCTAssertEqual(aarp.combinedAnalysis.score, 60)
        XCTAssertEqual(
            aarp.combinedAnalysis.reason,
            "Generic promotional sender domain; Brand/domain mismatch: AARP"
        )
        XCTAssertFalse(aarp.combinedAnalysis.isAutoDeleteCandidate)

        let chitubox = makeMessage(
            senderName: "CHITUBOX",
            senderAddress: "marketing@chitubox.com",
            subject: "Flash Sale Returns — 3 Hours Only!"
        )
        XCTAssertEqual(chitubox.combinedAnalysis.score, 0)
        XCTAssertEqual(chitubox.combinedAnalysis.reason, "No suspicious sender-address patterns")

        let library = makeMessage(
            senderName: "Hedberg Public Library",
            senderAddress: "info@hedbergpubliclibrary.org",
            subject: "October at HPL: New Programs & Partnerships, Spooky Fun, & more!"
        )
        XCTAssertEqual(library.combinedAnalysis.score, 0)
        XCTAssertEqual(library.combinedAnalysis.reason, "No suspicious sender-address patterns")
    }

    private func makeMessage(
        senderName: String,
        senderAddress: String,
        subject: String,
        body: String = ""
    ) -> JunkMailMessage {
        JunkMailMessage(
            reference: MailMessageReference(
                accountIdentifier: "test-account",
                messageID: UUID().uuidString,
                libraryIdentifier: "test-library"
            ),
            senderName: senderName,
            senderAddress: senderAddress,
            senderAnalysis: SenderAddressAnalyzer.analyze(senderAddress),
            analyzeContent: true,
            replyTo: "",
            subject: subject,
            dateReceived: Date(timeIntervalSince1970: 0),
            body: body,
            authenticationResults: ""
        )
    }
}
