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

    func testDocuSignDisplayNameFromUntrustedDomainIsStrongImpersonation() {
        let analysis = analyze(
            "DocuSign",
            "noreply.vpxyuo-united@wrightonecomm.com",
            subject: "Please review and Esignature DocuSign"
        )

        XCTAssertEqual(analysis.score, 80)
        XCTAssertEqual(analysis.riskLevel, .high)
        XCTAssertEqual(
            analysis.reason,
            "DocuSign impersonation: sender domain is not trusted"
        )
        XCTAssertEqual(analysis.claimedBrand, "DocuSign")
        XCTAssertEqual(analysis.senderDomain, "wrightonecomm.com")
        XCTAssertEqual(analysis.isTrustedBrandDomain, false)
        XCTAssertTrue(analysis.isAutoDeleteCandidate)
    }

    func testDocuSignNotificationSubjectFromUntrustedDomainIsDetected() {
        let analysis = analyze(
            "Member Service",
            "member_sercicemadison@olloum.com",
            subject: "DocuSign signature requested — please review the document"
        )

        XCTAssertEqual(analysis.score, 80)
        XCTAssertTrue(analysis.isAutoDeleteCandidate)
    }

    func testDocuSignNotificationBodyFromUntrustedDomainIsDetected() {
        let analysis = analyze(
            "Document Center",
            "notice@unrelated.example",
            body: "Docu Sign has sent you a document. Please review and sign."
        )

        XCTAssertEqual(analysis.score, 80)
        XCTAssertEqual(analysis.claimedBrand, "DocuSign")
    }

    func testLegitimateDocuSignNotificationDomainsAreTrusted() {
        for address in [
            "dse@docusign.net",
            "info@account.docusign.net",
            "notice@mail.docusign.com"
        ] {
            let analysis = analyze(
                "DocuSign",
                address,
                subject: "Please review and sign your document"
            )
            XCTAssertEqual(analysis.score, 0, address)
            XCTAssertEqual(analysis.isTrustedBrandDomain, true, address)
            XCTAssertFalse(analysis.isAutoDeleteCandidate, address)
        }
    }

    func testDocuSignLookalikeDomainIsNotTrusted() {
        let analysis = analyze(
            "DocuSign",
            "notice@docusign.com.example.net"
        )

        XCTAssertEqual(analysis.score, 80)
        XCTAssertEqual(analysis.isTrustedBrandDomain, false)
    }

    func testConversationalDocuSignMentionDoesNotClaimIdentity() {
        let analysis = analyze(
            "Vendor Newsletter",
            "news@vendor.example",
            subject: "Tools our team uses",
            body: "Our legal department sometimes uses DocuSign for contracts."
        )

        XCTAssertEqual(analysis.score, 0)
        XCTAssertNil(analysis.claimedBrand)
    }

    func testDocuSignURLDoesNotMakeUntrustedSenderLegitimate() {
        let analysis = analyze(
            "Document Center",
            "notice@untrusted.example",
            subject: "DocuSign signature requested",
            body: "Please review the document at https://www.docusign.com/example"
        )

        XCTAssertEqual(analysis.score, 80)
        XCTAssertEqual(analysis.senderDomain, "untrusted.example")
        XCTAssertEqual(analysis.isTrustedBrandDomain, false)
    }

    private func analyze(
        _ displayName: String,
        _ address: String,
        subject: String = "",
        body: String = "",
        decodedMessageText: String = ""
    ) -> BrandImpersonationAnalysis {
        BrandImpersonationAnalyzer.analyze(
            senderDisplayName: displayName,
            senderAddress: address,
            subject: subject,
            body: body,
            decodedMessageText: decodedMessageText
        )
    }
}
