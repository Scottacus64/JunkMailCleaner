import Foundation

nonisolated struct EmailHeaderField: Sendable, Equatable {
    let name: String
    let value: String
}

nonisolated struct EmailAttachmentMetadata: Sendable, Equatable {
    let filename: String
    let mimeType: String
    let size: Int
    let isInline: Bool
}

nonisolated struct EmailLink: Sendable, Equatable, Identifiable {
    let visibleText: String
    let destination: String
    let actualDestination: String?
    let destinationDomain: String?
    let hasDisplayDestinationMismatch: Bool

    var id: String { visibleText + "\u{0}" + destination }
}

nonisolated struct MessageInspectionSource: Sendable, Equatable {
    let rawSource: String
    let mailBody: String
}

nonisolated struct MessageInspectionData: Sendable, Equatable {
    let rawSource: String
    let headers: [EmailHeaderField]
    let plainText: String
    let visibleHTMLText: String
    let originalHTML: String?
    let inlineImages: [String: String]
    let links: [EmailLink]
    let attachments: [EmailAttachmentMetadata]
    let mailBody: String

    var safeHTML: String? {
        renderedHTML(allowsRemoteImages: false)
    }

    func renderedHTML(allowsRemoteImages: Bool) -> String? {
        guard let originalHTML else { return nil }
        return RenderedEmailHTML.sanitize(
            originalHTML,
            inlineImages: inlineImages,
            allowsRemoteImages: allowsRemoteImages
        )
    }

    func firstHeader(named name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func headers(named name: String) -> [String] {
        headers
            .filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            .map(\.value)
    }
}

nonisolated struct MessageInspectorAnalysisSnapshot: Sendable {
    let finalRisk: SenderRiskLevel
    let finalScore: Int
    let isAutoDeleteCandidate: Bool
    let senderScore: Int
    let contentScore: Int
    let bodyTextScore: Int
    let microsoftImpersonationScore: Int
    let brandImpersonationScore: Int
    let invoiceFraudScore: Int
    let calendarFraudScore: Int
    let commercialMessageScore: Int
    let senderListStatus: SenderListStatus
    let spf: String?
    let dkim: String?
    let dmarc: String?
    let categories: [String]
    let reasons: [String]
    let claimedBrand: String?
    let isTrustedBrandDomain: Bool?
    let replyToAddress: String?
    let suspiciousTokens: [String]
    let protectedTokens: [String]

    init(message: JunkMailMessage) {
        finalRisk = message.combinedAnalysis.riskLevel
        finalScore = message.combinedAnalysis.score
        isAutoDeleteCandidate = message.combinedAnalysis.isAutoDeleteCandidate
        senderScore = message.senderAnalysis.score
        contentScore = message.contentAnalysis.score
        bodyTextScore = message.bodyTextAnalysis.score
        microsoftImpersonationScore = message.microsoftImpersonationAnalysis.score
        brandImpersonationScore = message.brandImpersonationAnalysis.score
        invoiceFraudScore = message.invoiceFraudAnalysis.score
        calendarFraudScore = message.calendarInviteFraudAnalysis.score
        commercialMessageScore = message.commercialMessageAnalysis.score
        senderListStatus = message.senderListStatus
        spf = message.microsoftImpersonationAnalysis.spfResult
        dkim = message.microsoftImpersonationAnalysis.dkimResult
        dmarc = message.microsoftImpersonationAnalysis.dmarcResult
        categories = message.contentAnalysis.categories.map(\.rawValue).sorted()
        reasons = Self.uniqueReasons(from: message)
        claimedBrand = message.brandImpersonationAnalysis.claimedBrand
        isTrustedBrandDomain = message.brandImpersonationAnalysis.isTrustedBrandDomain
        replyToAddress = message.replyToAddress.isEmpty ? nil : message.replyToAddress
        suspiciousTokens = message.bodyTextAnalysis.suspiciousTokens
        protectedTokens = message.bodyTextAnalysis.protectedTokens
    }

    private static func uniqueReasons(from message: JunkMailMessage) -> [String] {
        let candidates = [
            message.combinedAnalysis.reason,
            message.senderAnalysis.score > 0 ? message.senderAnalysis.reason : nil,
            message.contentAnalysis.score > 0 ? message.contentAnalysis.reason : nil,
            message.bodyTextAnalysis.reason,
            message.microsoftImpersonationAnalysis.reason,
            message.brandImpersonationAnalysis.reason,
            message.invoiceFraudAnalysis.reason,
            message.calendarInviteFraudAnalysis.reason,
            message.commercialMessageAnalysis.reason
        ].compactMap { $0 }
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted }
    }
}

