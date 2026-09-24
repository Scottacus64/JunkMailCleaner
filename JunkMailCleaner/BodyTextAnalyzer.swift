import Foundation

nonisolated struct BodyTextAnalysis: Sendable {
    let score: Int
    let riskLevel: SenderRiskLevel
    let reason: String?
    let isAutoDeleteCandidate: Bool
    let suspiciousTokens: [String]
    let protectedTokens: [String]

    nonisolated static let none = BodyTextAnalysis(
        score: 0,
        riskLevel: .low,
        reason: nil,
        isAutoDeleteCandidate: false,
        suspiciousTokens: [],
        protectedTokens: []
    )
}

nonisolated enum BodyTextAnalyzer {
    nonisolated private static let highRiskThreshold = 70
    nonisolated private static let mediumRiskThreshold = 35
    nonisolated private static let autoDeleteThreshold = 75

    nonisolated private static let protectedWords: Set<String> = [
        "paypal", "amazon", "microsoft", "apple", "account", "invoice",
        "refund", "transaction", "payment", "paid", "cancel", "support",
        "security", "purchase", "order", "charge"
    ]

    nonisolated private static let recognizedWords: Set<String> = protectedWords.union([
        "access", "please", "evidence", "tollfree", "product", "sales",
        "regarding", "giftcard", "obtain"
    ])

    nonisolated static func analyze(_ body: String) -> BodyTextAnalysis {
        guard !body.isEmpty else { return .none }

        var suspiciousTokens: [String] = []
        var protectedTokens: [String] = []

        for chunk in body.split(whereSeparator: \Character.isWhitespace) {
            let rawChunk = trimBoundaryPunctuation(String(chunk))
            guard !rawChunk.isEmpty, !isExcludedStructuredToken(rawChunk) else {
                continue
            }

            for token in candidateTokens(in: rawChunk) {
                guard let normalizedWord = normalizedWord(for: token) else {
                    continue
                }
                suspiciousTokens.append(token)
                if protectedWords.contains(normalizedWord) {
                    protectedTokens.append(token)
                }
            }
        }

        guard !suspiciousTokens.isEmpty else { return .none }

        let baseScore: Int
        switch suspiciousTokens.count {
        case 1:
            baseScore = 5
        case 2...3:
            baseScore = 15
        case 4...6:
            baseScore = 30
        default:
            baseScore = 50
        }

        let protectedWordBonus: Int
        switch protectedTokens.count {
        case 0:
            protectedWordBonus = 0
        case 1:
            protectedWordBonus = 15
        default:
            protectedWordBonus = 30
        }

        let score = min(baseScore + protectedWordBonus, 100)
        let riskLevel: SenderRiskLevel
        switch score {
        case highRiskThreshold...:
            riskLevel = .high
        case mediumRiskThreshold..<highRiskThreshold:
            riskLevel = .medium
        default:
            riskLevel = .low
        }

        var reasons = ["Obfuscated words in message body (\(suspiciousTokens.count) found)"]
        if !protectedTokens.isEmpty {
            reasons.append(
                "Obfuscated payment/brand terms: "
                    + protectedTokens.prefix(3).joined(separator: ", ")
            )
        } else if suspiciousTokens.count >= 4 {
            reasons.append("Repeated symbol substitutions inside words")
        }

        return BodyTextAnalysis(
            score: score,
            riskLevel: riskLevel,
            reason: reasons.joined(separator: "; "),
            isAutoDeleteCandidate: score >= autoDeleteThreshold
                && suspiciousTokens.count >= 7
                && protectedTokens.count >= 2,
            suspiciousTokens: suspiciousTokens,
            protectedTokens: protectedTokens
        )
    }

    nonisolated static func shouldInspectBody(
        senderDisplayName: String,
        subject: String
    ) -> Bool {
        let preliminaryText = senderDisplayName + " " + subject
        if analyze(preliminaryText).score > 0 {
            return true
        }

        let normalizedText = preliminaryText.lowercased()
        return protectedWords.contains { word in
            normalizedText.range(
                of: #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#,
                options: .regularExpression
            ) != nil
        }
    }

    nonisolated private static func trimBoundaryPunctuation(_ value: String) -> String {
        value.trimmingCharacters(
            in: CharacterSet(charactersIn: "()[]{}<>,;:!?\"'“”‘’.$")
        )
    }

    nonisolated private static func isExcludedStructuredToken(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        if lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("www.") {
            return true
        }

        let patterns = [
            #"^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,63}$"#,
            #"^[A-Z][A-Z0-9_-]*\.[A-Z0-9]{1,12}$"#
        ]
        return patterns.contains { pattern in
            value.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }

    nonisolated private static func candidateTokens(in value: String) -> [String] {
        value
            .split { character in
                !(character.isASCII
                    && (character.isLetter
                        || character.isNumber
                        || character == "@"
                        || character == "_"
                        || character == "."))
            }
            .map(String.init)
    }

    nonisolated private static func normalizedWord(for token: String) -> String? {
        guard token.contains(where: isObfuscationCharacter) else { return nil }

        var variants = [""]
        for character in token.lowercased() {
            let replacements: [Character]
            switch character {
            case "@", "4": replacements = ["a"]
            case "0": replacements = ["o"]
            case "1": replacements = ["i", "l"]
            case "3": replacements = ["e"]
            case "5": replacements = ["s"]
            case "7": replacements = ["t"]
            case "_", ".": replacements = []
            default:
                guard character.isASCII && character.isLetter else { return nil }
                replacements = [character]
            }

            if replacements.isEmpty {
                continue
            }
            variants = variants.flatMap { prefix in
                replacements.map { prefix + String($0) }
            }
        }

        return variants.first(where: recognizedWords.contains)
    }

    nonisolated private static func isObfuscationCharacter(_ character: Character) -> Bool {
        "@_.013457".contains(character)
    }
}
