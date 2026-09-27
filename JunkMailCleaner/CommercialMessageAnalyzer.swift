import Foundation

nonisolated struct CommercialMessageIndicator: Sendable, Equatable {
    let reason: String
    let score: Int
    let matches: [String]
}

nonisolated struct CommercialMessageAnalysis: Sendable {
    let score: Int
    let riskLevel: SenderRiskLevel
    let reason: String?
    let indicators: [CommercialMessageIndicator]
    let hasExplicitAdvertisingDisclosure: Bool
    let isAutoDeleteCandidate: Bool

    var hasOnlySupportingEvidence: Bool {
        score > 0 && !hasExplicitAdvertisingDisclosure
    }

    nonisolated static let none = CommercialMessageAnalysis(
        score: 0,
        riskLevel: .low,
        reason: nil,
        indicators: [],
        hasExplicitAdvertisingDisclosure: false,
        isAutoDeleteCandidate: false
    )
}

nonisolated enum CommercialMessageAnalyzer {
    nonisolated private static let explicitAdvertisingScore = 70
    nonisolated private static let bulkMailScore = 15
    nonisolated private static let callToActionScore = 10

    nonisolated private static let explicitAdvertisingPattern =
        #"\bthis[\s\p{P}]+(?:message[\s\p{P}]+)?is[\s\p{P}]+(?:an?[\s\p{P}]+|a[\s\p{P}]+paid[\s\p{P}]+)advertisement\b"#

    nonisolated private static let bulkMailPhrases = [
        "unsubscribe from future mailings",
        "unsubscribe",
        "opt out",
        "promotional offers",
        "promotional emails",
        "marketing communications",
        "you are receiving this email because"
    ]

    nonisolated private static let callToActionPhrases = [
        "try it today",
        "buy now",
        "order now",
        "shop now",
        "get started",
        "claim offer"
    ]

    nonisolated static func analyze(decodedBodyText: String) -> CommercialMessageAnalysis {
        guard !decodedBodyText.isEmpty else { return .none }

        let normalized = normalize(decodedBodyText)
        var indicators: [CommercialMessageIndicator] = []

        let hasExplicitAdvertisingDisclosure = decodedBodyText.range(
            of: explicitAdvertisingPattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        if hasExplicitAdvertisingDisclosure {
            indicators.append(
                CommercialMessageIndicator(
                    reason: "Explicit advertising disclosure",
                    score: explicitAdvertisingScore,
                    matches: ["explicit advertisement disclosure"]
                )
            )
        }

        let matchedBulkMailPhrases = matchingPhrases(bulkMailPhrases, in: normalized)
        if !matchedBulkMailPhrases.isEmpty {
            indicators.append(
                CommercialMessageIndicator(
                    reason: "Bulk-mail unsubscribe/opt-out language",
                    score: bulkMailScore,
                    matches: matchedBulkMailPhrases
                )
            )
        }

        let matchedCallToActionPhrases = matchingPhrases(callToActionPhrases, in: normalized)
        if !matchedCallToActionPhrases.isEmpty {
            indicators.append(
                CommercialMessageIndicator(
                    reason: "Commercial call-to-action",
                    score: callToActionScore,
                    matches: matchedCallToActionPhrases
                )
            )
        }

        let score = min(indicators.reduce(0) { $0 + $1.score }, 100)
        let riskLevel: SenderRiskLevel
        switch score {
        case 70...:
            riskLevel = .high
        case 35..<70:
            riskLevel = .medium
        default:
            riskLevel = .low
        }

        return CommercialMessageAnalysis(
            score: score,
            riskLevel: riskLevel,
            reason: indicators.isEmpty
                ? nil
                : indicators.map(\.reason).joined(separator: "; "),
            indicators: indicators,
            hasExplicitAdvertisingDisclosure: hasExplicitAdvertisingDisclosure,
            isAutoDeleteCandidate: hasExplicitAdvertisingDisclosure
        )
    }

    nonisolated private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[\s\p{P}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func matchingPhrases(
        _ phrases: [String],
        in normalizedText: String
    ) -> [String] {
        phrases.filter { phrase in
            normalizedText.range(
                of: #"(?<![a-z0-9])"# + NSRegularExpression.escapedPattern(for: phrase)
                    + #"(?![a-z0-9])"#,
                options: .regularExpression
            ) != nil
        }
    }
}
