import Foundation

nonisolated enum SenderRiskLevel: String, Sendable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
}

nonisolated struct SenderAddressAnalysis: Sendable {
    let score: Int
    let riskLevel: SenderRiskLevel
    let reason: String
    let isAutoDeleteCandidate: Bool
}

nonisolated struct SenderDomainSyntaxAnalysis: Sendable {
    let domainSyntaxPasses: Bool
    let tldSyntaxPasses: Bool
    let isKnownPublicTLD: Bool?
    let riskPoints: Int
    let reason: String?
}

nonisolated enum SenderAddressAnalyzer {
    nonisolated private static let unknownTLDScore = 0

    nonisolated static func analyze(_ address: String) -> SenderAddressAnalysis {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmedAddress.split(separator: "@", omittingEmptySubsequences: false)

        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return makeAnalysis(
                score: 95,
                reasons: ["Malformed sender email address"],
                isAutoDeleteCandidate: false
            )
        }

        let localPart = String(parts[0])
        let domain = String(parts[1])
        var score = 0
        var reasons: [(score: Int, text: String)] = []
        var strongEvidenceCount = 0

        analyzeDomain(
            domain,
            score: &score,
            reasons: &reasons,
            strongEvidenceCount: &strongEvidenceCount
        )
        analyzeLocalPart(localPart, score: &score, reasons: &reasons)

        if reasons.isEmpty {
            return makeAnalysis(
                score: 0,
                reasons: ["No suspicious sender-address patterns"],
                isAutoDeleteCandidate: false
            )
        }

        let reasonText = reasons
            .sorted { $0.score > $1.score }
            .prefix(2)
            .map(\.text)

        let finalScore = min(score, 100)
        return makeAnalysis(
            score: finalScore,
            reasons: reasonText,
            isAutoDeleteCandidate: finalScore >= 70 && strongEvidenceCount >= 2
        )
    }

    nonisolated private static func analyzeDomain(
        _ domain: String,
        score: inout Int,
        reasons: inout [(score: Int, text: String)],
        strongEvidenceCount: inout Int
    ) {
        let syntaxAnalysis = analyzeDomainSyntax(domain)
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if let reason = syntaxAnalysis.reason, syntaxAnalysis.riskPoints > 0 {
            add(syntaxAnalysis.riskPoints, reason, score: &score, reasons: &reasons)
            strongEvidenceCount += 1
        }

        let hasValidTLD = labels.count >= 2
            && !labels.contains(where: \.isEmpty)
            && isValidLookingTLD(labels.last ?? "")
        let hostnameLabels = hasValidTLD ? Array(labels.dropLast()) : labels.filter { !$0.isEmpty }
        for label in hostnameLabels {
            let labelSignals = randomnessSignals(for: label)
            guard labelSignals.score > 0 else { continue }

            let isSubdomain = hasValidTLD && labels.count > 2
            let reason = isSubdomain
                ? labelSignals.isAlphanumeric
                    ? "Random alphanumeric subdomain"
                    : "Random-looking subdomain"
                : labelSignals.reason

            add(labelSignals.score, reason, score: &score, reasons: &reasons)
            strongEvidenceCount += labelSignals.strongSignalCount
        }
    }

    nonisolated static func analyzeDomainSyntax(_ domain: String) -> SenderDomainSyntaxAnalysis {
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let hasTLD = labels.count >= 2 && !(labels.last ?? "").isEmpty
        let tld = hasTLD ? labels.last ?? "" : ""
        let tldSyntaxPasses = hasTLD && isValidLookingTLD(tld)
        let hostnameLabels = hasTLD ? Array(labels.dropLast()) : labels
        let hostnameSyntaxPasses = !hostnameLabels.isEmpty
            && !hostnameLabels.contains(where: { !isValidDomainLabel($0) })
        let knownPublicTLD = tldSyntaxPasses
            ? knownPublicTLDs.map { $0.contains(tld.uppercased()) }
            : false

        if domain.count > 253 {
            return SenderDomainSyntaxAnalysis(
                domainSyntaxPasses: false,
                tldSyntaxPasses: tldSyntaxPasses,
                isKnownPublicTLD: knownPublicTLD,
                riskPoints: 70,
                reason: "Domain is malformed or excessively long"
            )
        }

        if !hasTLD {
            return SenderDomainSyntaxAnalysis(
                domainSyntaxPasses: false,
                tldSyntaxPasses: false,
                isKnownPublicTLD: false,
                riskPoints: 60,
                reason: "Domain has malformed TLD"
            )
        }

        if !hostnameSyntaxPasses {
            return SenderDomainSyntaxAnalysis(
                domainSyntaxPasses: false,
                tldSyntaxPasses: tldSyntaxPasses,
                isKnownPublicTLD: knownPublicTLD,
                riskPoints: 55,
                reason: "Domain contains malformed characters"
            )
        }

        if !tldSyntaxPasses {
            return SenderDomainSyntaxAnalysis(
                domainSyntaxPasses: true,
                tldSyntaxPasses: false,
                isKnownPublicTLD: false,
                riskPoints: 55,
                reason: "Domain has malformed TLD"
            )
        }

        return SenderDomainSyntaxAnalysis(
            domainSyntaxPasses: true,
            tldSyntaxPasses: true,
            isKnownPublicTLD: knownPublicTLD,
            riskPoints: knownPublicTLD == false ? unknownTLDScore : 0,
            reason: nil
        )
    }

    nonisolated private static func analyzeLocalPart(
        _ localPart: String,
        score: inout Int,
        reasons: inout [(score: Int, text: String)]
    ) {
        guard localPart.count > 24 else { return }

        let signals = randomnessSignals(for: localPart)
        if signals.score >= 30 {
            add(25, "Unusually long random-looking local part", score: &score, reasons: &reasons)
        }
    }

    nonisolated private static func randomnessSignals(for label: String) -> (
        score: Int,
        reason: String,
        isAlphanumeric: Bool,
        strongSignalCount: Int
    ) {
        let lowercased = label.lowercased()
        let benignLabels: Set<String> = [
            "bounce", "contact", "email", "hello", "info", "mail", "mailer",
            "marketing", "newsletter", "newsletters", "noreply", "no-reply",
            "notifications", "notify", "reply", "sales", "send", "smtp",
            "support", "updates", "www"
        ]

        guard label.count >= 7, !benignLabels.contains(lowercased), !lowercased.hasPrefix("xn--") else {
            return (0, "", false, 0)
        }

        let letters = label.filter(\.isLetter)
        let digitCount = label.filter(\.isNumber).count
        let uppercaseCount = label.filter(\.isUppercase).count
        let lowercaseCount = label.filter(\.isLowercase).count
        let isAlphanumeric = !letters.isEmpty && digitCount > 0
        var signalScore = 0
        var strongSignalCount = 0
        var nonEntropySignalCount = 0

        if isAlphanumeric && uppercaseCount > 0 && lowercaseCount > 0 {
            signalScore += 75
            strongSignalCount += 1
            nonEntropySignalCount += 1
        } else if isAlphanumeric && label.count >= 10 {
            signalScore += label.count >= 18 ? 60 : 35
            strongSignalCount += 1
            nonEntropySignalCount += 1
        } else if uppercaseCount > 0 && lowercaseCount > 0 {
            signalScore += 55
            strongSignalCount += 1
            nonEntropySignalCount += 1
        }

        if letters.count >= 8 {
            let vowelCount = letters.filter { "aeiou".contains($0.lowercased()) }.count
            let vowelRatio = Double(vowelCount) / Double(letters.count)
            if vowelRatio < 0.16 {
                signalScore += 30
                strongSignalCount += 1
                nonEntropySignalCount += 1
            }

            if longestConsonantRun(in: letters) >= 7 {
                signalScore += 35
                strongSignalCount += 1
                nonEntropySignalCount += 1
            }
        }

        let poorPronounceability = hasPoorPronounceability(lowercased)
        if poorPronounceability {
            signalScore += 45
            strongSignalCount += 1
            nonEntropySignalCount += 1
        }

        let rareLetterCount = lowercased.filter { "jqxz".contains($0) }.count
        if label.count >= 10 && rareLetterCount >= 2 {
            signalScore += 30
            strongSignalCount += 1
            nonEntropySignalCount += 1
        }

        if label.count >= 11 && shannonEntropy(of: lowercased) >= 3.35 {
            signalScore += 30
            strongSignalCount += 1
        }

        guard signalScore >= 40 || (signalScore >= 30 && nonEntropySignalCount > 0) else {
            return (0, "", isAlphanumeric, 0)
        }

        let reason: String
        if isAlphanumeric {
            reason = "Random alphanumeric hostname"
        } else if uppercaseCount > 0 && lowercaseCount > 0 {
            reason = "Improbable mixed-case domain label"
        } else if poorPronounceability {
            reason = "Domain label has poor pronounceability"
        } else if longestConsonantRun(in: letters) >= 7 {
            reason = "Hostname contains a long consonant sequence"
        } else {
            reason = "Random-looking hostname"
        }

        return (min(signalScore, 100), reason, isAlphanumeric, strongSignalCount)
    }

    nonisolated private static func hasPoorPronounceability(_ value: String) -> Bool {
        let letters = value.filter(\.isLetter)
        guard letters.count >= 10 else { return false }

        let commonBigrams: Set<String> = [
            "ac", "ad", "ai", "al", "am", "an", "ar", "as", "at", "be",
            "bl", "ca", "ce", "ch", "ci", "co", "ct", "de", "di", "do",
            "ea", "ec", "ed", "ee", "el", "em", "en", "er", "es", "et",
            "fi", "fo", "ge", "go", "ha", "he", "hi", "ho", "ic", "id",
            "il", "im", "in", "io", "ir", "is", "it", "ki", "la", "le",
            "li", "ll", "lo", "ly", "ma", "me", "mi", "mo", "na", "nc",
            "nd", "ne", "ng", "ni", "no", "ns", "nt", "of", "ol", "om",
            "on", "op", "or", "os", "ot", "ou", "ow", "pa", "pe", "pl",
            "po", "pr", "ra", "re", "ri", "ro", "rs", "rt", "se", "sh",
            "si", "so", "ss", "st", "su", "ta", "te", "th", "ti", "to",
            "tr", "ts", "ul", "un", "up", "ur", "us", "ut", "ve", "vi",
            "wa", "we", "wh", "wi"
        ]

        let characters = Array(letters)
        let bigrams = zip(characters, characters.dropFirst()).map { String([$0, $1]) }
        guard !bigrams.isEmpty else { return false }

        let commonCount = bigrams.filter(commonBigrams.contains).count
        return Double(commonCount) / Double(bigrams.count) < 0.20
    }

    nonisolated private static func isValidLookingTLD(_ value: String) -> Bool {
        guard (2...63).contains(value.count), isValidDomainLabel(value) else {
            return false
        }

        if value.lowercased().hasPrefix("xn--") {
            return value.count > 4
        }

        return value.allSatisfy { $0.isASCII && $0.isLetter }
    }

    nonisolated private static func isValidDomainLabel(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 63,
              value.first != "-",
              value.last != "-" else {
            return false
        }

        return value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
        }
    }

    nonisolated private static let knownPublicTLDs: Set<String>? = {
        guard let url = Bundle.main.url(
            forResource: "tlds-alpha-by-domain",
            withExtension: "txt"
        ), let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        return Set(
            contents
                .split(whereSeparator: \.isNewline)
                .lazy
                .filter { !$0.hasPrefix("#") }
                .map { $0.uppercased() }
        )
    }()

    nonisolated private static func longestConsonantRun(in characters: String) -> Int {
        var longestRun = 0
        var currentRun = 0

        for character in characters.lowercased() {
            if character.isLetter && !"aeiou".contains(character) {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }

        return longestRun
    }

    nonisolated private static func shannonEntropy(of value: String) -> Double {
        guard !value.isEmpty else { return 0 }

        let counts = Dictionary(grouping: value, by: { $0 }).mapValues(\.count)
        let length = Double(value.count)

        return counts.values.reduce(0) { entropy, count in
            let probability = Double(count) / length
            return entropy - probability * log2(probability)
        }
    }

    nonisolated private static func add(
        _ points: Int,
        _ reason: String,
        score: inout Int,
        reasons: inout [(score: Int, text: String)]
    ) {
        score += points
        if !reasons.contains(where: { $0.text == reason }) {
            reasons.append((points, reason))
        }
    }

    nonisolated private static func makeAnalysis(
        score: Int,
        reasons: [String],
        isAutoDeleteCandidate: Bool
    ) -> SenderAddressAnalysis {
        let riskLevel: SenderRiskLevel
        switch score {
        case 70...:
            riskLevel = .high
        case 35..<70:
            riskLevel = .medium
        default:
            riskLevel = .low
        }

        return SenderAddressAnalysis(
            score: score,
            riskLevel: riskLevel,
            reason: reasons.joined(separator: "; "),
            isAutoDeleteCandidate: isAutoDeleteCandidate
        )
    }
}
