import XCTest
@testable import JunkMailCleaner

final class SenderAddressAnalyzerTests: XCTestCase {
    private struct DomainTestCase {
        let address: String
        let domainSyntaxPasses: Bool
        let tldSyntaxPasses: Bool
        let tldIsKnown: Bool
        let riskPoints: Int
        let reason: String?
    }

    func testLongRandomAlphanumericDomainScoresAtLeastNinety() {
        let analysis = SenderAddressAnalyzer.analyze(
            "URFZ1GY@UGE705SA7RKFRSGUP02H4U4BFD7P.com"
        )

        XCTAssertEqual(analysis.riskLevel, .high)
        XCTAssertGreaterThanOrEqual(analysis.score, 90)
        XCTAssertTrue(analysis.isAutoDeleteCandidate)
    }

    func testStructurallyNormalDomainRemainsLowRisk() {
        let analysis = SenderAddressAnalyzer.analyze("theupside@kingoperating.com")

        XCTAssertEqual(analysis.riskLevel, .low)
        XCTAssertFalse(analysis.isAutoDeleteCandidate)
    }

    func testDomainAndTLDSyntaxCases() {
        let cases = [
            DomainTestCase(address: "info@printables.com", domainSyntaxPasses: true, tldSyntaxPasses: true, tldIsKnown: true, riskPoints: 0, reason: nil),
            DomainTestCase(address: "sales@example.shop", domainSyntaxPasses: true, tldSyntaxPasses: true, tldIsKnown: true, riskPoints: 0, reason: nil),
            DomainTestCase(address: "user@example.xyz", domainSyntaxPasses: true, tldSyntaxPasses: true, tldIsKnown: true, riskPoints: 0, reason: nil),
            DomainTestCase(address: "contact@example.photography", domainSyntaxPasses: true, tldSyntaxPasses: true, tldIsKnown: true, riskPoints: 0, reason: nil),
            DomainTestCase(address: "person@example.de", domainSyntaxPasses: true, tldSyntaxPasses: true, tldIsKnown: true, riskPoints: 0, reason: nil),
            DomainTestCase(address: "junk@example.c0m", domainSyntaxPasses: true, tldSyntaxPasses: false, tldIsKnown: false, riskPoints: 55, reason: "Domain has malformed TLD"),
            DomainTestCase(address: "junk@example.x", domainSyntaxPasses: true, tldSyntaxPasses: false, tldIsKnown: false, riskPoints: 55, reason: "Domain has malformed TLD"),
            DomainTestCase(address: "junk@example.", domainSyntaxPasses: false, tldSyntaxPasses: false, tldIsKnown: false, riskPoints: 60, reason: "Domain has malformed TLD"),
            DomainTestCase(address: "junk@example", domainSyntaxPasses: false, tldSyntaxPasses: false, tldIsKnown: false, riskPoints: 60, reason: "Domain has malformed TLD"),
            DomainTestCase(address: "junk@subdomain..com", domainSyntaxPasses: false, tldSyntaxPasses: true, tldIsKnown: true, riskPoints: 55, reason: "Domain contains malformed characters")
        ]

        for testCase in cases {
            let domain = String(testCase.address.split(separator: "@", maxSplits: 1)[1])
            let syntax = SenderAddressAnalyzer.analyzeDomainSyntax(domain)
            let analysis = SenderAddressAnalyzer.analyze(testCase.address)

            XCTAssertEqual(syntax.domainSyntaxPasses, testCase.domainSyntaxPasses, testCase.address)
            XCTAssertEqual(syntax.tldSyntaxPasses, testCase.tldSyntaxPasses, testCase.address)
            XCTAssertEqual(syntax.isKnownPublicTLD, testCase.tldIsKnown, testCase.address)
            XCTAssertEqual(syntax.riskPoints, testCase.riskPoints, testCase.address)
            XCTAssertEqual(syntax.reason, testCase.reason, testCase.address)
            XCTAssertEqual(analysis.score, testCase.riskPoints, testCase.address)
            XCTAssertEqual(
                analysis.reason,
                testCase.reason ?? "No suspicious sender-address patterns",
                testCase.address
            )
        }
    }

    func testSyntacticallyValidUnknownTLDAddsNoRisk() {
        let syntax = SenderAddressAnalyzer.analyzeDomainSyntax("example.notregisteredtld")
        let analysis = SenderAddressAnalyzer.analyze("user@example.notregisteredtld")

        XCTAssertTrue(syntax.domainSyntaxPasses)
        XCTAssertTrue(syntax.tldSyntaxPasses)
        XCTAssertEqual(syntax.isKnownPublicTLD, false)
        XCTAssertEqual(syntax.riskPoints, 0)
        XCTAssertNil(syntax.reason)
        XCTAssertEqual(analysis.riskLevel, .low)
        XCTAssertEqual(analysis.score, 0)
    }

    func testAdditionalModernAndCountryCodeTLDsAreKnown() {
        for tld in ["email", "solutions", "museum", "technology", "online", "uk", "ca", "jp", "us"] {
            let syntax = SenderAddressAnalyzer.analyzeDomainSyntax("example.\(tld)")

            XCTAssertTrue(syntax.domainSyntaxPasses, tld)
            XCTAssertTrue(syntax.tldSyntaxPasses, tld)
            XCTAssertEqual(syntax.isKnownPublicTLD, true, tld)
            XCTAssertEqual(syntax.riskPoints, 0, tld)
        }
    }
}
