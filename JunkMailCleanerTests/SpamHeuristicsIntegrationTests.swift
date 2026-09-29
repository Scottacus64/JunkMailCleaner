import Foundation
import XCTest
@testable import JunkMailCleaner

final class SpamHeuristicsIntegrationTests: XCTestCase {
    func testImageOnlyPayPalInvoiceScamScoresOneHundredAndAutoDeletes() {
        let message = makeMessage(
            senderName: "Jacob Bernice",
            senderAddress: "jacob2bernice080@icloud.com",
            subject: "Re: Thank You for Buying—Your Package Is Set",
            imageText: """
            PayPal INVOICE
            Your account has been debited. Amount Paid for this transaction.
            Merchant: Amazon.com
            Contact Customer Support at (888) 555-1212 for a refund.
            """
        )

        XCTAssertEqual(message.combinedAnalysis.score, 100)
        XCTAssertEqual(
            message.combinedAnalysis.reason,
            "PayPal brand impersonation; "
                + "Invoice/payment message from free-mail account (image text); "
                + "Financial brand/domain mismatch: PayPal (image text); "
                + "Payment message directs recipient to support phone number (image text)"
        )
        XCTAssertTrue(message.combinedAnalysis.isAutoDeleteCandidate)
    }

    func testPayPalInvoiceScamFromFreeMailScoresOneHundredAndAutoDeletes() {
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
            "PayPal brand impersonation; "
                + "Invoice/payment message from free-mail account; "
                + "Financial brand/domain mismatch: PayPal; "
                + "Payment message directs recipient to support phone number"
        )
        XCTAssertTrue(message.combinedAnalysis.isAutoDeleteCandidate)
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

    func testZohoCalendarBillingReceiptIsHighRiskAutomaticDeleteCandidate() {
        let calendar = """
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        SUMMARY:Billing Receipt — Amount $298.99
        DESCRIPTION:Billing Receipt — Amount $298.99
        ORGANIZER:mailto:xarlesroteau@zohomail.com
        END:VEVENT
        END:VCALENDAR
        """
        let message = makeMessage(
            senderName: "Xarles",
            senderAddress: "xarlesroteau@zohomail.com",
            subject: "Invitation: Billing Receipt — Amount $298.99",
            calendarText: calendar,
            hasCalendarPart: true
        )

        XCTAssertEqual(message.calendarInviteFraudAnalysis.score, 100)
        XCTAssertEqual(message.combinedAnalysis.score, 100)
        XCTAssertEqual(message.combinedAnalysis.riskLevel, .high)
        XCTAssertTrue(message.combinedAnalysis.isAutoDeleteCandidate)
        XCTAssertTrue(
            message.combinedAnalysis.reason.contains("Suspicious financial calendar invitation")
        )
    }

    func testDocuSignImpersonationIsAutomaticDeleteCandidate() {
        let message = makeMessage(
            senderName: "Member Service",
            senderAddress: "member_sercicemadison@olloum.com",
            subject: "DocuSign signature requested — please review the document"
        )

        XCTAssertEqual(message.brandImpersonationAnalysis.score, 80)
        XCTAssertEqual(message.combinedAnalysis.score, 80)
        XCTAssertEqual(message.combinedAnalysis.riskLevel, .high)
        XCTAssertEqual(
            message.combinedAnalysis.reason,
            "DocuSign impersonation: sender domain is not trusted"
        )
        XCTAssertTrue(message.combinedAnalysis.isAutoDeleteCandidate)
    }

