import XCTest
@testable import JunkMailCleaner

final class BrandImpersonationAnalyzerTests: XCTestCase {
    func testAARPDisplayNameFromUnrelatedDomainIsDetected() {
        let analysis = analyze("AARP Opportunity", "member@salesurge.shop")

        XCTAssertEqual(analysis.score, 60)
        XCTAssertEqual(analysis.riskLevel, .medium)
        XCTAssertEqual(analysis.reason, "Brand/domain mismatch: AARP")
    }

    func testAARPDisplayNameFromAllowedDomainIsNotDetected() {
        let analysis = analyze("AARP", "something@aarp.org")

        XCTAssertEqual(analysis.score, 0)
        XCTAssertNil(analysis.reason)
    }

    func testMicrosoftDisplayNameFromAllowedDomainIsNotDetected() {
        let analysis = analyze("Microsoft Account Team", "sender@microsoft.com")

        XCTAssertEqual(analysis.score, 0)
        XCTAssertNil(analysis.reason)
    }

    func testMicrosoftDisplayNameFromUnrelatedDomainIsDetected() {
        let analysis = analyze("Microsoft Account Team", "sender@randomdomain.com")

        XCTAssertEqual(analysis.score, 60)
        XCTAssertEqual(analysis.reason, "Brand/domain mismatch: Microsoft")
    }

    func testBrandNameInSubjectIsIrrelevantToDisplayNameAnalysis() {
        let analysis = analyze("Ordinary Sender", "sender@randomdomain.com")

        XCTAssertEqual(analysis.score, 0)
        XCTAssertNil(analysis.claimedBrand)
    }

    func testAllowedSubdomainMatchesButLookalikeDomainDoesNot() {
        XCTAssertEqual(analyze("AARP", "news@mail.aarp.org").score, 0)
        XCTAssertEqual(analyze("AARP", "news@aarp-membership.example.com").score, 60)
        XCTAssertEqual(analyze("PayPal", "notice@paypal.example.net").score, 60)
    }

    func testKnownGoodDisplayNamesAndAddressesReceiveNoBrandRisk() {
        XCTAssertEqual(analyze("CHITUBOX", "marketing@chitubox.com").score, 0)
        XCTAssertEqual(
            analyze("Hedberg Public Library", "info@hedbergpubliclibrary.org").score,
            0
        )
    }

    func testGeekSquadDisplayNameFromUnrelatedDomainIsDetected() {
        let analysis = analyze("Geek Squad Support", "billing@randomdomain.com")

        XCTAssertEqual(analysis.score, 60)
        XCTAssertEqual(analysis.reason, "Brand/domain mismatch: Geek Squad")
    }

    func testGeekSquadDisplayNameFromApprovedDomainsIsNotDetected() {
        XCTAssertEqual(analyze("Geek Squad", "service@geeksquad.com").score, 0)
        XCTAssertEqual(analyze("Geek Squad Support", "notice@mail.bestbuy.com").score, 0)
    }

    private func analyze(
        _ displayName: String,
        _ address: String
    ) -> BrandImpersonationAnalysis {
        BrandImpersonationAnalyzer.analyze(
            senderDisplayName: displayName,
            senderAddress: address
        )
    }
}
