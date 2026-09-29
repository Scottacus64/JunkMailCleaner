import Foundation

nonisolated struct BrandImpersonationAnalysis: Sendable {
    let score: Int
    let riskLevel: SenderRiskLevel
    let reason: String?
    let claimedBrand: String?
    let senderDomain: String?
    let isTrustedBrandDomain: Bool?
    let isAutoDeleteCandidate: Bool

    nonisolated static let none = BrandImpersonationAnalysis(
        score: 0,
        riskLevel: .low,
        reason: nil,
        claimedBrand: nil,
        senderDomain: nil,
        isTrustedBrandDomain: nil,
        isAutoDeleteCandidate: false
    )
}

nonisolated enum BrandImpersonationAnalyzer {
    nonisolated private struct BrandDefinition: Sendable {
        let name: String
        let displayNameAliases: [Set<String>]
        let contentIdentifiers: [String]
        let allowedDomains: Set<String>
        let presentationPhrases: [String]
        let actionTerms: [String]
        let minimumActionTerms: Int
        let strongScore: Int?
        let strongReason: String?
    }

    nonisolated private static let domainMismatchScore = 60
    nonisolated private static let suspiciousReplyChainBonus = 10

    // Brand identifiers, claim context, and explicitly trusted registrable domains
    // live together so new protected brands do not require a separate analyzer.
    nonisolated private static let brands: [BrandDefinition] = [
        BrandDefinition(
            name: "DocuSign",
            displayNameAliases: [["docusign"], ["docu", "sign"]],
            contentIdentifiers: ["docusign", "docu sign"],
            allowedDomains: ["docusign.com", "docusign.net"],
            presentationPhrases: [
                "please review", "please sign", "signature requested",
                "needs your signature", "sent you a document", "document is ready",
                "review the document", "complete the document", "docusign envelope"
            ],
            actionTerms: ["review", "sign", "signature", "document", "envelope"],
            minimumActionTerms: 1,
            strongScore: 80,
            strongReason: "DocuSign impersonation: sender domain is not trusted"
        ),
        BrandDefinition(
            name: "Microsoft",
            displayNameAliases: [
                ["microsoft"], ["outlook"], ["onedrive"], ["msn"],
                ["office", "365"], ["microsoft", "365"]
            ],
            contentIdentifiers: [
                "microsoft", "microsoft 365", "office 365", "outlook", "onedrive", "msn"
            ],
            allowedDomains: [
                "microsoft.com", "microsoftonline.com", "microsoft365.com",
                "microsoftstore.com", "office.com", "office365.com",
                "onedrive.com", "windows.com", "azure.com"
            ],
            presentationPhrases: [
                "microsoft account", "microsoft security", "microsoft support",
                "outlook account", "outlook security", "msn account", "msn security"
            ],
            actionTerms: [
                "phone number changed", "phone number change", "change your phone number",
                "update request", "someone submitted a request", "reject it", "not you reject",
                "security notice", "security alert", "unusual sign in", "new sign in",
                "password reset", "reset your password", "recovery phone changed",
                "recovery email changed", "account recovery request"
            ],
            minimumActionTerms: 1,
            strongScore: 95,
            strongReason: "Microsoft account/security impersonation: sender domain is not approved"
        ),
        BrandDefinition(
            name: "Alibaba",
            displayNameAliases: [["alibaba"], ["alibaba.com"]],
            contentIdentifiers: ["alibaba", "alibaba.com"],
            allowedDomains: ["alibaba.com", "alibabagroup.com"],
            presentationPhrases: [
                "alibaba.com trade center", "alibaba trade center", "trade center",
                "view inquiry", "buyer information", "seller information"
            ],
            actionTerms: [
                "invoice", "signed contract", "contract", "new order", "order",
                "purchase", "payment", "buyer", "seller", "inquiry", "quotation"
            ],
            minimumActionTerms: 2,
            strongScore: 90,
            strongReason: "Alibaba brand impersonation"
        ),
        BrandDefinition(
            name: "PayPal",
            displayNameAliases: [["paypal"]],
            contentIdentifiers: ["paypal"],
            allowedDomains: ["paypal.com"],
            presentationPhrases: [
                "paypal account", "paypal invoice", "paypal security", "paypal transaction",
                "paypal payment notification", "from paypal"
            ],
            actionTerms: [
                "invoice", "transaction", "account", "payment", "purchase", "charged",
                "debited", "refund", "verify", "verification", "password", "sign in"
            ],
            minimumActionTerms: 2,
            strongScore: 90,
            strongReason: "PayPal brand impersonation"
        ),
        BrandDefinition(
            name: "AARP",
            displayNameAliases: [["aarp"]],
            contentIdentifiers: [], allowedDomains: ["aarp.org"],
            presentationPhrases: [], actionTerms: [], minimumActionTerms: 0,
            strongScore: nil, strongReason: nil
        ),
        BrandDefinition(
            name: "Walmart",
            displayNameAliases: [["walmart"]],
            contentIdentifiers: [], allowedDomains: ["walmart.com"],
            presentationPhrases: [], actionTerms: [], minimumActionTerms: 0,
            strongScore: nil, strongReason: nil
        ),
        BrandDefinition(
            name: "CVS",
            displayNameAliases: [["cvs"]],
            contentIdentifiers: [], allowedDomains: ["cvs.com"],
            presentationPhrases: [], actionTerms: [], minimumActionTerms: 0,
            strongScore: nil, strongReason: nil
        ),
        BrandDefinition(
            name: "Amazon",
            displayNameAliases: [["amazon"]],
            contentIdentifiers: [], allowedDomains: ["amazon.com"],
            presentationPhrases: [], actionTerms: [], minimumActionTerms: 0,
            strongScore: nil, strongReason: nil
        ),
        BrandDefinition(
            name: "Apple",
            displayNameAliases: [["apple"]],
            contentIdentifiers: [], allowedDomains: ["apple.com"],
            presentationPhrases: [], actionTerms: [], minimumActionTerms: 0,
            strongScore: nil, strongReason: nil
        ),
        BrandDefinition(
            name: "Geek Squad",
            displayNameAliases: [["geek", "squad"], ["geeksquad"]],
            contentIdentifiers: [], allowedDomains: ["bestbuy.com", "geeksquad.com"],
            presentationPhrases: [], actionTerms: [], minimumActionTerms: 0,
            strongScore: nil, strongReason: nil
        )
    ]

    nonisolated static func analyze(
        senderDisplayName: String,
        senderAddress: String,
        subject: String = "",
        body: String = "",
        decodedMessageText: String = "",
        imageText: String = ""
    ) -> BrandImpersonationAnalysis {
        let senderDomain = domain(from: senderAddress)
        let normalizedDisplayName = normalize(senderDisplayName)
        let normalizedContent = normalize(
            [subject, body, decodedMessageText, imageText].joined(separator: "\n")
        )

        var matchedBrand: BrandDefinition?
        var isStrongClaim = false

        for brand in brands where brand.strongScore != nil {
            let displayClaim = displayNameMatches(normalizedDisplayName, brand: brand)
            let hasIdentifier = containsAnyPhrase(brand.contentIdentifiers, in: normalizedContent)
            let actionCount = matchingPhraseCount(brand.actionTerms, in: normalizedContent)
            let hasPresentationPhrase = containsAnyPhrase(
                brand.presentationPhrases,
                in: normalizedContent
            )
            let hasRequiredAction = brand.name == "DocuSign" && displayClaim
                || actionCount >= max(brand.minimumActionTerms, 1)
            let presentsAsBrand = displayClaim
                || hasPresentationPhrase
                || actionCount >= max(brand.minimumActionTerms, 2)

            if (displayClaim || hasIdentifier) && hasRequiredAction && presentsAsBrand
                && !isThirdPartyDiscussion(normalizedContent, brand: brand) {
                matchedBrand = brand
                isStrongClaim = true
                break
            }
        }

        if matchedBrand == nil {
            let displayBrand = claimedBrand(inNormalizedDisplayName: normalizedDisplayName)
            // Microsoft and Alibaba require contextual claim evidence. PayPal keeps its
            // prior medium display-name mismatch behavior but only becomes a deletion
            // candidate when transaction/account context establishes a strong claim.
            if displayBrand?.name != "Microsoft" && displayBrand?.name != "Alibaba" {
                matchedBrand = displayBrand
            }
        }

        guard let brand = matchedBrand else {
            return noMatch(senderDomain: senderDomain)
        }

        let isTrusted = senderDomain.map { isAllowed($0, for: brand) } ?? false
        guard !isTrusted else {
            return BrandImpersonationAnalysis(
                score: 0, riskLevel: .low, reason: nil, claimedBrand: brand.name,
                senderDomain: senderDomain, isTrustedBrandDomain: true,
                isAutoDeleteCandidate: false
            )
        }

        if isStrongClaim, let strongScore = brand.strongScore {
            let replyBonus = hasSuspiciousTransactionalReplyChain(subject)
                ? suspiciousReplyChainBonus : 0
            let score = min(100, strongScore + replyBonus)
            return BrandImpersonationAnalysis(
                score: score,
                riskLevel: .high,
                reason: brand.strongReason,
                claimedBrand: brand.name,
                senderDomain: senderDomain,
                isTrustedBrandDomain: false,
                isAutoDeleteCandidate: true
            )
        }

        return BrandImpersonationAnalysis(
            score: domainMismatchScore,
            riskLevel: .medium,
            reason: "Brand/domain mismatch: \(brand.name)",
            claimedBrand: brand.name,
            senderDomain: senderDomain,
            isTrustedBrandDomain: false,
            isAutoDeleteCandidate: false
        )
    }

    nonisolated static func isAllowedDomain(_ domain: String, for brandName: String) -> Bool {
        guard let brand = brands.first(where: { $0.name == brandName }) else { return false }
        return isAllowed(domain.lowercased(), for: brand)
    }

    nonisolated private static func noMatch(senderDomain: String?) -> BrandImpersonationAnalysis {
        BrandImpersonationAnalysis(
            score: 0, riskLevel: .low, reason: nil, claimedBrand: nil,
            senderDomain: senderDomain, isTrustedBrandDomain: nil,
            isAutoDeleteCandidate: false
        )
    }

    nonisolated private static func claimedBrand(
        inNormalizedDisplayName displayName: String
    ) -> BrandDefinition? {
        brands.first { displayNameMatches(displayName, brand: $0) }
    }

    nonisolated private static func displayNameMatches(
        _ normalizedDisplayName: String,
        brand: BrandDefinition
    ) -> Bool {
        let tokens = Set(normalizedDisplayName.split(separator: " ").map(String.init))
        return brand.displayNameAliases.contains { aliasTokens in
            aliasTokens.isSubset(of: tokens)
        }
    }

    nonisolated private static func matchingPhraseCount(
        _ phrases: [String],
        in value: String
    ) -> Int {
        phrases.reduce(into: 0) { count, phrase in
            if containsPhrase(phrase, in: value) { count += 1 }
        }
    }

    nonisolated private static func containsAnyPhrase(
        _ phrases: [String],
        in value: String
    ) -> Bool {
        phrases.contains { containsPhrase($0, in: value) }
    }

    nonisolated private static func containsPhrase(_ phrase: String, in value: String) -> Bool {
        value.range(
            of: #"(?<![a-z0-9])"#
                + NSRegularExpression.escapedPattern(for: normalize(phrase))
                    .replacingOccurrences(of: #"\ "#, with: #"\s+"#)
                + #"(?![a-z0-9])"#,
            options: .regularExpression
        ) != nil
    }

    nonisolated private static func isThirdPartyDiscussion(
        _ content: String,
        brand: BrandDefinition
    ) -> Bool {
        let discussionPhrases = [
            "news article", "newsletter", "our article", "this article", "analysis of",
            "guide to", "how to protect", "attacks against", "discussing", "we discuss",
            "products through", "sells products through", "payment method", "paid with",
            "we accept", "using paypal"
        ]
        guard containsAnyPhrase(discussionPhrases, in: content) else { return false }

        // Direct recipient-facing requests override discussion wording only when the
        // message also uses brand-specific presentation language.
        let directRequestPhrases = [
            "your account", "your order", "your invoice", "verify your", "sign in",
            "reject it", "view inquiry", "buyer information", "seller information"
        ]
        return !(containsAnyPhrase(directRequestPhrases, in: content)
            && containsAnyPhrase(brand.presentationPhrases, in: content))
    }

    nonisolated private static func hasSuspiciousTransactionalReplyChain(_ subject: String) -> Bool {
        let hasRepeatedPrefix = subject.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"^(?:(?:re|fw)\s*:\s*){2,}"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        guard hasRepeatedPrefix else { return false }
        return containsAnyPhrase(
            ["invoice", "contract", "payment", "order", "account", "transaction"],
            in: normalize(subject)
        )
    }

    nonisolated private static func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9.]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func domain(from address: String) -> String? {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return parts[1].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    nonisolated private static func isAllowed(
        _ senderDomain: String,
        for brand: BrandDefinition
    ) -> Bool {
        brand.allowedDomains.contains { allowedDomain in
            senderDomain == allowedDomain || senderDomain.hasSuffix("." + allowedDomain)
        }
    }
}
