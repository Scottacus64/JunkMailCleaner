import Foundation

nonisolated struct BrandImpersonationAnalysis: Sendable {
    let score: Int
    let riskLevel: SenderRiskLevel
    let reason: String?
    let claimedBrand: String?
    let senderDomain: String?

    nonisolated static let none = BrandImpersonationAnalysis(
        score: 0,
        riskLevel: .low,
        reason: nil,
        claimedBrand: nil,
        senderDomain: nil
    )
}

nonisolated enum BrandImpersonationAnalyzer {
    nonisolated private struct BrandDefinition: Sendable {
        let name: String
        let displayNameTokens: Set<String>
        let allowedDomains: Set<String>
    }

    nonisolated private static let domainMismatchScore = 60

    // Keep brand identities and their explicitly trusted registrable domains
    // together so this list can be reviewed and extended in one place.
    nonisolated private static let brands: [BrandDefinition] = [
        BrandDefinition(
            name: "Microsoft",
            displayNameTokens: ["microsoft", "outlook", "onedrive"],
            allowedDomains: [
                "microsoft.com", "microsoftonline.com", "microsoft365.com",
                "microsoftstore.com", "office.com", "office365.com",
                "onedrive.com", "windows.com", "azure.com"
            ]
        ),
        BrandDefinition(
            name: "AARP",
            displayNameTokens: ["aarp"],
            allowedDomains: ["aarp.org"]
        ),
        BrandDefinition(
            name: "Walmart",
            displayNameTokens: ["walmart"],
            allowedDomains: ["walmart.com"]
        ),
        BrandDefinition(
            name: "CVS",
            displayNameTokens: ["cvs"],
            allowedDomains: ["cvs.com"]
        ),
        BrandDefinition(
            name: "PayPal",
            displayNameTokens: ["paypal"],
            allowedDomains: ["paypal.com"]
        ),
        BrandDefinition(
            name: "Amazon",
            displayNameTokens: ["amazon"],
            allowedDomains: ["amazon.com"]
        ),
        BrandDefinition(
            name: "Apple",
            displayNameTokens: ["apple"],
            allowedDomains: ["apple.com"]
        )
    ]

    nonisolated static func analyze(
        senderDisplayName: String,
        senderAddress: String
    ) -> BrandImpersonationAnalysis {
        let senderDomain = domain(from: senderAddress)
        guard let brand = claimedBrand(in: senderDisplayName) else {
            return BrandImpersonationAnalysis(
                score: 0,
                riskLevel: .low,
                reason: nil,
                claimedBrand: nil,
                senderDomain: senderDomain
            )
        }

        guard let senderDomain, !isAllowed(senderDomain, for: brand) else {
            return BrandImpersonationAnalysis(
                score: 0,
                riskLevel: .low,
                reason: nil,
                claimedBrand: brand.name,
                senderDomain: senderDomain
            )
        }

        return BrandImpersonationAnalysis(
            score: domainMismatchScore,
            riskLevel: .medium,
            reason: "Brand/domain mismatch: \(brand.name)",
            claimedBrand: brand.name,
            senderDomain: senderDomain
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
        return brands.first { !$0.displayNameTokens.isDisjoint(with: tokens) }
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
