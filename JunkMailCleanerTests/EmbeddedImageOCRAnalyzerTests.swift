import AppKit
import XCTest
@testable import JunkMailCleaner

final class EmbeddedImageOCRAnalyzerTests: XCTestCase {
    func testPayPalInvoiceImageFromFreeMailTriggersImageTextMismatch() throws {
        let image = try makePNG(
            text: "PayPal INVOICE\nYour account has been debited\nAmount Paid Transaction",
            width: 1_600,
            height: 600
        )
        let ocr = EmbeddedImageOCRAnalyzer.recognizeText(
            in: rawMessage(imageData: image, disposition: "inline", contentID: "invoice-image")
        )

        XCTAssertEqual(ocr.discoveredImageCount, 1)
        XCTAssertEqual(ocr.attemptedImageCount, 1)
        XCTAssertTrue(ocr.recognizedText.lowercased().contains("paypal"))
        XCTAssertTrue(ocr.recognizedText.lowercased().contains("invoice"))

        let analysis = InvoiceFraudAnalyzer.analyze(
            senderAddress: "person@icloud.com",
            subject: "Your purchase",
            body: "",
            imageText: ocr.recognizedText
        )

        XCTAssertEqual(analysis.score, 90)
        XCTAssertTrue(
            analysis.reasons.contains("Financial brand/domain mismatch: PayPal (image text)")
        )
    }

    func testSameImageFromApprovedPayPalDomainHasNoMismatch() throws {
        let image = try makePNG(
            text: "PayPal INVOICE\nYour account has been debited\nAmount Paid Transaction",
            width: 1_600,
            height: 600
        )
        let ocr = EmbeddedImageOCRAnalyzer.recognizeText(
            in: rawMessage(imageData: image, disposition: "attachment")
        )
        let analysis = InvoiceFraudAnalyzer.analyze(
            senderAddress: "service@billing.paypal.com",
            subject: "Your purchase",
            body: "",
            imageText: ocr.recognizedText
        )

        XCTAssertEqual(analysis.score, 0)
        XCTAssertFalse(analysis.reasons.contains { $0.contains("brand/domain mismatch") })
    }

    func testOrdinaryImageWithNoRelevantTextAddsNoRisk() throws {
        let image = try makePNG(text: "", width: 1_200, height: 800)
        let ocr = EmbeddedImageOCRAnalyzer.recognizeText(
            in: rawMessage(imageData: image, disposition: "inline")
        )
        let analysis = InvoiceFraudAnalyzer.analyze(
            senderAddress: "person@icloud.com",
            subject: "Vacation photograph",
            body: "Hope you enjoy this picture.",
            imageText: ocr.recognizedText
        )

        XCTAssertEqual(ocr.attemptedImageCount, 1)
        XCTAssertEqual(analysis.score, 0)
    }

    func testTinyTrackingImageIsSkipped() throws {
        let image = try makePNG(text: "PayPal INVOICE", width: 1, height: 1)
        let ocr = EmbeddedImageOCRAnalyzer.recognizeText(
            in: rawMessage(imageData: image, disposition: "inline")
        )

        XCTAssertEqual(ocr.discoveredImageCount, 1)
        XCTAssertEqual(ocr.attemptedImageCount, 0)
        XCTAssertEqual(ocr.skippedImageCount, 1)
        XCTAssertTrue(ocr.recognizedText.isEmpty)
    }

    func testExistingTextOnlyBrandDetectionIsUnchanged() {
        let analysis = InvoiceFraudAnalyzer.analyze(
            senderAddress: "billing@randomdomain.com",
            subject: "PayPal invoice",
            body: "This PayPal invoice confirms your payment and transaction."
        )

        XCTAssertEqual(analysis.score, 50)
        XCTAssertEqual(analysis.reasons, ["Financial brand/domain mismatch: PayPal"])
    }

    func testBrandLogoWithoutPaymentContextAddsNoRisk() {
        let analysis = InvoiceFraudAnalyzer.analyze(
            senderAddress: "newsletter@example.org",
            subject: "Store newsletter",
            body: "",
            imageText: "PayPal"
        )

        XCTAssertEqual(analysis.score, 0)
    }

    private func rawMessage(
        imageData: Data,
        disposition: String,
        contentID: String? = nil
    ) -> String {
        let contentIDHeader = contentID.map { "Content-ID: <\($0)>\r\n" } ?? ""
        return """
        MIME-Version: 1.0\r
        Content-Type: multipart/related; boundary="ocr-test-boundary"\r
        \r
        --ocr-test-boundary\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><body><img src="cid:invoice-image"></body></html>\r
        --ocr-test-boundary\r
        Content-Type: image/png\r
        Content-Transfer-Encoding: base64\r
        Content-Disposition: \(disposition); filename="invoice.png"\r
        \(contentIDHeader)\r
        \(imageData.base64EncodedString(options: .lineLength76Characters))\r
        --ocr-test-boundary--\r
        """
    }

    private func makePNG(text: String, width: Int, height: Int) throws -> Data {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw TestImageError.creationFailed
        }

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
            NSGraphicsContext.restoreGraphicsState()
            throw TestImageError.creationFailed
        }
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        if !text.isEmpty {
            (text as NSString).draw(
                in: NSRect(x: 70, y: 70, width: width - 140, height: height - 140),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 58, weight: .semibold),
                    .foregroundColor: NSColor.black
                ]
            )
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw TestImageError.creationFailed
        }
        return data
    }
}

private enum TestImageError: Error {
    case creationFailed
}
