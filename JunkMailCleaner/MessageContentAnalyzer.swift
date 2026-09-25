import Foundation

nonisolated enum MessageContentCategory: String, Sendable {
    case replyToMismatch = "reply-to mismatch"
    case targetedReplyInstruction = "targeted reply instruction"
    case lotteryPrize = "lottery/prize"
    case donation = "donation"
    case donationCode = "donation code"
    case unsolicitedSelection = "unsolicited selection"
    case beneficiaryInheritance = "beneficiary/inheritance"
    case advanceFee = "advance fee"
    case replyInstruction = "reply instruction"
    case largeMoney = "large money"
    case confidentiality = "confidentiality"
    case urgency = "urgency"
    case giftCardReward = "gift-card/reward"
    case bitcoin = "bitcoin"
}

nonisolated struct MessageContentAnalysis: Sendable {
    let score: Int
    let riskLevel: SenderRiskLevel
    let reason: String
    let isAutoDeleteCandidate: Bool
    let replyToAddress: String?
    let categories: Set<MessageContentCategory>

    nonisolated static let skipped = MessageContentAnalysis(
        score: 0,
        riskLevel: .low,
        reason: "Content analysis skipped",
        isAutoDeleteCandidate: false,
        replyToAddress: nil,
        categories: []
    )
}

nonisolated struct CombinedMessageAnalysis: Sendable {
    let score: Int
    let riskLevel: SenderRiskLevel
    let reason: String
    let isAutoDeleteCandidate: Bool
}