    func testExplicitAdvertisingMessageIsSelectedForNuke() {
        let message = makeMessage(
            senderName: "Direct Meds Support",
            senderAddress: "health@eliteupgrade.store",
            subject: "A Faster, Simpler Approach",
            decodedMessageText: """
            Try It Today
            If you wish to unsubscribe from future mailings...
            This is an advertisement.
            promotional offers
            """
        )

        XCTAssertEqual(message.commercialMessageAnalysis.score, 95)
        XCTAssertEqual(message.combinedAnalysis.riskLevel, .high)
        XCTAssertTrue(message.combinedAnalysis.isNukeCandidate)
        XCTAssertTrue(message.combinedAnalysis.isAutoDeleteCandidate)
        XCTAssertTrue(
            message.combinedAnalysis.reason.contains("Explicit advertising disclosure")
        )
        XCTAssertTrue(
            message.combinedAnalysis.reason.contains("Bulk-mail unsubscribe/opt-out language")
        )
        XCTAssertTrue(
            message.combinedAnalysis.reason.contains("Commercial call-to-action")
        )
    }

    func testUnsubscribeOnlyMessageIsNotSelectedForNuke() {
        let message = makeMessage(
            senderName: "Community Newsletter",
            senderAddress: "newsletter@example.com",
            subject: "September community news",
            decodedMessageText: "Read this month's events. Unsubscribe if you no longer want updates."
        )

        XCTAssertEqual(message.commercialMessageAnalysis.score, 15)
        XCTAssertEqual(message.combinedAnalysis.score, 15)
        XCTAssertFalse(message.combinedAnalysis.isNukeCandidate)
        XCTAssertFalse(message.combinedAnalysis.isAutoDeleteCandidate)
    }

    func testExistingNonCommercialRiskRemainsSelectedForNuke() {
        let message = makeMessage(
            senderName: "TrimRX",
            senderAddress: "health@dailyupgrade.space",
            subject: "Monthly information",
            decodedMessageText: "Unsubscribe"
        )

        XCTAssertEqual(message.senderAnalysis.score, 25)
        XCTAssertTrue(message.combinedAnalysis.isNukeCandidate)
    }

    func testMsnPhoneChangeImpersonationIsSelectedForNuke() {
        let message = makeMessage(
            senderName: "Msn Changed Request",
            senderAddress: "dorothyiryatesburgman@pentzero.com",
            subject: "Phone Number Changed Request on 2026-09-27",
            decodedMessageText: """
            Microsoft
            Update Request
            Someone submitted a request to change your phone number.
            Not you? Reject it. REJECT IT
            """
        )

        XCTAssertEqual(message.microsoftImpersonationAnalysis.score, 95)
        XCTAssertEqual(message.combinedAnalysis.riskLevel, .high)
        XCTAssertTrue(message.combinedAnalysis.isAutoDeleteCandidate)
        XCTAssertTrue(message.combinedAnalysis.isNukeCandidate)
        XCTAssertEqual(
            message.combinedAnalysis.reason,
            "Microsoft account/security impersonation: sender domain is not approved"
        )
    }

    func testAlibabaOrderImpersonationIsSelectedForNuke() {
        let message = makeMessage(
            senderName: "Sales",
            senderAddress: "sales086@sabeng.it",
            subject: "RE: RE: Invoice & Signed Contract -NEW ORDER-088408",
            decodedMessageText: """
            Alibaba.com
            Alibaba.com Trade Center
            New order inquiry
            View Inquiry
            View Buyer Information
            """
        )

        XCTAssertEqual(message.brandImpersonationAnalysis.score, 100)
        XCTAssertEqual(message.combinedAnalysis.riskLevel, .high)
        XCTAssertEqual(message.combinedAnalysis.reason, "Alibaba brand impersonation")
        XCTAssertTrue(message.combinedAnalysis.isAutoDeleteCandidate)
        XCTAssertTrue(message.combinedAnalysis.isNukeCandidate)
    }

    private func makeMessage(
        senderName: String,
        senderAddress: String,
        subject: String,
        body: String = "",
        imageText: String = "",
        calendarText: String = "",
        hasCalendarPart: Bool = false,
        decodedMessageText: String = ""
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
            authenticationResults: "",
            imageText: imageText,
            calendarText: calendarText,
            hasCalendarPart: hasCalendarPart,
            decodedMessageText: decodedMessageText
        )
    }
}
