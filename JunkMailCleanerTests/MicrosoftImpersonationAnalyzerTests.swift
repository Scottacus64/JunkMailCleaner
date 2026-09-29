import XCTest
@testable import JunkMailCleaner

final class MicrosoftImpersonationAnalyzerTests: XCTestCase {
    func testMicrosoftAccountFromUnapprovedDomainIsHighRisk() {
        let analysis = analyze(
            displayName: "Microsoft Account",
            address: "security@random-domain.xyz"
        )

        XCTAssertEqual(analysis.riskLevel, .high)
        XCTAssertEqual(analysis.score, 95)
        XCTAssertEqual(
            analysis.reason,
            "Microsoft account/security impersonation: sender domain is not approved"
        )
    }

    func testMicrosoftSecurityFromRandomDomainIsHighRisk() {
        let analysis = analyze(
            displayName: "Microsoft Security",
            address: "alerts@randomletters123.com"
        )

        XCTAssertEqual(analysis.riskLevel, .high)
        XCTAssertTrue(analysis.claimsMicrosoftIdentity)
    }

    func testSubjectMentionAloneDoesNotClaimMicrosoftIdentity() {
        let analysis = analyze(
            displayName: "John Smith",
            address: "john@example.com",
            subject: "Question about my Microsoft account"
        )

        XCTAssertFalse(analysis.claimsMicrosoftIdentity)
        XCTAssertEqual(analysis.riskLevel, .low)
        XCTAssertEqual(analysis.score, 0)
    }

    func testDisplayNameAloneDoesNotTriggerWithoutAccountSecurityAction() {
        let analysis = analyze(
            displayName: "Microsoft",
            address: "events@unrelated.example",
            subject: "Join our developer conference"
        )

        XCTAssertFalse(analysis.claimsMicrosoftIdentity)
        XCTAssertEqual(analysis.score, 0)
    }

    func testAccountActionAloneDoesNotTriggerWithoutMicrosoftIdentity() {
        let analysis = analyze(
            displayName: "Neighborhood Association",
            address: "notices@example.org",
            subject: "Phone number changed request"
        )

        XCTAssertFalse(analysis.claimsMicrosoftIdentity)
        XCTAssertEqual(analysis.score, 0)
    }

    func testTargetMsnPhoneChangeRequestIsHighRisk() {
        let analysis = analyze(
            displayName: "Msn Changed Request",
            address: "dorothyiryatesburgman@pentzero.com",
            subject: "Phone Number Changed Request on 2026-09-27",
            decodedMessageText: """
            Microsoft
            Update Request
            Someone submitted a request to change your phone number.
            Not you? Reject it. REJECT IT
            """
        )

        XCTAssertTrue(analysis.claimsMicrosoftIdentity)
        XCTAssertEqual(analysis.senderDomain, "pentzero.com")
        XCTAssertEqual(analysis.score, 95)
        XCTAssertEqual(analysis.riskLevel, .high)
        XCTAssertEqual(
            analysis.reason,
            "Microsoft account/security impersonation: sender domain is not approved"
        )
    }

    func testBodyBrandingAndSecurityActionCanTrigger() {
        let analysis = analyze(
            displayName: "Account Notification",
            address: "notice@unrelated.example",
            subject: "Update request",
            decodedMessageText: "Microsoft Account — someone submitted a request. Reject it."
        )

        XCTAssertTrue(analysis.claimsMicrosoftIdentity)
        XCTAssertEqual(analysis.score, 95)
    }

    func testConversationalMicrosoftSecurityMentionDoesNotTrigger() {
        let analysis = analyze(
            displayName: "Technology Newsletter",
            address: "news@example.org",
            subject: "How Microsoft approaches account security",
            decodedMessageText: "An overview of Microsoft products and security practices."
        )

        XCTAssertFalse(analysis.claimsMicrosoftIdentity)
        XCTAssertEqual(analysis.score, 0)
    }

    func testAuthenticatedApprovedMicrosoftSenderIsNotImpersonation() {
        let analysis = analyze(
            displayName: "Microsoft Account",
            address: "account-security-noreply@accountprotection.microsoft.com",
            authenticationResults: "spf=pass; dkim=pass; dmarc=pass"
        )

        XCTAssertTrue(analysis.claimsMicrosoftIdentity)
        XCTAssertEqual(analysis.riskLevel, .low)
        XCTAssertEqual(analysis.score, 0)
        XCTAssertNil(analysis.reason)
    }

    func testAuthenticationFailureRaisesUnapprovedDomainScore() {
        let analysis = analyze(
            displayName: "Microsoft 365",
            address: "notice@unrelated.example",
            authenticationResults: "spf=fail; dkim=fail; dmarc=fail"
        )

        XCTAssertEqual(analysis.riskLevel, .high)
        XCTAssertEqual(analysis.score, 100)
        XCTAssertTrue(analysis.reason?.contains("Authentication failed") == true)
    }

    func testMicrosoftOutlookFromUnapprovedDomainBecomesAutoDeleteCandidate() {
        let impersonation = analyze(
            displayName: "Microsoft Outlook",
            address: "no-reply_servicemadison@alloum.com"
        )
        let sender = SenderAddressAnalyzer.analyze("no-reply_servicemadison@alloum.com")
        let content = MessageContentAnalyzer.analyze(
            senderDisplayName: "Microsoft Outlook",
            fromAddress: "no-reply_servicemadison@alloum.com",
            replyTo: "",
            subject: "Security notice",
            body: ""
        )

        let combined = CombinedMessageAnalyzer.combine(
            senderAnalysis: sender,
            contentAnalysis: content,
            bodyTextAnalysis: .none,
            microsoftImpersonationAnalysis: impersonation
        )

        XCTAssertEqual(combined.riskLevel, .high)
        XCTAssertEqual(combined.score, 95)
        XCTAssertTrue(combined.isAutoDeleteCandidate)
        XCTAssertTrue(combined.reason.contains("Microsoft account/security impersonation"))
    }

    private func analyze(
        displayName: String,
        address: String,
        subject: String = "Security notice",
        authenticationResults: String = "",
        decodedMessageText: String = "",
        imageText: String = ""
    ) -> MicrosoftImpersonationAnalysis {
        MicrosoftImpersonationAnalyzer.analyze(
            senderDisplayName: displayName,
            senderAddress: address,
            subject: subject,
            authenticationResults: authenticationResults,
            decodedMessageText: decodedMessageText,
            imageText: imageText
        )
    }
}