nonisolated enum MessageContentAnalyzer {
    nonisolated private static let highRiskThreshold = 70
    nonisolated private static let mediumRiskThreshold = 35
    nonisolated private static let autoDeleteThreshold = 75

    nonisolated static func analyze(
        senderDisplayName: String,
        fromAddress: String,
        replyTo: String,
        subject: String,
        body: String
    ) -> MessageContentAnalysis {
        let normalizedSenderDisplayName = normalize(senderDisplayName)
        let normalizedFromAddress = normalize(fromAddress)
        let normalizedSubject = normalize(subject)
        let normalizedBody = normalize(body)
        let searchableText = [
            normalizedSenderDisplayName,
            normalizedFromAddress,
            normalizedSubject,
            normalizedBody
        ].joined(separator: "\n")
        let extractedFromAddress = extractEmailAddress(from: fromAddress)
        let normalizedReplyToAddress = extractEmailAddress(from: replyTo)
        let fromDomain = extractedFromAddress.flatMap(domain)
        let replyToDomain = normalizedReplyToAddress.flatMap(domain)
        let hasReplyToMismatch = fromDomain != nil
            && replyToDomain != nil
            && fromDomain != replyToDomain

        var categories: Set<MessageContentCategory> = []
        if containsBitcoinReference(searchableText) {
            categories.insert(.bitcoin)
        }
        if hasReplyToMismatch {
            categories.insert(.replyToMismatch)
        }
        if containsAny(searchableText, phrases: lotteryPrizePhrases) {
            categories.insert(.lotteryPrize)
        }
        if containsAny(searchableText, phrases: donationPhrases) {
            categories.insert(.donation)
        }
        if containsAny(searchableText, phrases: donationCodePhrases) {
            categories.insert(.donationCode)
        }
        if containsAny(searchableText, phrases: selectionPhrases) {
            categories.insert(.unsolicitedSelection)
        }
        if containsAny(searchableText, phrases: beneficiaryPhrases) {
            categories.insert(.beneficiaryInheritance)
        }
        if containsAny(searchableText, phrases: advanceFeePhrases) {
            categories.insert(.advanceFee)
        }
        if containsAny(searchableText, phrases: replyInstructionPhrases) {
            categories.insert(.replyInstruction)
        }
        if containsAny(searchableText, phrases: confidentialityPhrases) {
            categories.insert(.confidentiality)
        }
        if containsAny(normalizedSubject, phrases: urgencyPhrases) {
            categories.insert(.urgency)
        }
        if containsAny(normalizedSubject, phrases: giftCardRewardPhrases) {
            categories.insert(.giftCardReward)
        }
        if hasLargeMonetaryClaim(in: searchableText) {
            categories.insert(.largeMoney)
        }

        let explicitlyTargetsReplyTo = normalizedReplyToAddress.map {
            normalizedBody.contains($0)
                && containsAny(normalizedBody, phrases: replyInstructionPhrases)
        } ?? false
        if hasReplyToMismatch && explicitlyTargetsReplyTo {
            categories.insert(.targetedReplyInstruction)
        }

        return score(categories: categories, replyToAddress: normalizedReplyToAddress)
    }

    nonisolated static func shouldLoadBody(after preliminaryAnalysis: MessageContentAnalysis) -> Bool {
        guard preliminaryAnalysis.riskLevel != .high else { return false }

        let bodyWorthyCategories: Set<MessageContentCategory> = [
            .lotteryPrize,
            .donation,
            .donationCode,
            .unsolicitedSelection,
            .beneficiaryInheritance,
            .advanceFee,
            .replyInstruction,
            .confidentiality
        ]
        return !preliminaryAnalysis.categories.isDisjoint(with: bodyWorthyCategories)
    }

    nonisolated private static func score(
        categories: Set<MessageContentCategory>,
        replyToAddress: String?
    ) -> MessageContentAnalysis {
        if categories.contains(.bitcoin) {
            return MessageContentAnalysis(
                score: 100,
                riskLevel: .high,
                reason: "Contains Bitcoin reference",
                isAutoDeleteCandidate: true,
                replyToAddress: replyToAddress,
                categories: categories
            )
        }

        let coreCategories: Set<MessageContentCategory> = [
            .lotteryPrize,
            .donation,
            .donationCode,
            .unsolicitedSelection,
            .beneficiaryInheritance,
            .advanceFee
        ]
        let coreCount = categories.intersection(coreCategories).count
        let hasLargeMoney = categories.contains(.largeMoney)
        let hasReplyInstruction = categories.contains(.replyInstruction)
        let hasTargetedReply = categories.contains(.targetedReplyInstruction)

        var score = 0
        if categories.contains(.replyToMismatch) { score += 10 }
        if categories.contains(.lotteryPrize) { score += 20 }
        if categories.contains(.donation) { score += 15 }
        if categories.contains(.donationCode) { score += 20 }
        if categories.contains(.unsolicitedSelection) { score += 15 }
        if categories.contains(.beneficiaryInheritance) { score += 20 }
        if categories.contains(.advanceFee) { score += 20 }
        if categories.contains(.replyInstruction) { score += 10 }
        if categories.contains(.targetedReplyInstruction) { score += 25 }
        if categories.contains(.confidentiality) { score += 5 }
        if categories.contains(.urgency) { score += 10 }
        if categories.contains(.giftCardReward) { score += 10 }

        if hasLargeMoney && coreCount > 0 { score += 20 }
        if coreCount >= 2 { score += 20 }
        if coreCount >= 3 { score += 10 }
        if coreCount > 0 && hasLargeMoney && hasReplyInstruction { score += 25 }

        let finalScore = min(score, 100)
        let hasHighConfidenceCombination =
            (coreCount >= 2 && (hasLargeMoney || hasReplyInstruction || hasTargetedReply))
            || (coreCount > 0 && hasLargeMoney && hasReplyInstruction)
            || (coreCount > 0 && hasLargeMoney && hasTargetedReply)
        let isAutoDeleteCandidate = finalScore >= autoDeleteThreshold
            && hasHighConfidenceCombination

        let riskLevel: SenderRiskLevel
        switch finalScore {
        case highRiskThreshold...:
            riskLevel = .high
        case mediumRiskThreshold..<highRiskThreshold:
            riskLevel = .medium
        default:
            riskLevel = .low
        }

        return MessageContentAnalysis(
            score: finalScore,
            riskLevel: riskLevel,
            reason: reason(for: categories, coreCount: coreCount),
            isAutoDeleteCandidate: isAutoDeleteCandidate,
            replyToAddress: replyToAddress,
            categories: categories
        )
    }

    nonisolated private static func reason(
        for categories: Set<MessageContentCategory>,
        coreCount: Int
    ) -> String {
        var reasons: [String] = []

        if categories.contains(.lotteryPrize) && categories.contains(.donation) {
            reasons.append("Lottery/donation scam pattern")
        } else if categories.contains(.lotteryPrize) {
            reasons.append("Lottery/prize scam pattern")
        } else if categories.contains(.donation) {
            reasons.append("Donation scam pattern")
        } else if categories.contains(.beneficiaryInheritance) {
            reasons.append("Inheritance/beneficiary language")
        } else if categories.contains(.advanceFee) {
            reasons.append("Advance-fee language")
        } else if categories.contains(.unsolicitedSelection) {
            reasons.append("Unsolicited-selection language")
        }

        if categories.contains(.donationCode) && !categories.contains(.donation) {
            reasons.append("Donation-code request")
        }
        if categories.contains(.largeMoney) && coreCount > 0 {
            reasons.append("Large monetary claim")
        }
        if categories.contains(.replyToMismatch) {
            reasons.append("Reply-To domain mismatch")
        }
        if categories.contains(.targetedReplyInstruction) {
            reasons.append("Explicit reply instruction")
        } else if categories.contains(.replyInstruction) && coreCount > 0 {
            reasons.append("Reply/contact instruction")
        }
        if reasons.isEmpty && categories.contains(.urgency) {
            reasons.append("Urgent-response phrase")
        }
        if reasons.isEmpty && categories.contains(.giftCardReward) {
            reasons.append("Gift-card/reward phrase")
        }
        if reasons.isEmpty && categories.contains(.confidentiality) {
            reasons.append("Confidentiality request")
        }
        if reasons.isEmpty && categories.contains(.replyInstruction) {
            reasons.append("Reply/contact instruction")
        }

        return reasons.isEmpty ? "No suspicious message-content patterns" : reasons.joined(separator: "; ")
    }

    nonisolated private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    nonisolated private static func containsAny(_ value: String, phrases: [String]) -> Bool {
        phrases.contains(where: value.contains)
    }

    nonisolated private static func containsBitcoinReference(_ value: String) -> Bool {
        value.contains("bitcoin") || value.contains("bit coin")
    }

    nonisolated private static func extractEmailAddress(from value: String) -> String? {
        let pattern = #"[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9.-]+"#
        guard let range = value.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }
        return String(value[range]).lowercased()
    }

    nonisolated private static func domain(of address: String) -> String? {
        address.split(separator: "@", maxSplits: 1).last.map {
            $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
    }

    nonisolated private static func hasLargeMonetaryClaim(in value: String) -> Bool {
        let patterns = [
            #"(?:[$€£]\s*)?\d+(?:[.,]\d+)?\s*(?:million|billion)\b(?:\s*(?:usd|dollars?))?"#,
            #"\b(?:usd\s*)?[$€£]?\s*\d{1,3}(?:,\d{3}){2,}(?:\.\d+)?\b"#,
            #"\bmillions? of (?:us )?dollars\b"#
        ]
        return patterns.contains { pattern in
            value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    nonisolated private static let lotteryPrizePhrases = [
        "lottery winner", "lottery winnings", "jackpot winner", "mega millions",
        "claim your winnings", "claim your prize", "cash prize", "prize winner",
        "selected winner", "claim your reward"
    ]
    nonisolated private static let donationPhrases = [
        "donation code", "i am donating", "we are donating", "donate the sum",
        "financial assistance", "compensation fund"
    ]
    nonisolated private static let donationCodePhrases = ["donation code"]
    nonisolated private static let selectionPhrases = [
        "you have been selected", "your email was selected", "randomly selected"
    ]
    nonisolated private static let beneficiaryPhrases = [
        "beneficiary", "inheritance", "unclaimed funds"
    ]
    nonisolated private static let advanceFeePhrases = [
        "processing fee", "release fee", "transfer fee", "delivery fee"
    ]
    nonisolated private static let replyInstructionPhrases = [
        "reply with", "reply to this email", "reply immediately", "urgent reply",
        "contact me at", "contact the", "email me at", "send your reply"
    ]
    nonisolated private static let confidentialityPhrases = [
        "keep this confidential", "strictly confidential", "confidential transaction"
    ]
    nonisolated private static let urgencyPhrases = [
        "urgent response", "urgent reply", "reply immediately", "act immediately",
        "final notice", "payment pending"
    ]
    nonisolated private static let giftCardRewardPhrases = [
        "gift card", "claim your reward"
    ]
}

nonisolated enum CombinedMessageAnalyzer {
    nonisolated static func combine(
        senderAnalysis: SenderAddressAnalysis,
        contentAnalysis: MessageContentAnalysis,
        bodyTextAnalysis: BodyTextAnalysis,
        microsoftImpersonationAnalysis: MicrosoftImpersonationAnalysis,
        brandImpersonationAnalysis: BrandImpersonationAnalysis = .none,
        invoiceFraudAnalysis: InvoiceFraudAnalysis = .none,
        calendarInviteFraudAnalysis: CalendarInviteFraudAnalysis = .none
    ) -> CombinedMessageAnalysis {
        let riskLevel: SenderRiskLevel
        if senderAnalysis.riskLevel == .high
            || contentAnalysis.riskLevel == .high
            || bodyTextAnalysis.riskLevel == .high
            || microsoftImpersonationAnalysis.riskLevel == .high
            || invoiceFraudAnalysis.riskLevel == .high
            || calendarInviteFraudAnalysis.riskLevel == .high {
            riskLevel = .high
        } else if senderAnalysis.riskLevel == .medium
            || contentAnalysis.riskLevel == .medium
            || bodyTextAnalysis.riskLevel == .medium
            || brandImpersonationAnalysis.riskLevel == .medium
            || invoiceFraudAnalysis.riskLevel == .medium
            || calendarInviteFraudAnalysis.riskLevel == .medium {
            riskLevel = .medium
        } else {
            riskLevel = .low
        }

        var reasons: [String] = []
        if senderAnalysis.score > 0 {
            reasons.append(senderAnalysis.reason)
        }
        if contentAnalysis.score > 0 {
            reasons.append(contentAnalysis.reason)
        }
        if let reason = bodyTextAnalysis.reason {
            reasons.append(reason)
        }
        if let reason = microsoftImpersonationAnalysis.reason {
            reasons.append(reason)
        }
        if let reason = brandImpersonationAnalysis.reason,
           microsoftImpersonationAnalysis.reason == nil
            || brandImpersonationAnalysis.claimedBrand != "Microsoft" {
            reasons.append(reason)
        }
        if let reason = invoiceFraudAnalysis.reason {
            reasons.append(reason)
        }
        if let reason = calendarInviteFraudAnalysis.reason {
            reasons.append(reason)
        }
        if reasons.isEmpty {
            reasons.append(senderAnalysis.reason)
        }

        return CombinedMessageAnalysis(
            score: max(
                senderAnalysis.score,
                contentAnalysis.score,
                bodyTextAnalysis.score,
                microsoftImpersonationAnalysis.score,
                brandImpersonationAnalysis.score,
                invoiceFraudAnalysis.score,
                calendarInviteFraudAnalysis.score
            ),
            riskLevel: riskLevel,
            reason: reasons.joined(separator: "; "),
            isAutoDeleteCandidate: senderAnalysis.isHighRiskForAutomaticDeletion
                || contentAnalysis.isAutoDeleteCandidate
                || bodyTextAnalysis.isAutoDeleteCandidate
                || microsoftImpersonationAnalysis.riskLevel == .high
                || calendarInviteFraudAnalysis.isAutoDeleteCandidate
        )
    }
}
