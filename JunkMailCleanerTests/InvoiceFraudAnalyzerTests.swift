import XCTest
@testable import JunkMailCleaner

final class InvoiceFraudAnalyzerTests: XCTestCase {
    func testFreeMailInvoiceSignalAddsFortyPoints() {
        let analysis = analyze(
            address: "person@gmail.com",
            subject: "Invoice notice",
            body: "Your invoice lists the amount paid for this transaction."
        )

        XCTAssertEqual(analysis.score, 40)
        XCTAssertEqual(analysis.reasons, ["Invoice/payment message from free-mail account"])
    }

    func testFinancialBrandDomainMismatchAddsFiftyPoints() {
        let analysis = analyze(
            address: "billing@randomdomain.com",
            subject: "PayPal invoice",
            body: "This PayPal invoice confirms your payment and transaction."
        )

        XCTAssertEqual(analysis.score, 50)
        XCTAssertEqual(analysis.reasons, ["Financial brand/domain mismatch: PayPal"])
    }

    func testPaymentSupportPhoneCombinationAddsThirtyPoints() {
        let analysis = analyze(
            address: "billing@example.com",
            subject: "Invoice notice",
            body: "Your invoice payment was charged. Call customer support at (888) 555-1212."
        )

        XCTAssertEqual(analysis.score, 30)
        XCTAssertEqual(
            analysis.reasons,
            ["Payment message directs recipient to support phone number"]
        )
    }

    func testCombinedInvoiceFraudSignalsCapAtOneHundred() {
        let analysis = analyze(
            address: "notice@icloud.com",
            subject: "PayPal invoice",
            body: "Your PayPal invoice says the amount paid was debited. "
                + "Contact customer support at 888-555-1212 about this transaction."
        )

        XCTAssertEqual(analysis.score, 100)
        XCTAssertEqual(analysis.riskLevel, .high)
        XCTAssertEqual(analysis.reasons.count, 3)
    }

    func testStoreAcceptingPayPalIsNotFlagged() {
        let analysis = analyze(
            address: "sales@legitimatestore.com",
            subject: "Ways to pay",
            body: "Our store accepts PayPal as a payment option for every purchase and order."
        )

        XCTAssertEqual(analysis.score, 0)
    }

    func testNewsletterWithSupportPhoneIsNotFlagged() {
        let analysis = analyze(
            address: "newsletter@example.org",
            subject: "Monthly newsletter",
            body: "Questions? Call customer support at (608) 555-0199."
        )

        XCTAssertEqual(analysis.score, 0)
    }

    func testPersonalFreeMailDiscussionOfAmazonPurchaseIsNotFlagged() {
        let analysis = analyze(
            address: "normal.person@gmail.com",
            subject: "My Amazon purchase",
            body: "I wanted to ask whether my Amazon order arrived at your house."
        )

        XCTAssertEqual(analysis.score, 0)
    }

    func testLegitimatePayPalInvoiceFromApprovedDomainIsNotFlagged() {
        let analysis = analyze(
            address: "service@billing.paypal.com",
            subject: "PayPal invoice",
            body: "This PayPal invoice confirms your payment and transaction."
        )

        XCTAssertEqual(analysis.score, 0)
    }

    func testTelephoneNumberAloneNeverAddsRisk() {
        let analysis = analyze(
            address: "person@icloud.com",
            subject: "Hello",
            body: "My new telephone number is 608-555-0199."
        )

        XCTAssertEqual(analysis.score, 0)
    }

    func testOCRDerivedReasonsAreMarkedAsImageText() {
        let analysis = InvoiceFraudAnalyzer.analyze(
            senderAddress: "notice@icloud.com",
            subject: "Purchase details",
            body: "",
            imageText: "PayPal invoice. Your account was debited. Amount paid for transaction."
        )

        XCTAssertEqual(analysis.score, 90)
        XCTAssertEqual(
            analysis.reasons,
            [
                "Invoice/payment message from free-mail account (image text)",
                "Financial brand/domain mismatch: PayPal (image text)"
            ]
        )
    }

    private func analyze(
        address: String,
        subject: String,
        body: String
    ) -> InvoiceFraudAnalysis {
        InvoiceFraudAnalyzer.analyze(
            senderAddress: address,
            subject: subject,
            body: body
        )
    }
}
