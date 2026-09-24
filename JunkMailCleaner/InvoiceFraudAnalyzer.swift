import Foundation

nonisolated struct InvoiceFraudAnalysis: Sendable {
    let score: Int
    let riskLevel: SenderRiskLevel
    let reasons: [String]

    var reason: String? {
        reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }

    nonisolated static let none = InvoiceFraudAnalysis(
        score: 0,
        riskLevel: .low,
        reasons: []
    )
}

nonisolated enum InvoiceFraudAnalyzer {
    nonisolated private struct TransactionBrand: Sendable {
        let name: String
        let aliases: [String]
        let allowedDomains: Set<String>
    }

    nonisolated private static let freeMailInvoiceScore = 40
    nonisolated private static let brandDomainMismatchScore = 50
    nonisolated private static let supportPhoneScore = 30

    nonisolated private static let freeMailDomains: Set<String> = [
        "gmail.com", "icloud.com", "outlook.com", "hotmail.com",
        "yahoo.com", "aol.com"
    ]

    nonisolated private static let paymentIndicatorGroups: [[String]] = [
        ["invoice", "billing statement"],
        ["amount paid", "total paid"],
        ["debited", "debit"],
        ["charged", "charge"],
        ["transaction"],
        ["purchase", "purchased"],
        ["payment"],
        ["refund", "refunded"],
        ["order"]
    ]

    nonisolated private static let supportContactPhrases = [
        "customer support", "customer service", "contact support",
        "contact us", "call us", "call now", "call at", "reach us",
        "phone support", "support team"
    ]

    nonisolated private static let brands: [TransactionBrand] = [
        TransactionBrand(
            name: "PayPal",
            aliases: ["paypal"],
            allowedDomains: ["paypal.com"]
        ),
        TransactionBrand(
            name: "Venmo",
            aliases: ["venmo"],
            allowedDomains: ["venmo.com"]
        ),
        TransactionBrand(
            name: "Cash App",
            aliases: ["cash app"],
            allowedDomains: ["cash.app", "squareup.com"]
        ),
        TransactionBrand(
            name: "Apple Pay",
            aliases: ["apple pay"],
            allowedDomains: ["apple.com"]
        ),
        TransactionBrand(
            name: "Amazon",
            aliases: ["amazon"],
            allowedDomains: ["amazon.com"]
        ),
        TransactionBrand(
            name: "Walmart",
            aliases: ["walmart"],
            allowedDomains: ["walmart.com"]
        ),
        TransactionBrand(
            name: "Best Buy / Geek Squad",
            aliases: ["best buy", "geek squad"],
            allowedDomains: ["bestbuy.com", "geeksquad.com"]
        ),
        TransactionBrand(
            name: "Norton",
            aliases: ["norton"],
            allowedDomains: ["norton.com"]
        ),
        TransactionBrand(
            name: "McAfee",
            aliases: ["mcafee"],
            allowedDomains: ["mcafee.com"]
        )
    ]

    nonisolated static func analyze(
        senderAddress: String,
        subject: String,
        body: String
    ) -> InvoiceFraudAnalysis {
        let text = normalize(subject + "\n" + body)
        let paymentIndicators = matchedPaymentIndicatorCount(in: text)
        let hasStrongPaymentContext = paymentIndicators >= 3
            || (text.contains("invoice") && paymentIndicators >= 2)

        guard hasStrongPaymentContext else { return .none }

        let senderDomain = domain(from: senderAddress)
        var score = 0
        var reasons: [String] = []

        if senderDomain.map(freeMailDomains.contains) == true {
            score += freeMailInvoiceScore
            reasons.append("Invoice/payment message from free-mail account")
        }

        if let brand = claimedTransactionBrand(in: text),
           senderDomain.map({ isAllowed($0, for: brand) }) != true {
            score += brandDomainMismatchScore
            reasons.append("Financial brand/domain mismatch: \(brand.name)")
        }

        if supportContactPhrases.contains(where: text.contains), containsPhoneNumber(body) {
            score += supportPhoneScore
            reasons.append("Payment message directs recipient to support phone number")
        }

        let finalScore = min(score, 100)
        let riskLevel: SenderRiskLevel
        switch finalScore {
        case 70...:
            riskLevel = .high
        case 35..<70:
            riskLevel = .medium
        default:
            riskLevel = .low
        }

        return InvoiceFraudAnalysis(
            score: finalScore,
            riskLevel: riskLevel,
            reasons: reasons
        )
    }

    nonisolated private static func matchedPaymentIndicatorCount(in text: String) -> Int {
        paymentIndicatorGroups.count { variants in
            variants.contains(where: text.contains)
        }
    }

    nonisolated private static func claimedTransactionBrand(
        in text: String
    ) -> TransactionBrand? {
        let identityTerms = [
            "invoice", "payment", "transaction", "account", "billing",
            "receipt", "charge", "refund", "order"
        ]

        return brands.first { brand in
            brand.aliases.contains { alias in
                let isCasualPaymentOption = text.contains("accept \(alias)")
                    || text.contains("accepts \(alias)")
                    || text.contains("pay with \(alias)")
                    || text.contains("\(alias) accepted")
                guard !isCasualPaymentOption else { return false }

                return identityTerms.contains { term in
                    text.contains("\(alias) \(term)")
                        || text.contains("\(term) from \(alias)")
                        || text.contains("\(term) by \(alias)")
                }
            }
        }
    }

    nonisolated private static func containsPhoneNumber(_ text: String) -> Bool {
        let pattern = #"(?<!\d)(?:\+?1[\s.-]?)?(?:\(\d{3}\)|\d{3})[\s.-]\d{3}[\s.-]\d{4}(?!\d)"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    nonisolated private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func domain(from address: String) -> String? {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return parts[1].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    nonisolated private static func isAllowed(
        _ senderDomain: String,
        for brand: TransactionBrand
    ) -> Bool {
        brand.allowedDomains.contains { allowedDomain in
            senderDomain == allowedDomain || senderDomain.hasSuffix("." + allowedDomain)
        }
    }
}
