import Foundation
import XCTest
@testable import JunkMailCleaner

final class CalendarInviteFraudAnalyzerTests: XCTestCase {
    private let calendarPrefix = """
    BEGIN:VCALENDAR
    METHOD:REQUEST
    BEGIN:VEVENT
    """

    func testZohoBillingReceiptRegressionIsAutomaticDeleteCandidate() {
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
        let analysis = analyze(
            subject: "Invitation: Billing Receipt — Amount $298.99",
            calendarText: calendar
        )

        XCTAssertEqual(analysis.score, 100)
        XCTAssertEqual(analysis.riskLevel, .high)
        XCTAssertEqual(analysis.reason, "Suspicious financial calendar invitation")
        XCTAssertTrue(analysis.isAutoDeleteCandidate)
    }

    func testOrdinaryDinnerInvitationDoesNotTrigger() {
        let analysis = analyze(calendarText: calendarPrefix + "\nSUMMARY:Dinner at 6:00 PM")

        XCTAssertEqual(analysis.score, 0)
        XCTAssertNil(analysis.reason)
        XCTAssertFalse(analysis.isAutoDeleteCandidate)
    }

    func testBudgetMeetingDoesNotTrigger() {
        let analysis = analyze(calendarText: calendarPrefix + "\nSUMMARY:Quarterly budget meeting")

        XCTAssertEqual(analysis.score, 0)
    }

    func testPayPalInvoiceWithAmountIsAutomaticDeleteCandidate() {
        let analysis = analyze(calendarText: calendarPrefix + "\nSUMMARY:PayPal Invoice $499.99")

        XCTAssertEqual(analysis.score, 100)
        XCTAssertTrue(analysis.isAutoDeleteCandidate)
    }

    func testNortonRenewalWithAmountIsAutomaticDeleteCandidate() {
        let analysis = analyze(
            calendarText: calendarPrefix + "\nSUMMARY:Your Norton subscription renewal $349.99"
        )

        XCTAssertEqual(analysis.score, 100)
        XCTAssertTrue(analysis.isAutoDeleteCandidate)
    }

    func testBillingReceiptWithoutAmountIsHighRisk() {
        let analysis = analyze(calendarText: calendarPrefix + "\nSUMMARY:Billing Receipt")

        XCTAssertEqual(analysis.score, 75)
        XCTAssertEqual(analysis.riskLevel, .high)
        XCTAssertEqual(analysis.reason, "Financial content in calendar invitation")
        XCTAssertFalse(analysis.isAutoDeleteCandidate)
    }

    func testCurrencyWithoutFinancialTermsIsHighRisk() {
        let analysis = analyze(calendarText: calendarPrefix + "\nSUMMARY:$599.99")

        XCTAssertEqual(analysis.score, 75)
        XCTAssertEqual(analysis.riskLevel, .high)
        XCTAssertEqual(analysis.reason, "Currency amount in calendar invitation")
        XCTAssertFalse(analysis.isAutoDeleteCandidate)
    }

    func testFinancialTextWithoutCalendarEvidenceDoesNotTrigger() {
        let analysis = analyze(
            subject: "Your invoice",
            body: "Your payment amount is $499.99"
        )

        XCTAssertEqual(analysis.score, 0)
    }

    func testTextCalendarAttachmentIsDecodedAndUsefulFieldsAreExtracted() {
        let rawMessage = """
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="calendar-boundary"
        
        --calendar-boundary
        Content-Type: text/plain; charset=utf-8
        
        Please see the invitation.
        --calendar-boundary
        Content-Type: text/calendar; method=REQUEST; name="event.ics"
        Content-Disposition: attachment; filename="event.ics"
        Content-Transfer-Encoding: quoted-printable
        
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        SUMMARY:PayPal Invoice $499.99
        DESCRIPTION:Your account has been charged
        LOCATION:Online
        ORGANIZER:mailto:sender@example.com
        ATTENDEE:mailto:recipient@example.com
        END:VEVENT
        END:VCALENDAR
        --calendar-boundary--
        """

        let extraction = CalendarAttachmentExtractor.extract(from: rawMessage)

        XCTAssertTrue(extraction.hasCalendarPart)
        XCTAssertTrue(extraction.text.contains("BEGIN:VCALENDAR"))
        XCTAssertTrue(extraction.text.contains("METHOD:REQUEST"))
        XCTAssertTrue(extraction.text.contains("SUMMARY:PayPal Invoice $499.99"))
        XCTAssertTrue(extraction.text.contains("DESCRIPTION:Your account has been charged"))
        XCTAssertTrue(extraction.text.contains("ORGANIZER:mailto:sender@example.com"))
        XCTAssertTrue(extraction.text.contains("ATTENDEE:mailto:recipient@example.com"))

        let analysis = analyze(
            subject: "A shared event",
            calendarText: extraction.text,
            hasCalendarPart: extraction.hasCalendarPart
        )
        XCTAssertEqual(analysis.score, 100)
        XCTAssertTrue(analysis.isAutoDeleteCandidate)
    }

    func testOctetStreamICSFilenameIsRecognized() {
        let rawMessage = """
        Content-Type: application/octet-stream; name=event.ics
        Content-Disposition: attachment; filename=event.ics
        
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        SUMMARY:Billing Receipt
        END:VEVENT
        END:VCALENDAR
        """

        let extraction = CalendarAttachmentExtractor.extract(from: rawMessage)

        XCTAssertTrue(extraction.hasCalendarPart)
        XCTAssertTrue(extraction.text.contains("SUMMARY:Billing Receipt"))
    }

    private func analyze(
        subject: String = "Event details",
        body: String = "",
        calendarText: String = "",
        hasCalendarPart: Bool = false
    ) -> CalendarInviteFraudAnalysis {
        CalendarInviteFraudAnalyzer.analyze(
            subject: subject,
            body: body,
            calendarText: calendarText,
            hasCalendarPart: hasCalendarPart
        )
    }
}
