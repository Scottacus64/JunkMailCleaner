import Foundation

nonisolated struct MicrosoftImpersonationAnalysis: Sendable {
    let score: Int
    let riskLevel: SenderRiskLevel
    let reason: String?
    let claimsMicrosoftIdentity: Bool
    let senderDomain: String?
    let spfResult: String?
    let dkimResult: String?
    let dmarcResult: String?
}

nonisolated enum MicrosoftImpersonationAnalyzer {
    nonisolated private static let approvedDomains = [
        "microsoft.com",
        "microsoftonline.com",
        "microsoft365.com",
        "microsoftstore.com",
        "office.com",
        "office365.com",
        "onedrive.com",
        "windows.com",
        "azure.com"
    ]

    nonisolated static func claimsMicrosoftIdentity(
        senderDisplayName: String,
        senderAddress: String,
        subject: String
    ) -> Bool {
        let displayName = normalize(senderDisplayName)
        let localPart = senderAddress
            .split(separator: "@", maxSplits: 1)
            .first?
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
            ?? ""
        let normalizedSubject = normalize(subject)

        let explicitDisplayClaims = [
            "microsoft", "microsoft account", "microsoft account team",
            "microsoft security", "microsoft security team", "microsoft support",
            "outlook", "outlook team", "office 365", "office 365 team",
            "microsoft 365", "microsoft 365 team", "onedrive", "onedrive team"
        ]
        let localPartClaims = [
            "microsoft", "microsoftaccount", "microsoftaccountteam",
            "microsoftsecurity", "microsoftsupport", "outlookteam",
            "office365", "office365team", "microsoft365", "microsoft365team",
            "onedrive", "onedriveteam"
        ]
        let genericTeamNames = ["account team", "security team", "support team"]
        let subjectClaims = [
            "microsoft account", "microsoft security", "microsoft 365",
            "office 365", "outlook security", "onedrive"
        ]

        let hasExplicitDisplayClaim = explicitDisplayClaims.contains(displayName)
            || displayName.hasPrefix("microsoft ")
        let hasAddressClaim = localPartClaims.contains(localPart)
            || localPart.hasPrefix("microsoft")
        let hasSupportedGenericClaim = genericTeamNames.contains(displayName)
            && subjectClaims.contains(where: normalizedSubject.contains)
        return hasExplicitDisplayClaim || hasAddressClaim || hasSupportedGenericClaim
    }

    nonisolated static func analyze(
        senderDisplayName: String,
        senderAddress: String,
        subject: String,
        authenticationResults: String
    ) -> MicrosoftImpersonationAnalysis {
        let claimsIdentity = claimsMicrosoftIdentity(
            senderDisplayName: senderDisplayName,
            senderAddress: senderAddress,
            subject: subject
        )
        let senderDomain = domain(from: senderAddress)
        let authentication = parseAuthenticationResults(authenticationResults)

        guard claimsIdentity else {
            return MicrosoftImpersonationAnalysis(
                score: 0,
                riskLevel: .low,
                reason: nil,
                claimsMicrosoftIdentity: false,
                senderDomain: senderDomain,
                spfResult: authentication["spf"],
                dkimResult: authentication["dkim"],
                dmarcResult: authentication["dmarc"]
            )
        }

        let isApprovedDomain = senderDomain.map(isApprovedMicrosoftDomain) ?? false
        let failedMechanisms = ["spf", "dkim", "dmarc"].filter {
            authentication[$0] == "fail"
        }
        let hasStrongAuthenticationFailure = authentication["dmarc"] == "fail"
            && (authentication["spf"] == "fail" || authentication["dkim"] == "fail")

        var score = 0
        var reasons: [String] = []
        if !isApprovedDomain {
            score = 95
            reasons.append("Microsoft impersonation: sender domain is not an approved Microsoft domain")
            if !failedMechanisms.isEmpty {
                score = 100
                reasons.append("Authentication failed")
            }
        } else if hasStrongAuthenticationFailure {
            score = 90
            reasons.append("Microsoft impersonation: approved domain failed authentication")
        }

        return MicrosoftImpersonationAnalysis(
            score: score,
            riskLevel: score >= 70 ? .high : .low,
            reason: reasons.isEmpty ? nil : reasons.joined(separator: "; "),
            claimsMicrosoftIdentity: true,
            senderDomain: senderDomain,
            spfResult: authentication["spf"],
            dkimResult: authentication["dkim"],
            dmarcResult: authentication["dmarc"]
        )
    }

    nonisolated private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func domain(from address: String) -> String? {
        guard let domain = address.split(separator: "@", maxSplits: 1).last,
              address.contains("@") else {
            return nil
        }
        return domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    nonisolated private static func isApprovedMicrosoftDomain(_ domain: String) -> Bool {
        approvedDomains.contains { approvedDomain in
            domain == approvedDomain || domain.hasSuffix("." + approvedDomain)
        }
    }

    nonisolated private static func parseAuthenticationResults(_ value: String) -> [String: String] {
        let pattern = #"\b(spf|dkim|dmarc)\s*=\s*([a-z0-9_-]+)"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: .caseInsensitive
        ) else {
            return [:]
        }

        var results: [String: String] = [:]
        let range = NSRange(value.startIndex..., in: value)
        for match in expression.matches(in: value, range: range) {
            guard let mechanismRange = Range(match.range(at: 1), in: value),
                  let resultRange = Range(match.range(at: 2), in: value) else {
                continue
            }
            let mechanism = value[mechanismRange].lowercased()
            if results[mechanism] == nil {
                results[mechanism] = value[resultRange].lowercased()
            }
        }
        return results
    }
}
