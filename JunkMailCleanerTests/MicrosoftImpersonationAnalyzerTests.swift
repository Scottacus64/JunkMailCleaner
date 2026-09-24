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
            "Microsoft impersonation: sender domain is not an approved Microsoft domain"
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
        XCTAssertTrue(combined.reason.contains("Microsoft impersonation"))
    }

    private func analyze(
        displayName: String,
        address: String,
        subject: String = "Security notice",
        authenticationResults: String = ""
    ) -> MicrosoftImpersonationAnalysis {
        MicrosoftImpersonationAnalyzer.analyze(
            senderDisplayName: displayName,
            senderAddress: address,
            subject: subject,
            authenticationResults: authenticationResults
        )
    }
}