nonisolated enum MessageInspectorSelection {
    static func message(
        for reference: MailMessageReference,
        in messages: [JunkMailMessage]
    ) -> JunkMailMessage? {
        messages.first { $0.reference == reference }
    }
}

nonisolated enum MessageInspectorParser {
    private struct MIMEPart {
        let headers: [EmailHeaderField]
        let body: String
    }

    private static let maximumPartBytes = 10 * 1_024 * 1_024
    private static let maximumInlineImageBytes = 8 * 1_024 * 1_024
    private static let maximumTotalInlineImageBytes = 20 * 1_024 * 1_024

    static func parse(_ source: MessageInspectionSource) -> MessageInspectionData {
        let (headerText, _) = splitHeadersAndBody(source.rawSource)
        let headers = parseHeaders(headerText)
        let leafParts = collectLeafParts(from: source.rawSource)
        let decodedText = DecodedMessageTextExtractor.extract(from: source.rawSource)

        #if DEBUG
        let topLevelContentType = headerValue("Content-Type", in: headers) ?? "text/plain (default)"
        print(
            "[JunkMailCleaner][Inspector][MIME] rawSource chars=\(source.rawSource.count) "
                + "bytes=\(source.rawSource.utf8.count); top-level Content-Type=\(topLevelContentType); "
                + "leafParts=\(leafParts.count)"
        )
        #endif

        var htmlParts: [String] = []
        var plainTextParts: [String] = []
        var attachments: [EmailAttachmentMetadata] = []
        var inlineImages: [String: String] = [:]
        var totalInlineImageBytes = 0

        for (partIndex, part) in leafParts.enumerated() {
            let contentTypeHeader = headerValue("Content-Type", in: part.headers) ?? "text/plain"
            let mimeType = contentTypeHeader
                .split(separator: ";", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? "text/plain"
            let disposition = headerValue("Content-Disposition", in: part.headers) ?? ""
            let filename = parameter(named: "filename", in: disposition)
                ?? parameter(named: "name", in: contentTypeHeader)
            let transferEncoding = headerValue("Content-Transfer-Encoding", in: part.headers) ?? ""
            let decodedData = decodeBody(part.body, transferEncoding: transferEncoding)
            let charset = parameter(named: "charset", in: contentTypeHeader)
            let isAttachment = disposition.lowercased().contains("attachment") || filename != nil
            let isInline = disposition.lowercased().contains("inline")

            #if DEBUG
            let contentID = headerValue("Content-ID", in: part.headers) ?? "none"
            print(
                "[JunkMailCleaner][Inspector][MIME] part=\(partIndex + 1) "
                    + "type=\(mimeType) charset=\(charset ?? "unspecified") "
                    + "encoding=\(transferEncoding.isEmpty ? "7bit/8bit default" : transferEncoding) "
                    + "disposition=\(disposition.isEmpty ? "none" : disposition) "
                    + "contentID=\(contentID) encodedBytes=\(part.body.utf8.count) "
                    + "decodedBytes=\(decodedData.count)"
            )
            #endif

            if isAttachment || (isInline && mimeType.hasPrefix("image/")) {
                attachments.append(
                    EmailAttachmentMetadata(
                        filename: filename ?? "(unnamed)",
                        mimeType: mimeType,
                        size: decodedData.count,
                        isInline: isInline
                    )
                )
            }

            if mimeType == "text/html", !isAttachment,
               decodedData.count <= maximumPartBytes,
               let html = decodeText(decodedData, charset: charset) {
                htmlParts.append(html)
            }

            if mimeType == "text/plain", !isAttachment,
               decodedData.count <= maximumPartBytes,
               let plainText = decodeText(decodedData, charset: charset) {
                plainTextParts.append(plainText)
            }

            if ["image/jpeg", "image/png", "image/gif", "image/heic", "image/heif"]
                .contains(mimeType),
               !decodedData.isEmpty,
               decodedData.count <= maximumInlineImageBytes,
               totalInlineImageBytes + decodedData.count <= maximumTotalInlineImageBytes,
               let contentID = headerValue("Content-ID", in: part.headers)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")),
               !contentID.isEmpty {
                inlineImages[contentID.lowercased()] =
                    "data:\(mimeType);base64,\(decodedData.base64EncodedString())"
                totalInlineImageBytes += decodedData.count
            }
        }

        let originalHTML = htmlParts
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .max(by: { $0.utf8.count < $1.utf8.count })
        let parsedPlainText = plainTextParts
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .max(by: { $0.utf8.count < $1.utf8.count })
        let fallbackPlainText = parsedPlainText ?? decodedText.plainText
        #if DEBUG
        print(
            "[JunkMailCleaner][Inspector][MIME] htmlFound=\(originalHTML != nil) "
                + "htmlChars=\(originalHTML?.count ?? 0) "
                + "htmlPreview=\(debugPreview(originalHTML ?? "")); "
                + "plainFound=\(!fallbackPlainText.isEmpty) "
                + "plainChars=\(fallbackPlainText.count); cidResources=\(inlineImages.count)"
        )
        #endif
        return MessageInspectionData(
            rawSource: source.rawSource,
            headers: headers,
            plainText: fallbackPlainText,
            visibleHTMLText: decodedText.htmlText,
            originalHTML: originalHTML,
            inlineImages: inlineImages,
            links: EmailLinkExtractor.extract(
                html: originalHTML ?? "",
                plainText: fallbackPlainText
            ),
            attachments: attachments,
            mailBody: source.mailBody
        )
    }

    static func parseHeaders(_ text: String) -> [EmailHeaderField] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var unfolded: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " "
                    + line.trimmingCharacters(in: .whitespaces)
            } else {
                unfolded.append(line)
            }
        }
        return unfolded.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return EmailHeaderField(name: name, value: value)
        }
    }

    private static func collectLeafParts(from entity: String) -> [MIMEPart] {
        let (headerText, body) = splitHeadersAndBody(entity)
        let headers = parseHeaders(headerText)
        let contentType = headerValue("Content-Type", in: headers) ?? "text/plain"
        let mimeType = contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "text/plain"
        if mimeType.hasPrefix("multipart/"),
           let boundary = parameter(named: "boundary", in: contentType) {
            return multipartChildren(body: body, boundary: boundary)
                .flatMap(collectLeafParts)
        }
        return [MIMEPart(headers: headers, body: body)]
    }

    private static func splitHeadersAndBody(_ entity: String) -> (String, String) {
        for separator in ["\r\n\r\n", "\n\n"] {
            if let range = entity.range(of: separator) {
                return (
                    String(entity[..<range.lowerBound]),
                    String(entity[range.upperBound...])
                )
            }
        }
        return (entity, "")
    }

    private static func multipartChildren(body: String, boundary: String) -> [String] {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.components(separatedBy: "--\(boundary)")
            .dropFirst()
            .compactMap { component in
                let trimmed = component.trimmingCharacters(in: .newlines)
                guard !trimmed.hasPrefix("--") else { return nil }
                return trimmed
            }
    }

    private static func headerValue(
        _ name: String,
        in headers: [EmailHeaderField]
    ) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func parameter(named name: String, in header: String) -> String? {
        let pattern = #"(?i)(?:^|;)\s*"#
            + NSRegularExpression.escapedPattern(for: name)
            + #"\*?\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^;\s]*))"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: header,
                range: NSRange(header.startIndex..., in: header)
              ) else {
            return nil
        }
        for index in 1..<match.numberOfRanges
        where match.range(at: index).location != NSNotFound {
            if let range = Range(match.range(at: index), in: header) {
                return String(header[range])
            }
        }
        return nil
    }

    private static func decodeBody(_ body: String, transferEncoding: String) -> Data {
        switch transferEncoding.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "base64":
            return Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return decodeQuotedPrintable(body)
        default:
            return body.data(using: .utf8) ?? Data()
        }
    }

    private static func decodeQuotedPrintable(_ value: String) -> Data {
        let bytes = Array(value.utf8)
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 61 {
                if index + 1 < bytes.count, bytes[index + 1] == 10 {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 {
                    index += 3
                    continue
                }
                if index + 2 < bytes.count,
                   let high = hexValue(bytes[index + 1]),
                   let low = hexValue(bytes[index + 2]) {
                    result.append(high * 16 + low)
                    index += 3
                    continue
                }
            }
            result.append(bytes[index])
            index += 1
        }
        return Data(result)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    private static func decodeText(_ data: Data, charset: String?) -> String? {
        let normalized = charset?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\r\n"))
            .lowercased()
        let preferredEncoding: String.Encoding? = switch normalized {
        case "utf-8", "utf8": .utf8
        case "iso-8859-1", "latin1", "iso-latin-1": .isoLatin1
        case "windows-1252", "cp1252": .windowsCP1252
        case "us-ascii", "ascii": .ascii
        case "utf-16", "utf16": .utf16
        case "utf-16le": .utf16LittleEndian
        case "utf-16be": .utf16BigEndian
        default: nil
        }
        if let preferredEncoding, let decoded = String(data: data, encoding: preferredEncoding) {
            return decoded
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func debugPreview(_ value: String) -> String {
        String(value.prefix(200))
            .replacingOccurrences(of: #"[\r\n\t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }
}

nonisolated enum EmailLinkExtractor {
    static func describe(destination: String, visibleText: String = "") -> EmailLink? {
        var links: [EmailLink] = []
        append(destination: destination, visibleText: visibleText, to: &links)
        return links.first
    }

    static func extract(html: String, plainText: String) -> [EmailLink] {
        var links: [EmailLink] = []
        let anchorPattern = #"(?is)<a\b[^>]*\bhref\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a\s*>"#
        if let expression = try? NSRegularExpression(pattern: anchorPattern) {
            let range = NSRange(html.startIndex..., in: html)
            for match in expression.matches(in: html, range: range) {
                guard let destination = firstCapture(match, indexes: 1...3, in: html) else {
                    continue
                }
                let visibleHTML = capture(match, index: 4, in: html) ?? ""
                append(
                    destination: decodeHTMLEntities(destination),
                    visibleText: visibleText(from: visibleHTML),
                    to: &links
                )
            }
        }

        let urlPattern = #"(?i)\bhttps?://[^\s<>\"']+"#
        if let expression = try? NSRegularExpression(pattern: urlPattern) {
            let range = NSRange(plainText.startIndex..., in: plainText)
            for match in expression.matches(in: plainText, range: range) {
                guard let matchRange = Range(match.range, in: plainText) else { continue }
                let value = String(plainText[matchRange])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))
                append(destination: value, visibleText: value, to: &links)
            }
        }

        var seen: Set<String> = []
        return links.filter { seen.insert($0.destination).inserted }
    }

    private static func append(
        destination: String,
        visibleText: String,
        to links: inout [EmailLink]
    ) {
        guard let components = URLComponents(string: destination),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return
        }
        let actualDestination = MicrosoftSafeLinksDecoder.actualDestination(from: destination)
        let analyzedDestination = actualDestination ?? destination
        let domain = URLComponents(string: analyzedDestination)?.host?.lowercased()
        links.append(
            EmailLink(
                visibleText: visibleText.isEmpty ? "(no visible text)" : visibleText,
                destination: destination,
                actualDestination: actualDestination,
                destinationDomain: domain,
                hasDisplayDestinationMismatch: hasMismatch(
                    visibleText: visibleText,
                    destinationDomain: domain
                )
            )
        )
    }

    private static func hasMismatch(
        visibleText: String,
        destinationDomain: String?
    ) -> Bool {
        guard let destinationDomain else { return false }
        let normalizedText = visibleText.lowercased()
        let domainPattern = #"(?i)(?:https?://)?(?:www\.)?([a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,63})"#
        if let expression = try? NSRegularExpression(pattern: domainPattern),
           let match = expression.firstMatch(
            in: normalizedText,
            range: NSRange(normalizedText.startIndex..., in: normalizedText)
           ),
           let range = Range(match.range(at: 1), in: normalizedText) {
            let displayedDomain = String(normalizedText[range])
            return !domainsRelated(displayedDomain, destinationDomain)
        }

        let brands = ["Microsoft", "Alibaba", "PayPal", "DocuSign", "Amazon", "Apple", "Walmart", "Geek Squad"]
        if let brand = brands.first(where: { normalizedText.contains($0.lowercased()) }) {
            return !BrandImpersonationAnalyzer.isAllowedDomain(destinationDomain, for: brand)
        }
        return false
    }

    private static func domainsRelated(_ first: String, _ second: String) -> Bool {
        first == second
            || first.hasSuffix("." + second)
            || second.hasSuffix("." + first)
    }

    private static func visibleText(from html: String) -> String {
        decodeHTMLEntities(
            html.replacingOccurrences(
                of: #"(?is)<[^>]+>"#,
                with: " ",
                options: .regularExpression
            )
        )
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstCapture(
        _ match: NSTextCheckingResult,
        indexes: ClosedRange<Int>,
        in value: String
    ) -> String? {
        for index in indexes {
            if let captured = capture(match, index: index, in: value) {
                return captured
            }
        }
        return nil
    }

    private static func capture(
        _ match: NSTextCheckingResult,
        index: Int,
        in value: String
    ) -> String? {
        guard match.range(at: index).location != NSNotFound,
              let range = Range(match.range(at: index), in: value) else {
            return nil
        }
        return String(value[range])
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        var result = value
        for (entity, replacement) in [
            "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&lt;": "<", "&gt;": ">", "&nbsp;": " "
        ] {
            result = result.replacingOccurrences(
                of: entity,
                with: replacement,
                options: .caseInsensitive
            )
        }
        return result
    }
}

nonisolated enum MicrosoftSafeLinksDecoder {
    static func actualDestination(from protectedURL: String) -> String? {
        guard let components = URLComponents(string: protectedURL),
              let host = components.host?.lowercased(),
              host == "safelinks.protection.outlook.com"
                || host.hasSuffix(".safelinks.protection.outlook.com"),
              let encodedDestination = components.queryItems?.first(where: {
                  $0.name.caseInsensitiveCompare("url") == .orderedSame
              })?.value else {
            return nil
        }

        var candidate = encodedDestination
        if URLComponents(string: candidate)?.scheme == nil,
           let decoded = candidate.removingPercentEncoding {
            candidate = decoded
        }
        guard let destination = URLComponents(string: candidate),
              let scheme = destination.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              destination.host != nil else {
            return nil
        }
        return candidate
    }
}

nonisolated enum RenderedEmailHTML {
    static func sanitize(
        _ html: String,
        inlineImages: [String: String],
        allowsRemoteImages: Bool
    ) -> String {
        var result = html
        for tag in [
            "script", "iframe", "frame", "frameset", "object", "embed",
            "svg", "math", "audio", "video", "canvas", "template"
        ] {
            result = result.replacingOccurrences(
                of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>",
                with: " ",
                options: .regularExpression
            )
            result = result.replacingOccurrences(
                of: "(?is)<\(tag)\\b[^>]*/?\\s*>",
                with: " ",
                options: .regularExpression
            )
        }
        result = result.replacingOccurrences(
            of: #"(?is)</?form\b[^>]*>"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?is)<(?:meta|link|base|source)\b[^>]*>"#,
            with: " ",
            options: .regularExpression
        )
        result = stripAttribute(#"on[a-z0-9_-]+"#, from: result)
        for attribute in [
            "srcset", "poster", "srcdoc", "action", "formaction", "ping",
            "lowsrc", "dynsrc"
        ] {
            result = stripAttribute(attribute, from: result)
        }
        result = replaceAttribute("src", in: result) {
            safeResource($0, inlineImages: inlineImages, allowsRemoteImages: allowsRemoteImages)
        }
        result = replaceAttribute("href", in: result) { value in
            let decoded = value
                .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
                .replacingOccurrences(of: "&#38;", with: "&", options: .caseInsensitive)
            guard let scheme = URLComponents(string: decoded)?.scheme?.lowercased() else {
                return decoded.hasPrefix("#") ? decoded : nil
            }
            return ["http", "https", "mailto"].contains(scheme) ? decoded : nil
        }
        result = replaceAttribute("background", in: result) { value in
            let lower = value.lowercased()
            if lower.hasPrefix("cid:") || lower.hasPrefix("http://")
                || lower.hasPrefix("https://") || lower.hasPrefix("//") {
                return safeResource(
                    value,
                    inlineImages: inlineImages,
                    allowsRemoteImages: allowsRemoteImages
                )
            }
            return value
        }
        result = sanitizeCSSURLs(
            result,
            inlineImages: inlineImages,
            allowsRemoteImages: allowsRemoteImages
        )

        let imageSources = allowsRemoteImages ? "data: http: https:" : "data:"
        let policy = "default-src 'none'; img-src \(imageSources); style-src 'unsafe-inline'; "
            + "script-src 'none'; connect-src 'none'; frame-src 'none'; "
            + "font-src 'none'; media-src 'none'; object-src 'none'; "
            + "form-action 'none'; base-uri 'none'"
        let safetyHead = """
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <meta name="referrer" content="no-referrer">
        <style>html,body{min-height:100%}body{overflow-wrap:anywhere}img{max-width:100%;height:auto}</style>
        """
        if let range = result.range(of: #"(?is)<head\b[^>]*>"#, options: .regularExpression) {
            result.insert(contentsOf: safetyHead, at: range.upperBound)
            return result
        }
        if let range = result.range(of: #"(?is)<html\b[^>]*>"#, options: .regularExpression) {
            result.insert(contentsOf: "<head>\(safetyHead)</head>", at: range.upperBound)
            return result
        }
        return "<!doctype html><html><head>\(safetyHead)</head><body>\(result)</body></html>"
    }

    private static func safeResource(
        _ value: String,
        inlineImages: [String: String],
        allowsRemoteImages: Bool
    ) -> String? {
        let decoded = value
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&#38;", with: "&", options: .caseInsensitive)
        let lower = decoded.lowercased()
        if lower.hasPrefix("cid:") {
            let contentID = String(decoded.dropFirst(4))
                .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
                .lowercased()
            return inlineImages[contentID]
        }
        if lower.hasPrefix("data:image/png") || lower.hasPrefix("data:image/jpeg")
            || lower.hasPrefix("data:image/gif") {
            return decoded
        }
        if allowsRemoteImages && (lower.hasPrefix("http://") || lower.hasPrefix("https://")) {
            return decoded
        }
        if allowsRemoteImages && lower.hasPrefix("//") { return "https:" + decoded }
        return nil
    }

    private static func sanitizeCSSURLs(
        _ html: String,
        inlineImages: [String: String],
        allowsRemoteImages: Bool
    ) -> String {
        let pattern = #"(?is)url\(\s*(?:\"([^\"]*)\"|'([^']*)'|([^\)\s]+))\s*\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return html }
        var result = html
        for match in expression.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let fullRange = Range(match.range, in: result) else { continue }
            var value: String?
            for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                if let range = Range(match.range(at: index), in: html) {
                    value = String(html[range])
                    break
                }
            }
            let replacement = value.flatMap {
                safeResource($0, inlineImages: inlineImages, allowsRemoteImages: allowsRemoteImages)
            }.map { "url(\"\(escape($0))\")" } ?? "none"
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result.replacingOccurrences(
            of: #"(?is)@import\s+(?:url\()?[^;\n]+;?"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func stripAttribute(_ name: String, from html: String) -> String {
        html.replacingOccurrences(
            of: #"(?is)\s+"# + name + #"\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+)"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func replaceAttribute(
        _ name: String,
        in html: String,
        transform: (String) -> String?
    ) -> String {
        let pattern = #"(?is)\s+"# + NSRegularExpression.escapedPattern(for: name)
            + #"\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return html }
        var result = html
        for match in expression.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let fullRange = Range(match.range, in: result) else { continue }
            var value: String?
            for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                if let range = Range(match.range(at: index), in: html) {
                    value = String(html[range])
                    break
                }
            }
            let replacement = value.flatMap(transform).map { " \(name)=\"\(escape($0))\"" } ?? ""
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

nonisolated enum SafeEmailNetworkPolicy {
    static func contentRuleJSON(allowsRemoteImages: Bool) -> String {
        let blockedTypes = allowsRemoteImages
            ? #", "resource-type":["document","style-sheet","script","font","media","svg-document","raw","popup"]"#
            : ""
        let schemes = ["http", "https", "ftp", "file", "ws", "wss"]
        let rules = schemes.map { scheme in
            """
            {"trigger":{"url-filter":"^\(scheme):"\(blockedTypes)},"action":{"type":"block"}}
            """
        }
        return "[\(rules.joined(separator: ","))]"
    }
}

nonisolated enum SafeEmailHTML {
    static func sanitize(_ html: String, inlineImages: [String: String] = [:]) -> String {
        var result = html

        let dangerousContainers = [
            "script", "iframe", "frame", "frameset", "object", "embed", "form",
            "svg", "math", "audio", "video", "canvas", "template", "style",
            "button", "select", "textarea"
        ]
        for tag in dangerousContainers {
            result = result.replacingOccurrences(
                of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>",
                with: " ",
                options: .regularExpression
            )
            result = result.replacingOccurrences(
                of: "(?is)<\(tag)\\b[^>]*/?\\s*>",
                with: " ",
                options: .regularExpression
            )
        }
        result = result.replacingOccurrences(
            of: #"(?is)<(?:meta|link|base|source|input)\b[^>]*>"#,
            with: " ",
            options: .regularExpression
        )
        result = stripAttribute(namedPattern: #"on[a-z0-9_-]+"#, from: result)
        for attribute in [
            "style", "srcset", "background", "poster", "srcdoc", "action",
            "formaction", "ping", "lowsrc", "dynsrc"
        ] {
            result = stripAttribute(namedPattern: attribute, from: result)
        }

        result = replaceAttribute(named: "src", in: result) { value in
            guard value.lowercased().hasPrefix("cid:") else { return nil }
            let contentID = String(value.dropFirst(4)).lowercased()
            return inlineImages[contentID]
        }
        result = replaceAttribute(named: "href", in: result) { value in
            "blocked:" + value
        }
        result = result.replacingOccurrences(
            of: #"(?i)href\s*=\s*(\"blocked:([^\"]*)\"|'blocked:([^']*)')"#,
            with: #"data-inspector-link="$2$3""#,
            options: .regularExpression
        )

        let policy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; "
            + "script-src 'none'; connect-src 'none'; frame-src 'none'; "
            + "font-src 'none'; media-src 'none'; object-src 'none'; "
            + "form-action 'none'; base-uri 'none'"
        let prefix = """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <meta name="referrer" content="no-referrer">
        <style>
        body { font: 14px -apple-system, BlinkMacSystemFont, sans-serif; color: #202124;
               background: white; margin: 18px; overflow-wrap: anywhere; }
        a, [data-inspector-link] { color: #2458a6; text-decoration: underline;
                                  cursor: not-allowed; }
        img { max-width: 100%; height: auto; }
        </style></head><body>
        """
        return prefix + result + "</body></html>"
    }

    private static func stripAttribute(namedPattern name: String, from html: String) -> String {
        html.replacingOccurrences(
            of: #"(?is)\s+"# + name
                + #"\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+)"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func replaceAttribute(
        named name: String,
        in html: String,
        transform: (String) -> String?
    ) -> String {
        let pattern = #"(?is)\s+"#
            + NSRegularExpression.escapedPattern(for: name)
            + #"\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return html
        }
        var result = html
        let matches = expression.matches(
            in: html,
            range: NSRange(html.startIndex..., in: html)
        )
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result) else { continue }
            var value: String?
            for index in 1..<match.numberOfRanges
            where match.range(at: index).location != NSNotFound {
                if let range = Range(match.range(at: index), in: html) {
                    value = String(html[range])
                    break
                }
            }
            let replacement = value.flatMap(transform).map {
                " \(name)=\"\(escapeAttribute($0))\""
            } ?? ""
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
