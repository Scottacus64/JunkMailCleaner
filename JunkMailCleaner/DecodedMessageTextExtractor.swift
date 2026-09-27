import Foundation

nonisolated struct DecodedMessageText: Sendable {
    let plainText: String
    let htmlText: String

    var combinedText: String {
        [plainText, htmlText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    nonisolated static let none = DecodedMessageText(plainText: "", htmlText: "")
}

nonisolated enum DecodedMessageTextExtractor {
    nonisolated private static let maximumTextParts = 16
    nonisolated private static let maximumBytesPerPart = 2_097_152
    nonisolated private static let maximumTotalBytes = 4_194_304

    nonisolated static func extract(from rawMessage: String) -> DecodedMessageText {
        guard !rawMessage.isEmpty else { return .none }

        var plainParts: [String] = []
        var htmlParts: [String] = []
        var partCount = 0
        var totalBytes = 0
        collectTextParts(
            from: rawMessage,
            plainParts: &plainParts,
            htmlParts: &htmlParts,
            partCount: &partCount,
            totalBytes: &totalBytes
        )
        return DecodedMessageText(
            plainText: plainParts.joined(separator: "\n"),
            htmlText: htmlParts.joined(separator: "\n")
        )
    }

    nonisolated private static func collectTextParts(
        from entity: String,
        plainParts: inout [String],
        htmlParts: inout [String],
        partCount: inout Int,
        totalBytes: inout Int
    ) {
        guard partCount < maximumTextParts, totalBytes < maximumTotalBytes else { return }

        let (headerText, body) = splitHeadersAndBody(entity)
        let headers = parsedHeaders(headerText)
        let contentTypeHeader = headers["content-type"] ?? "text/plain"
        let contentType = contentTypeHeader
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "text/plain"

        if contentType.hasPrefix("multipart/"),
           let boundary = parameter(named: "boundary", in: contentTypeHeader) {
            for child in multipartChildren(body: body, boundary: boundary) {
                collectTextParts(
                    from: child,
                    plainParts: &plainParts,
                    htmlParts: &htmlParts,
                    partCount: &partCount,
                    totalBytes: &totalBytes
                )
            }
            return
        }

        guard contentType == "text/plain" || contentType == "text/html" else { return }
        let disposition = headers["content-disposition"]?.lowercased() ?? ""
        guard !disposition.hasPrefix("attachment") else { return }

        let data = decodedBody(
            body,
            transferEncoding: headers["content-transfer-encoding"] ?? ""
        )
        guard !data.isEmpty,
              data.count <= maximumBytesPerPart,
              totalBytes + data.count <= maximumTotalBytes else {
            return
        }

        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        guard !text.isEmpty else { return }

        partCount += 1
        totalBytes += data.count
        if contentType == "text/html" {
            htmlParts.append(visibleHTMLTextAndAttributes(text))
        } else {
            plainParts.append(text)
        }
    }

    nonisolated private static func visibleHTMLTextAndAttributes(_ html: String) -> String {
        var sanitizedHTML = html
        for pattern in [#"(?is)<!--.*?-->"#, #"(?is)<script\b.*?</script\s*>"#, #"(?is)<style\b.*?</style\s*>"#] {
            sanitizedHTML = sanitizedHTML.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }

        var attributeText: [String] = []
        let attributePattern = #"(?is)\b(?:alt|title)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
        if let expression = try? NSRegularExpression(pattern: attributePattern) {
            let range = NSRange(sanitizedHTML.startIndex..., in: sanitizedHTML)
            for match in expression.matches(in: sanitizedHTML, range: range) {
                for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                    if let valueRange = Range(match.range(at: index), in: sanitizedHTML) {
                        attributeText.append(String(sanitizedHTML[valueRange]))
                        break
                    }
                }
            }
        }

        var visible = sanitizedHTML
        visible = visible.replacingOccurrences(
            of: #"(?is)<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        return decodeHTMLEntities(
            ([visible] + attributeText).joined(separator: " ")
        )
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    nonisolated private static func decodeHTMLEntities(_ value: String) -> String {
        var decoded = value
        let namedEntities = [
            "&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&apos;": "'",
            "&#39;": "'", "&lt;": "<", "&gt;": ">"
        ]
        for (entity, replacement) in namedEntities {
            decoded = decoded.replacingOccurrences(
                of: entity,
                with: replacement,
                options: .caseInsensitive
            )
        }

        let pattern = #"&#(?:x([0-9a-f]+)|([0-9]+));"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return decoded
        }
        let matches = expression.matches(
            in: decoded,
            range: NSRange(decoded.startIndex..., in: decoded)
        )
        for match in matches.reversed() {
            let hexadecimalRange = match.range(at: 1)
            let decimalRange = match.range(at: 2)
            let number: UInt32?
            if hexadecimalRange.location != NSNotFound,
               let range = Range(hexadecimalRange, in: decoded) {
                number = UInt32(decoded[range], radix: 16)
            } else if decimalRange.location != NSNotFound,
                      let range = Range(decimalRange, in: decoded) {
                number = UInt32(decoded[range], radix: 10)
            } else {
                number = nil
            }
            guard let number, let scalar = UnicodeScalar(number),
                  let fullRange = Range(match.range, in: decoded) else {
                continue
            }
            decoded.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        return decoded
    }

    nonisolated private static func splitHeadersAndBody(_ entity: String) -> (String, String) {
        for separator in ["\r\n\r\n", "\n\n"] {
            if let range = entity.range(of: separator) {
                return (String(entity[..<range.lowerBound]), String(entity[range.upperBound...]))
            }
        }
        return (entity, "")
    }

    nonisolated private static func parsedHeaders(_ text: String) -> [String: String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var unfolded: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                unfolded.append(line)
            }
        }

        var headers: [String: String] = [:]
        for line in unfolded {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return headers
    }

    nonisolated private static func parameter(named name: String, in header: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?:^|;)\\s*\(escapedName)\\s*=\\s*(?:\"([^\"]*)\"|([^;\\s]*))"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(
                in: header,
                range: NSRange(header.startIndex..., in: header)
              ) else {
            return nil
        }
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            if let range = Range(match.range(at: index), in: header) {
                return String(header[range])
            }
        }
        return nil
    }

    nonisolated private static func multipartChildren(body: String, boundary: String) -> [String] {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized
            .components(separatedBy: "--\(boundary)")
            .dropFirst()
            .compactMap { component in
                guard !component.hasPrefix("--") else { return nil }
                return component.trimmingCharacters(in: .newlines)
            }
    }

    nonisolated private static func decodedBody(
        _ body: String,
        transferEncoding: String
    ) -> Data {
        switch transferEncoding.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "base64":
            return Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return decodeQuotedPrintable(body)
        default:
            return body.data(using: .utf8) ?? Data()
        }
    }

    nonisolated private static func decodeQuotedPrintable(_ value: String) -> Data {
        let bytes = Array(value.utf8)
        var output: [UInt8] = []
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
                    output.append(high * 16 + low)
                    index += 3
                    continue
                }
            }
            output.append(bytes[index])
            index += 1
        }
        return Data(output)
    }

    nonisolated private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}
