import Foundation

nonisolated struct CalendarInviteFraudAnalysis: Sendable {
    let score: Int
    let riskLevel: SenderRiskLevel
    let reason: String?
    let isAutoDeleteCandidate: Bool
    let hasFinancialLanguage: Bool
    let hasCurrencyAmount: Bool

    nonisolated static let none = CalendarInviteFraudAnalysis(
        score: 0,
        riskLevel: .low,
        reason: nil,
        isAutoDeleteCandidate: false,
        hasFinancialLanguage: false,
        hasCurrencyAmount: false
    )
}

nonisolated enum CalendarInviteFraudAnalyzer {
    nonisolated static let singleSignalScore = 75
    nonisolated static let combinedSignalScore = 100

    nonisolated static func analyze(
        subject: String,
        body: String,
        calendarText: String,
        hasCalendarPart: Bool
    ) -> CalendarInviteFraudAnalysis {
        let subjectText = normalize(subject)
        let calendarBodyText = normalize([body, calendarText].joined(separator: "\n"))
        let searchableText = [subjectText, calendarBodyText].joined(separator: "\n")
        let hasCalendarEvidence = hasCalendarPart
            || subjectText.range(
                of: #"\binvitation\s*:"#,
                options: .regularExpression
            ) != nil
            || containsAny(calendarBodyText, phrases: [
                "begin:vcalendar", "begin:vevent", "method:request",
                "calendar invitation", "event invitation", "meeting request",
                "urn:content-classes:calendarmessage"
            ])

        guard hasCalendarEvidence else { return .none }

        let hasFinancialLanguage = containsFinancialLanguage(searchableText)
        let hasCurrencyAmount = containsCurrencyAmount(searchableText)
        guard hasFinancialLanguage || hasCurrencyAmount else { return .none }

        if hasFinancialLanguage && hasCurrencyAmount {
            return CalendarInviteFraudAnalysis(
                score: combinedSignalScore,
                riskLevel: .high,
                reason: "Suspicious financial calendar invitation",
                isAutoDeleteCandidate: true,
                hasFinancialLanguage: true,
                hasCurrencyAmount: true
            )
        }

        return CalendarInviteFraudAnalysis(
            score: singleSignalScore,
            riskLevel: .high,
            reason: hasFinancialLanguage
                ? "Financial content in calendar invitation"
                : "Currency amount in calendar invitation",
            isAutoDeleteCandidate: false,
            hasFinancialLanguage: hasFinancialLanguage,
            hasCurrencyAmount: hasCurrencyAmount
        )
    }

    nonisolated static func shouldLoadBody(subject: String) -> Bool {
        let normalizedSubject = normalize(subject)
        return normalizedSubject.range(
            of: #"\binvitation\s*:"#,
            options: .regularExpression
        ) != nil
            || containsAny(normalizedSubject, phrases: [
                "calendar invitation", "event invitation", "meeting request"
            ])
    }

    nonisolated private static func containsFinancialLanguage(_ value: String) -> Bool {
        let terms = [
            "billing", "bill", "receipt", "invoice", "payment", "paid", "charge", "charged",
            "purchase", "order", "transaction", "refund", "renewal", "subscription", "account",
            "credit", "debit", "balance", "amount", "money", "paypal", "venmo", "cash app",
            "zelle", "geek squad", "norton", "mcafee", "microsoft", "amazon", "walmart", "bank"
        ]
        return terms.contains { term in
            value.range(
                of: #"(?<![a-z0-9])"# + NSRegularExpression.escapedPattern(for: term)
                    + #"(?![a-z0-9])"#,
                options: .regularExpression
            ) != nil
        }
    }

    nonisolated private static func containsCurrencyAmount(_ value: String) -> Bool {
        value.range(
            of: #"(?:\$\s*\d+(?:,\d{3})*(?:\.\d{2})?|\bUSD\s+\d+(?:,\d{3})*(?:\.\d{2})?\b|\b\d+(?:,\d{3})*(?:\.\d{2})?\s+USD\b)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    nonisolated private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    nonisolated private static func containsAny(_ value: String, phrases: [String]) -> Bool {
        phrases.contains(where: value.contains)
    }
}
