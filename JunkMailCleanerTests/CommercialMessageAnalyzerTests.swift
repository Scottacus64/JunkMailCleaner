import XCTest
@testable import JunkMailCleaner

final class CommercialMessageAnalyzerTests: XCTestCase {
    func testExplicitAdvertisementExampleCombinesAllIndicators() {
        let analysis = CommercialMessageAnalyzer.analyze(
            decodedBodyText: """
            A Faster, Simpler Approach
            Try It Today
            If you wish to unsubscribe from future mailings, use this link.
            This is an advertisement.
            Learn about future promotional offers.
            """
        )

        XCTAssertEqual(analysis.score, 95)
        XCTAssertEqual(analysis.riskLevel, .high)
        XCTAssertEqual(
            analysis.reason,
            "Explicit advertising disclosure; "
                + "Bulk-mail unsubscribe/opt-out language; "
                + "Commercial call-to-action"
        )
        XCTAssertEqual(analysis.indicators.map(\.score), [70, 15, 10])
        XCTAssertTrue(analysis.hasExplicitAdvertisingDisclosure)
        XCTAssertTrue(analysis.isAutoDeleteCandidate)
    }

    func testDisclosureMatchingToleratesCaseWhitespaceAndPunctuation() {
        for body in [
            "THIS IS A PAID ADVERTISEMENT!",
            "This... is -- an advertisement.",
            "This message\n is an advertisement"
        ] {
            let analysis = CommercialMessageAnalyzer.analyze(decodedBodyText: body)
            XCTAssertEqual(analysis.score, 70, body)
            XCTAssertTrue(analysis.hasExplicitAdvertisingDisclosure, body)
        }
    }

    func testLegitimateNewsletterWithOnlyUnsubscribeIsSupportingOnly() {
        let analysis = CommercialMessageAnalyzer.analyze(
            decodedBodyText: "Monthly library news. Unsubscribe if you no longer want updates."
        )

        XCTAssertEqual(analysis.score, 15)
        XCTAssertEqual(analysis.riskLevel, .low)
        XCTAssertEqual(analysis.reason, "Bulk-mail unsubscribe/opt-out language")
        XCTAssertTrue(analysis.hasOnlySupportingEvidence)
        XCTAssertFalse(analysis.isAutoDeleteCandidate)
    }

    func testTransactionalViewOrderPhraseDoesNotScore() {
        let analysis = CommercialMessageAnalyzer.analyze(
            decodedBodyText: "Your purchase has shipped. View order or track package for details."
        )

        XCTAssertEqual(analysis.score, 0)
        XCTAssertNil(analysis.reason)
    }

    func testMailingListUnsubscribeWithoutSalesLanguageIsSupportingOnly() {
        let analysis = CommercialMessageAnalyzer.analyze(
            decodedBodyText: "You are receiving this email because you joined the list. Unsubscribe."
        )

        XCTAssertEqual(analysis.score, 15)
        XCTAssertEqual(analysis.indicators.count, 1)
        XCTAssertFalse(analysis.isAutoDeleteCandidate)
    }

    func testMultipleBulkPhrasesAreCappedAtOneCategory() {
        let analysis = CommercialMessageAnalyzer.analyze(
            decodedBodyText: "Unsubscribe. Opt out of promotional emails and marketing communications."
        )

        XCTAssertEqual(analysis.score, 15)
        XCTAssertEqual(analysis.indicators.count, 1)
        XCTAssertGreaterThan(analysis.indicators[0].matches.count, 1)
    }

    func testCommercialCallToActionAloneIsSupportingOnly() {
        let analysis = CommercialMessageAnalyzer.analyze(decodedBodyText: "Shop Now")

        XCTAssertEqual(analysis.score, 10)
        XCTAssertTrue(analysis.hasOnlySupportingEvidence)
        XCTAssertFalse(analysis.isAutoDeleteCandidate)
    }
}
