import XCTest
@testable import JunkMailCleaner

final class DecodedMessageTextExtractorTests: XCTestCase {
    func testDecodesPlainTextMIMEBody() {
        let rawMessage = """
        MIME-Version: 1.0
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        DocuSign=20has=20sent=20you=20a=20document.=20Please=20review=20and=20sign.
        """

        let result = DecodedMessageTextExtractor.extract(from: rawMessage)

        XCTAssertTrue(result.plainText.contains("DocuSign has sent you a document"))
    }

    func testExtractsVisibleHTMLAndAltTitleAttributes() {
        let rawMessage = """
        MIME-Version: 1.0
        Content-Type: text/html; charset=utf-8

        <html>
          <head><title>Signature requested</title></head>
          <body>
            <img src="logo.png" alt="Docu Sign">
            <p>Please review the document &amp; sign it.</p>
          </body>
        </html>
        """

        let result = DecodedMessageTextExtractor.extract(from: rawMessage)

        XCTAssertTrue(result.htmlText.contains("Please review the document & sign it."))
        XCTAssertTrue(result.htmlText.contains("Docu Sign"))

        let analysis = BrandImpersonationAnalyzer.analyze(
            senderDisplayName: "Document Center",
            senderAddress: "notice@untrusted.example",
            decodedMessageText: result.htmlText
        )
        XCTAssertEqual(analysis.score, 80)
        XCTAssertTrue(analysis.isAutoDeleteCandidate)
    }

    func testScriptTextIsNotTreatedAsVisibleHTML() {
        let rawMessage = """
        Content-Type: text/html; charset=utf-8

        <html><body>
          <script title="DocuSign signature requested">Please review the document.</script>
          <p>Ordinary newsletter text.</p>
        </body></html>
        """

        let result = DecodedMessageTextExtractor.extract(from: rawMessage)
        let analysis = BrandImpersonationAnalyzer.analyze(
            senderDisplayName: "Newsletter",
            senderAddress: "news@example.com",
            decodedMessageText: result.htmlText
        )

        XCTAssertFalse(result.htmlText.contains("DocuSign"))
        XCTAssertEqual(analysis.score, 0)
    }

    func testTextAttachmentIsNotTreatedAsMessageBody() {
        let rawMessage = """
        Content-Type: text/plain; charset=utf-8
        Content-Disposition: attachment; filename=notes.txt

        DocuSign signature requested. Please review the document.
        """

        let result = DecodedMessageTextExtractor.extract(from: rawMessage)

        XCTAssertTrue(result.combinedText.isEmpty)
    }
}
