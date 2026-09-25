import Foundation
import ImageIO
import Vision

nonisolated struct EmbeddedImageOCRResult: Sendable {
    let recognizedText: String
    let discoveredImageCount: Int
    let attemptedImageCount: Int
    let skippedImageCount: Int

    nonisolated static let none = EmbeddedImageOCRResult(
        recognizedText: "",
        discoveredImageCount: 0,
        attemptedImageCount: 0,
        skippedImageCount: 0
    )
}

nonisolated enum EmbeddedImageOCRAnalyzer {
    nonisolated struct ImagePart: Sendable {
        let mimeType: String
        let data: Data
    }

    nonisolated static let maximumImagesPerMessage = 3
    nonisolated static let maximumImagePartsExaminedPerMessage = 8
    nonisolated static let maximumBytesPerImage = 6 * 1_024 * 1_024
    nonisolated static let maximumTotalImageBytes = 12 * 1_024 * 1_024
    nonisolated static let minimumWidth = 200
    nonisolated static let minimumHeight = 80
    nonisolated static let minimumPixelArea = 50_000

    nonisolated private static let supportedMIMETypes: Set<String> = [
        "image/jpeg", "image/png", "image/heic", "image/heif"
    ]

    /// This method is synchronous by design and must be called away from the main actor.
    /// MailService runs the complete scan, including OCR, in a detached task.
    nonisolated static func recognizeText(in rawMessage: String) -> EmbeddedImageOCRResult {
        guard !rawMessage.isEmpty else { return .none }

        let parts = imageParts(in: rawMessage)
        guard !parts.isEmpty else { return .none }

        var texts: [String] = []
        var attemptedCount = 0
        var skippedCount = 0
        var totalBytes = 0

        for part in parts {
            log("Image MIME part discovered: \(part.mimeType)")

            guard attemptedCount < maximumImagesPerMessage else {
                skippedCount += 1
                log("Skipped: per-message image limit reached.")
                continue
            }
            guard part.data.count <= maximumBytesPerImage,
                  totalBytes + part.data.count <= maximumTotalImageBytes else {
                skippedCount += 1
                log("Skipped: image byte limit exceeded.")
                continue
            }
            guard let source = CGImageSourceCreateWithData(part.data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                skippedCount += 1
                log("Skipped: image could not be decoded.")
                continue
            }

            log("Image dimensions: \(width)x\(height)")
            guard shouldOCR(width: width, height: height) else {
                skippedCount += 1
                log("OCR skipped: image is too small.")
                continue
            }
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                skippedCount += 1
                log("Skipped: image pixels could not be decoded.")
                continue
            }

            attemptedCount += 1
            totalBytes += part.data.count
            log("OCR attempted with accurate recognition.")

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                let recognizedText = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                log(
                    recognizedText.isEmpty
                        ? "Recognized text: (none)"
                        : "Recognized text: \(recognizedText)"
                )
                if !recognizedText.isEmpty {
                    texts.append(recognizedText)
                }
            } catch {
                log("Recognition failed: \(error.localizedDescription)")
            }
        }

        return EmbeddedImageOCRResult(
            recognizedText: texts.joined(separator: "\n"),
            discoveredImageCount: parts.count,
            attemptedImageCount: attemptedCount,
            skippedImageCount: skippedCount
        )
    }

    nonisolated static func shouldOCR(width: Int, height: Int) -> Bool {
        width >= minimumWidth
            && height >= minimumHeight
            && width * height >= minimumPixelArea
    }

    nonisolated static func log(_ message: String) {
        #if DEBUG
        print("[JunkMailCleaner][OCR] \(message)")
        #endif
    }

    nonisolated static func imageParts(in rawMessage: String) -> [ImagePart] {
        var parts: [ImagePart] = []
        var discoveredCount = 0
        var decodedBytes = 0
        collectImageParts(
            from: rawMessage,
            into: &parts,
            discoveredCount: &discoveredCount,
            decodedBytes: &decodedBytes
        )
        return parts
    }

    nonisolated private static func collectImageParts(
        from entity: String,
        into parts: inout [ImagePart],
        discoveredCount: inout Int,
        decodedBytes: inout Int
    ) {
        let (headerText, body) = splitHeadersAndBody(entity)
        let headers = parsedHeaders(headerText)
        let contentType = headers["content-type"] ?? "text/plain"
        let mimeType = contentType
            .split(separator: ";", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            ?? "text/plain"

        if mimeType.hasPrefix("multipart/"),
           let boundary = parameter(named: "boundary", in: contentType) {
            for child in multipartChildren(body: body, boundary: boundary) {
                collectImageParts(
                    from: child,
                    into: &parts,
                    discoveredCount: &discoveredCount,
                    decodedBytes: &decodedBytes
                )
            }
            return
        }

        guard supportedMIMETypes.contains(mimeType) else { return }
        discoveredCount += 1
        guard discoveredCount <= maximumImagePartsExaminedPerMessage else {
            log("Image MIME part skipped: examination limit reached.")
            return
        }
        let transferEncoding = headers["content-transfer-encoding"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard let data = decodedBody(body, transferEncoding: transferEncoding),
              !data.isEmpty else {
            log("Image MIME part discovered but data could not be decoded: \(mimeType)")
            return
        }
        guard decodedBytes + data.count <= maximumTotalImageBytes else {
            log("Image MIME part skipped: total byte limit reached.")
            return
        }
        decodedBytes += data.count
        parts.append(ImagePart(mimeType: mimeType, data: data))
    }

    nonisolated private static func splitHeadersAndBody(_ entity: String) -> (String, String) {
        if let range = entity.range(of: "\r\n\r\n") {
            return (String(entity[..<range.lowerBound]), String(entity[range.upperBound...]))
        }
        if let range = entity.range(of: "\n\n") {
            return (String(entity[..<range.lowerBound]), String(entity[range.upperBound...]))
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
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        return headers
    }

    nonisolated private static func parameter(named name: String, in header: String) -> String? {
        let pattern = #"(?i)(?:^|;)\s*"#
            + NSRegularExpression.escapedPattern(for: name)
            + #"\s*=\s*(?:\"([^\"]+)\"|([^;\s]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: header,
                range: NSRange(header.startIndex..., in: header)
              ) else { return nil }

        for index in 1...2 {
            let range = match.range(at: index)
            if range.location != NSNotFound, let swiftRange = Range(range, in: header) {
                return String(header[swiftRange])
            }
        }
        return nil
    }

    nonisolated private static func multipartChildren(body: String, boundary: String) -> [String] {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        let delimiter = "--" + boundary
        return normalized
            .components(separatedBy: delimiter)
            .dropFirst()
            .compactMap { segment in
                let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != "--", !trimmed.hasPrefix("--\n") else {
                    return nil
                }
                return trimmed
            }
    }

    nonisolated private static func decodedBody(
        _ body: String,
        transferEncoding: String
    ) -> Data? {
        switch transferEncoding {
        case "base64":
            // Reject an oversized encoded body before allocating decoded storage.
            guard body.utf8.count <= (maximumBytesPerImage * 4 / 3) + 16_384 else {
                return nil
            }
            return Data(base64Encoded: body, options: .ignoreUnknownCharacters)
        case "quoted-printable":
            return decodeQuotedPrintable(body)
        default:
            return body.data(using: .isoLatin1) ?? body.data(using: .utf8)
        }
    }

    nonisolated private static func decodeQuotedPrintable(_ value: String) -> Data {
        let bytes = Array(value.utf8)
        var result = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] == 61 { // '='
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
        return result
    }

    nonisolated private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}
