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
        let allowedDomains: Set<String>
    }

    nonisolated private static let domainMismatchScore = 60
    nonisolated private static let strongDomainMismatchScore = 80

    // Keep brand identities and their explicitly trusted registrable domains
    // together so this list can be reviewed and extended in one place.
    nonisolated private static let brands: [BrandDefinition] = [
        BrandDefinition(
            name: "DocuSign",
            displayNameAliases: [["docusign"], ["docu", "sign"]],
            allowedDomains: ["docusign.com", "docusign.net"]
        ),
        BrandDefinition(
            name: "Microsoft",
            displayNameAliases: [["microsoft"], ["outlook"], ["onedrive"]],
            allowedDomains: [
                "microsoft.com", "microsoftonline.com", "microsoft365.com",
                "microsoftstore.com", "office.com", "office365.com",
                "onedrive.com", "windows.com", "azure.com"
            ]
        ),
        BrandDefinition(
            name: "AARP",
            displayNameAliases: [["aarp"]],
            allowedDomains: ["aarp.org"]
        ),
        BrandDefinition(
            name: "Walmart",
            displayNameAliases: [["walmart"]],
            allowedDomains: ["walmart.com"]
        ),
        BrandDefinition(
            name: "CVS",
            displayNameAliases: [["cvs"]],
            allowedDomains: ["cvs.com"]
        ),
        BrandDefinition(
            name: "PayPal",
            displayNameAliases: [["paypal"]],
            allowedDomains: ["paypal.com"]
        ),
        BrandDefinition(
            name: "Amazon",
            displayNameAliases: [["amazon"]],
            allowedDomains: ["amazon.com"]
        ),
        BrandDefinition(
            name: "Apple",
            displayNameAliases: [["apple"]],
            allowedDomains: ["apple.com"]
        ),
        BrandDefinition(
            name: "Geek Squad",
            displayNameAliases: [["geek", "squad"], ["geeksquad"]],
            allowedDomains: ["bestbuy.com", "geeksquad.com"]
        )
    ]

    nonisolated static func analyze(
        senderDisplayName: String,
        senderAddress: String,
        subject: String = "",
        body: String = "",
        decodedMessageText: String = ""
    ) -> BrandImpersonationAnalysis {
        let senderDomain = domain(from: senderAddress)
        let displayNameBrand = claimedBrand(in: senderDisplayName)
        let claimsDocuSign = displayNameBrand?.name == "DocuSign"
            || claimsDocuSignNotification(
                in: [subject, body, decodedMessageText].joined(separator: "\n")
            )
        let brand = claimsDocuSign
            ? brands.first(where: { $0.name == "DocuSign" })
            : displayNameBrand
        guard let brand else {
            return BrandImpersonationAnalysis(
                score: 0,
                riskLevel: .low,
                reason: nil,
                claimedBrand: nil,
                senderDomain: senderDomain,
                isTrustedBrandDomain: nil,
                isAutoDeleteCandidate: false
            )
        }

        let isTrusted = senderDomain.map { isAllowed($0, for: brand) } ?? false
        guard !isTrusted else {
            return BrandImpersonationAnalysis(
                score: 0,
                riskLevel: .low,
                reason: nil,
                claimedBrand: brand.name,
                senderDomain: senderDomain,
                isTrustedBrandDomain: true,
                isAutoDeleteCandidate: false
            )
        }

        if brand.name == "DocuSign" {
            return BrandImpersonationAnalysis(
                score: strongDomainMismatchScore,
                riskLevel: .high,
                reason: "DocuSign impersonation: sender domain is not trusted",
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

    nonisolated private static func claimedBrand(in displayName: String) -> BrandDefinition? {
        let tokens = Set(
            displayName
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
        return brands.first { brand in
            brand.displayNameAliases.contains { aliasTokens in
                aliasTokens.isSubset(of: tokens)
            }
        }
    }

    nonisolated private static func claimsDocuSignNotification(in value: String) -> Bool {
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard normalized.range(
            of: #"(?<![a-z0-9])doc\s*u\s*sign(?![a-z0-9])"#,
            options: .regularExpression
        ) != nil else {
            return false
        }

        let notificationPatterns = [
            #"\bplease\s+(?:review|sign)\b"#,
            #"\breview\s+(?:and|&)\s+(?:e[- ]?sign|sign)\b"#,
            #"\bsignature\s+(?:is\s+)?requested\b"#,
            #"\bneeds?\s+your\s+signature\b"#,
            #"\bsent\s+you\s+(?:a|an|the)\s+(?:new\s+)?document\b"#,
            #"\bdocument\s+(?:is\s+)?(?:ready|waiting|available)\s+(?:for\s+)?(?:your\s+)?(?:review|signature)\b"#,
            #"\b(?:view|review|complete)\s+(?:the\s+)?(?:completed\s+)?(?:document|envelope)\b"#,
            #"\bdoc\s*u\s*sign\s+(?:envelope|notification|signature request)\b"#
        ]
        return notificationPatterns.contains { pattern in
            normalized.range(of: pattern, options: .regularExpression) != nil
        }
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
