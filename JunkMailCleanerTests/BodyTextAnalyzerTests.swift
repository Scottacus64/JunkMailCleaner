import XCTest
@testable import JunkMailCleaner

final class BodyTextAnalyzerTests: XCTestCase {
    func testRepeatedObfuscationWithProtectedTermsScoresHigh() {
        let body = """
        There is eviden_ce that someone gained unauthorized @ccess to your P@_yP@l account.
        Ple@se call us to c@ncel the Trans@ction and Obtain a re_fund.
        The pr0duct is an Am@zon E-Gift_Card.
        """

        let analysis = BodyTextAnalyzer.analyze(body)

        XCTAssertEqual(analysis.score, 80)
        XCTAssertEqual(analysis.riskLevel, .high)
        XCTAssertTrue(analysis.isAutoDeleteCandidate)
        XCTAssertEqual(analysis.suspiciousTokens.count, 10)
        XCTAssertEqual(analysis.protectedTokens.count, 5)
        XCTAssertTrue(analysis.reason?.contains("10 found") == true)
        XCTAssertTrue(analysis.reason?.contains("P@_yP@l") == true)
    }

    func testEmailInvoiceAndCurrencyAreNotObfuscation() {
        let analysis = BodyTextAnalyzer.analyze(
            "Please email support@apple.com regarding invoice 12345 for $399.99."
        )

        XCTAssertEqual(analysis.score, 0)
        XCTAssertEqual(analysis.riskLevel, .low)
        XCTAssertFalse(analysis.isAutoDeleteCandidate)
        XCTAssertTrue(analysis.suspiciousTokens.isEmpty)
    }

    func testEmailAddressAndFilenameAreNotObfuscation() {
        let analysis = BodyTextAnalyzer.analyze(
            "My email is john.smith@gmail.com and the file is invoice_2026.pdf."
        )

        XCTAssertEqual(analysis.score, 0)
        XCTAssertTrue(analysis.suspiciousTokens.isEmpty)
    }

    func testOrdinaryMisspellingsAreNotObfuscation() {
        let analysis = BodyTextAnalyzer.analyze("I recieve seperate messages teh same day.")

        XCTAssertEqual(analysis.score, 0)
    }

    func testURLsTimesDatesModelsAndPartNumbersAreNotObfuscation() {
        let analysis = BodyTextAnalyzer.analyze(
            "Visit https://example.com or www.example.com at 10:30 on September 23, 2026 for model MK4S, part A-20095."
        )

        XCTAssertEqual(analysis.score, 0)
        XCTAssertTrue(analysis.suspiciousTokens.isEmpty)
    }

    func testSingleObfuscatedProtectedWordIsWeakEvidence() {
        let analysis = BodyTextAnalyzer.analyze("The item was P@id yesterday.")

        XCTAssertEqual(analysis.score, 20)
        XCTAssertEqual(analysis.riskLevel, .low)
        XCTAssertFalse(analysis.isAutoDeleteCandidate)
    }

    func testAdditionalRequestedObfuscationsAreDetected() {
        let analysis = BodyTextAnalyzer.analyze(
            "P@Y.P@L Inv0ice Sale_s Reg@rding toll_free"
        )

        XCTAssertEqual(analysis.suspiciousTokens.count, 5)
        XCTAssertEqual(analysis.protectedTokens.count, 2)
        XCTAssertEqual(analysis.score, 60)
        XCTAssertEqual(analysis.riskLevel, .medium)
    }

    func testCumulativeTokenScoreTiers() {
        XCTAssertEqual(BodyTextAnalyzer.analyze("Ple@se").score, 5)
        XCTAssertEqual(BodyTextAnalyzer.analyze("Ple@se eviden_ce").score, 15)
        XCTAssertEqual(
            BodyTextAnalyzer.analyze("Ple@se eviden_ce @ccess pr0duct").score,
            30
        )
        XCTAssertEqual(
            BodyTextAnalyzer.analyze(
                "Ple@se eviden_ce @ccess pr0duct Sale_s Reg@rding toll_free"
            ).score,
            50
        )
    }
}
