import Foundation

nonisolated struct MailMessageReference: Hashable, Sendable {
    let accountIdentifier: String
    let messageID: String
    let libraryIdentifier: String
}

nonisolated struct JunkMailMessage: Identifiable, Sendable {
    var id: MailMessageReference { reference }

    let reference: MailMessageReference
    let senderName: String
    let senderAddress: String
    let subject: String
    let dateReceived: Date
    let senderAnalysis: SenderAddressAnalysis
    let contentAnalysis: MessageContentAnalysis
    let bodyTextAnalysis: BodyTextAnalysis
    let microsoftImpersonationAnalysis: MicrosoftImpersonationAnalysis
    let brandImpersonationAnalysis: BrandImpersonationAnalysis
    let invoiceFraudAnalysis: InvoiceFraudAnalysis
    let combinedAnalysis: CombinedMessageAnalysis

    init(
        reference: MailMessageReference,
        senderName: String,
        senderAddress: String,
        senderAnalysis: SenderAddressAnalysis,
        analyzeContent: Bool,
        replyTo: String,
        subject: String,
        dateReceived: Date,
        body: String,
        authenticationResults: String
    ) {
        self.reference = reference
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.subject = subject
        self.dateReceived = dateReceived
        self.senderAnalysis = senderAnalysis
        let contentAnalysis = analyzeContent
            ? MessageContentAnalyzer.analyze(
                senderDisplayName: senderName,
                fromAddress: senderAddress,
                replyTo: replyTo,
                subject: subject,
                body: body
            )
            : .skipped
        self.contentAnalysis = contentAnalysis
        let bodyTextAnalysis = analyzeContent ? BodyTextAnalyzer.analyze(body) : .none
        self.bodyTextAnalysis = bodyTextAnalysis
        let microsoftImpersonationAnalysis = MicrosoftImpersonationAnalyzer.analyze(
            senderDisplayName: senderName,
            senderAddress: senderAddress,
            subject: subject,
            authenticationResults: authenticationResults
        )
        self.microsoftImpersonationAnalysis = microsoftImpersonationAnalysis
        let brandImpersonationAnalysis = BrandImpersonationAnalyzer.analyze(
            senderDisplayName: senderName,
            senderAddress: senderAddress
        )
        self.brandImpersonationAnalysis = brandImpersonationAnalysis
        let invoiceFraudAnalysis = InvoiceFraudAnalyzer.analyze(
            senderAddress: senderAddress,
            subject: subject,
            body: body
        )
        self.invoiceFraudAnalysis = invoiceFraudAnalysis
        combinedAnalysis = CombinedMessageAnalyzer.combine(
            senderAnalysis: senderAnalysis,
            contentAnalysis: contentAnalysis,
            bodyTextAnalysis: bodyTextAnalysis,
            microsoftImpersonationAnalysis: microsoftImpersonationAnalysis,
            brandImpersonationAnalysis: brandImpersonationAnalysis,
            invoiceFraudAnalysis: invoiceFraudAnalysis
        )
    }
}
