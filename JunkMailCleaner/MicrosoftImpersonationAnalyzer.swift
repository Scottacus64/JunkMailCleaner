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
    // Authentication remains Microsoft-specific, while brand claim and trusted-domain
    // evaluation are delegated to the shared brand impersonation framework.
    nonisolated static func claimsMicrosoftIdentity(
        senderDisplayName: String,
        senderAddress: String,
        subject: String
    ) -> Bool {
        BrandImpersonationAnalyzer.analyze(
            senderDisplayName: senderDisplayName,
            senderAddress: senderAddress,
            subject: subject
        ).claimedBrand == "Microsoft"
    }

    nonisolated static func analyze(
        senderDisplayName: String,
        senderAddress: String,
        subject: String,
        authenticationResults: String,
        decodedMessageText: String = "",
        imageText: String = ""
    ) -> MicrosoftImpersonationAnalysis {
        let brandAnalysis = BrandImpersonationAnalyzer.analyze(
            senderDisplayName: senderDisplayName,
            senderAddress: senderAddress,
            subject: subject,
            decodedMessageText: decodedMessageText,
            imageText: imageText
        )
        let claimsIdentity = brandAnalysis.claimedBrand == "Microsoft"
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

        let failedMechanisms = ["spf", "dkim", "dmarc"].filter {
            authentication[$0] == "fail"
        }
        let hasStrongAuthenticationFailure = authentication["dmarc"] == "fail"
            && (authentication["spf"] == "fail" || authentication["dkim"] == "fail")

        var score = brandAnalysis.score
        var reasons = brandAnalysis.reason.map { [$0] } ?? []
        if brandAnalysis.isTrustedBrandDomain == false, !failedMechanisms.isEmpty {
            score = 100
            reasons.append("Authentication failed")
        } else if brandAnalysis.isTrustedBrandDomain == true && hasStrongAuthenticationFailure {
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

    nonisolated private static func domain(from address: String) -> String? {
        guard let domain = address.split(separator: "@", maxSplits: 1).last,
              address.contains("@") else {
            return nil
        }
        return domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
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
