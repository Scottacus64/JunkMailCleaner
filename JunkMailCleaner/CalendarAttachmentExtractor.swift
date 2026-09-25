import Foundation

nonisolated struct CalendarAttachmentExtraction: Sendable {
    let text: String
    let hasCalendarPart: Bool

    nonisolated static let none = CalendarAttachmentExtraction(
        text: "",
        hasCalendarPart: false
    )
}

nonisolated enum CalendarAttachmentExtractor {
    nonisolated private static let maximumCalendarParts = 4
    nonisolated private static let maximumBytesPerPart = 1_048_576
    nonisolated private static let maximumTotalBytes = 2_097_152

    nonisolated static func extract(from rawMessage: String) -> CalendarAttachmentExtraction {
        guard !rawMessage.isEmpty else { return .none }

        var extractedTexts: [String] = []
        var totalBytes = 0
        collectCalendarParts(
            from: rawMessage,
            extractedTexts: &extractedTexts,
            totalBytes: &totalBytes
        )

        return CalendarAttachmentExtraction(
            text: extractedTexts.joined(separator: "\n"),
            hasCalendarPart: !extractedTexts.isEmpty
        )
    }

    nonisolated private static func collectCalendarParts(
        from entity: String,
        extractedTexts: inout [String],
        totalBytes: inout Int
    ) {
        guard extractedTexts.count < maximumCalendarParts,
              totalBytes < maximumTotalBytes else {
            return
        }

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
                collectCalendarParts(
                    from: child,
                    extractedTexts: &extractedTexts,
                    totalBytes: &totalBytes
                )
            }
            return
        }

        let dispositionHeader = headers["content-disposition"] ?? ""
        let filename = parameter(named: "filename", in: dispositionHeader)
            ?? parameter(named: "name", in: contentTypeHeader)
        let isCalendar = contentType == "text/calendar"
            || filename?.lowercased().hasSuffix(".ics") == true
        guard isCalendar else { return }

        let data = decodedBody(
            body,
            transferEncoding: headers["content-transfer-encoding"] ?? ""
        )
        guard !data.isEmpty,
              data.count <= maximumBytesPerPart,
              totalBytes + data.count <= maximumTotalBytes else {
            return
        }

        let decodedText = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        guard !decodedText.isEmpty else { return }

        totalBytes += data.count
        extractedTexts.append(usefulCalendarText(from: decodedText))
        print(
            "[JunkMailCleaner][Calendar] Extracted \(data.count) bytes from "
                + "\(contentType)\(filename.map { " (\($0))" } ?? "")."
        )
    }

    nonisolated private static func usefulCalendarText(from value: String) -> String {
        let unfolded = value.replacingOccurrences(
            of: #"\r?\n[ \t]"#,
            with: "",
            options: .regularExpression
        )
        let usefulProperties: Set<String> = [
            "BEGIN", "METHOD", "SUMMARY", "DESCRIPTION", "LOCATION", "ORGANIZER", "ATTENDEE"
        ]
        let selectedLines = unfolded
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let property = line[..<colon]
                    .split(separator: ";", maxSplits: 1)
                    .first?
                    .uppercased() ?? ""
                guard usefulProperties.contains(property) else { return nil }
                return line
            }

        let selected = selectedLines.isEmpty ? unfolded : selectedLines.joined(separator: "\n")
        return selected
            .replacingOccurrences(of: #"\\[nN]"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
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
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return headers
    }

    nonisolated private static func parameter(named name: String, in header: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?:^|;)\\s*\(escapedName)\\s*=\\s*(?:\"([^\"]*)\"|([^;\\s]*))"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(header.startIndex..., in: header)
        guard let match = expression.firstMatch(in: header, range: range) else { return nil }
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            if let swiftRange = Range(match.range(at: index), in: header) {
                return String(header[swiftRange])
            }
        }
        return nil
    }

    nonisolated private static func multipartChildren(body: String, boundary: String) -> [String] {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        let delimiter = "--\(boundary)"
        return normalized
            .components(separatedBy: delimiter)
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
