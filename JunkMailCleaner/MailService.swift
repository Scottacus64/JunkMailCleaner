import Foundation

struct MailMoveFailure: Sendable {
    let reference: MailMessageReference
    let message: String
}

struct MailMoveResult: Sendable {
    let movedReferences: Set<MailMessageReference>
    let failures: [MailMoveFailure]
}

nonisolated private struct ScannedMessageMetadata {
    let reference: MailMessageReference
    let senderName: String
    let senderAddress: String
    let replyTo: String
    let subject: String
    let dateReceived: Date
    let senderAnalysis: SenderAddressAnalysis
}

nonisolated private struct MessageContentFields {
    let body: String
    let authenticationResults: String
    let imageText: String
    let calendarText: String
    let hasCalendarPart: Bool
    let decodedMessageText: String
}

nonisolated private struct MailMoveRequest {
    let token: String
    let reference: MailMessageReference
}

enum MailService {
    nonisolated static func fetchJunkMessages(
        blacklistedAddresses: Set<String> = [],
        whitelistedAddresses: Set<String> = []
    ) async throws -> [JunkMailMessage] {
        try await Task.detached(priority: .userInitiated) {
            try executeScanScript(
                blacklistedAddresses: blacklistedAddresses,
                whitelistedAddresses: whitelistedAddresses
            )
        }.value
    }

    nonisolated static func moveMessagesToTrash(
        _ references: [MailMessageReference]
    ) async throws -> MailMoveResult {
        try await Task.detached(priority: .userInitiated) {
            try executeMoveScript(references)
        }.value
    }

    nonisolated private static func executeScanScript(
        blacklistedAddresses: Set<String>,
        whitelistedAddresses: Set<String>
    ) throws -> [JunkMailMessage] {
        guard let script = NSAppleScript(source: scanScript) else {
            throw MailServiceError.couldNotCreateScript
        }

        let metadataStart = Date()
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            throw MailServiceError.appleScript(
                number: errorInfo[NSAppleScript.errorNumber] as? Int,
                message: errorInfo[NSAppleScript.errorMessage] as? String
            )
        }
        print(
            "[JunkMailCleaner] Metadata scan completed in "
            + "\(String(format: "%.2f", Date().timeIntervalSince(metadataStart))) seconds."
        )

        guard result.numberOfItems > 0 else { return [] }

        var metadata: [ScannedMessageMetadata] = []
        for index in 1...result.numberOfItems {
            guard let row = result.atIndex(index), row.numberOfItems == 8 else {
                continue
            }

            let accountIdentifier = row.atIndex(1)?.stringValue ?? ""
            let libraryIdentifier = row.atIndex(2)?.stringValue ?? ""
            let messageID = row.atIndex(3)?.stringValue ?? ""
            let senderName = row.atIndex(4)?.stringValue ?? ""
            let senderAddress = row.atIndex(5)?.stringValue ?? ""
            let replyTo = row.atIndex(6)?.stringValue ?? ""
            let subject = row.atIndex(7)?.stringValue ?? ""
            guard !accountIdentifier.isEmpty,
                  !libraryIdentifier.isEmpty,
                  let dateReceived = row.atIndex(8)?.dateValue else {
                continue
            }

            metadata.append(
                ScannedMessageMetadata(
                    reference: MailMessageReference(
                        accountIdentifier: accountIdentifier,
                        messageID: messageID,
                        libraryIdentifier: libraryIdentifier
                    ),
                    senderName: senderName,
                    senderAddress: senderAddress,
                    replyTo: replyTo,
                    subject: subject,
                    dateReceived: dateReceived,
                    senderAnalysis: SenderAddressAnalyzer.analyze(senderAddress)
                )
            )
        }

        let contentMessageIDs = Set<String>(
            metadata.compactMap { message in
                guard message.senderAnalysis.riskLevel != .high,
                      !message.reference.messageID.isEmpty else {
                    return nil
                }

                let preliminaryAnalysis = MessageContentAnalyzer.analyze(
                    senderDisplayName: message.senderName,
                    fromAddress: message.senderAddress,
                    replyTo: message.replyTo,
                    subject: message.subject,
                    body: ""
                )
                let preliminaryImpersonationAnalysis = MicrosoftImpersonationAnalyzer.analyze(
                    senderDisplayName: message.senderName,
                    senderAddress: message.senderAddress,
                    subject: message.subject,
                    authenticationResults: ""
                )
                guard preliminaryAnalysis.riskLevel != .high,
                      preliminaryImpersonationAnalysis.riskLevel != .high,
                      MessageContentAnalyzer.shouldLoadBody(after: preliminaryAnalysis)
                        || BodyTextAnalyzer.shouldInspectBody(
                            senderDisplayName: message.senderName,
                            subject: message.subject
                        )
                        || CalendarInviteFraudAnalyzer.shouldLoadBody(
                            subject: message.subject
                        ) else {
                    return nil
                }
                return message.reference.messageID
            }
        ).sorted()
        let authenticationMessageIDs = Set<String>(
            metadata.compactMap { message in
                guard !message.reference.messageID.isEmpty,
                      MicrosoftImpersonationAnalyzer.claimsMicrosoftIdentity(
                        senderDisplayName: message.senderName,
                        senderAddress: message.senderAddress,
                        subject: message.subject
                      ) else {
                    return nil
                }
                return message.reference.messageID
            }
        ).sorted()
        let imageMessageIDs = Set<String>(
            metadata.compactMap { message in
                guard message.senderAnalysis.riskLevel != .high,
                      !message.reference.messageID.isEmpty else {
                    return nil
                }
                return message.reference.messageID
            }
        ).sorted()
        var contentByMessageID: [String: MessageContentFields] = [:]

        if let accountIdentifier = metadata.first?.reference.accountIdentifier,
           !contentMessageIDs.isEmpty
            || !authenticationMessageIDs.isEmpty
            || !imageMessageIDs.isEmpty {
            do {
                let contentStart = Date()
                contentByMessageID = try executeContentScript(
                    accountIdentifier: accountIdentifier,
                    bodyMessageIDs: contentMessageIDs,
                    authenticationMessageIDs: authenticationMessageIDs,
                    imageMessageIDs: imageMessageIDs
                )
                print(
                    "[JunkMailCleaner] Loaded message details in "
                    + "\(String(format: "%.2f", Date().timeIntervalSince(contentStart))) seconds."
                )
            } catch {
                print("[JunkMailCleaner] Content enrichment failed: \(error.localizedDescription)")
            }
        }

        let messages = metadata.map { metadata in
            let shouldAnalyzeContent = metadata.senderAnalysis.riskLevel != .high
            let content = contentByMessageID[metadata.reference.messageID]
            let normalizedAddress = SenderListStore.normalize(metadata.senderAddress)
            let senderListStatus: SenderListStatus
            if normalizedAddress.map(whitelistedAddresses.contains) == true {
                senderListStatus = .whitelisted
            } else if normalizedAddress.map(blacklistedAddresses.contains) == true {
                senderListStatus = .blacklisted
            } else {
                senderListStatus = .neither
            }
            let message = JunkMailMessage(
                reference: metadata.reference,
                senderName: metadata.senderName,
                senderAddress: metadata.senderAddress,
                senderAnalysis: metadata.senderAnalysis,
                analyzeContent: shouldAnalyzeContent,
                replyTo: metadata.replyTo,
                subject: metadata.subject,
                dateReceived: metadata.dateReceived,
                body: content?.body ?? "",
                authenticationResults: content?.authenticationResults ?? "",
                imageText: content?.imageText ?? "",
                calendarText: content?.calendarText ?? "",
                hasCalendarPart: content?.hasCalendarPart ?? false,
                decodedMessageText: content?.decodedMessageText ?? "",
                senderListStatus: senderListStatus
            )
            logAnalysis(for: message)
            return message
        }

        return messages.sorted { first, second in
            if first.combinedAnalysis.score != second.combinedAnalysis.score {
                return first.combinedAnalysis.score > second.combinedAnalysis.score
            }
            return first.dateReceived > second.dateReceived
        }
    }

    nonisolated private static func executeContentScript(
        accountIdentifier: String,
        bodyMessageIDs: [String],
        authenticationMessageIDs: [String],
        imageMessageIDs: [String]
    ) throws -> [String: MessageContentFields] {
        guard let script = NSAppleScript(
            source: contentScript(
                accountIdentifier: accountIdentifier,
                bodyMessageIDs: bodyMessageIDs,
                authenticationMessageIDs: authenticationMessageIDs,
                imageMessageIDs: imageMessageIDs
            )
        ) else {
            throw MailServiceError.couldNotCreateScript
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw MailServiceError.appleScript(
                number: errorInfo[NSAppleScript.errorNumber] as? Int,
                message: errorInfo[NSAppleScript.errorMessage] as? String
            )
        }

        var fieldsByMessageID: [String: MessageContentFields] = [:]
        guard result.numberOfItems > 0 else { return fieldsByMessageID }

        for index in 1...result.numberOfItems {
            guard let row = result.atIndex(index),
                  row.numberOfItems == 6,
                  let messageID = row.atIndex(1)?.stringValue else {
                continue
            }

            if row.atIndex(2)?.booleanValue == true {
                let rawSource = row.atIndex(5)?.stringValue ?? ""
                let ocrResult = EmbeddedImageOCRAnalyzer.recognizeText(in: rawSource)
                let calendarExtraction = CalendarAttachmentExtractor.extract(from: rawSource)
                let decodedMessageText = DecodedMessageTextExtractor.extract(from: rawSource)
                fieldsByMessageID[messageID] = MessageContentFields(
                    body: row.atIndex(3)?.stringValue ?? "",
                    authenticationResults: row.atIndex(4)?.stringValue ?? "",
                    imageText: ocrResult.recognizedText,
                    calendarText: calendarExtraction.text,
                    hasCalendarPart: calendarExtraction.hasCalendarPart,
                    decodedMessageText: decodedMessageText.combinedText
                )
            } else {
                fieldsByMessageID.removeValue(forKey: messageID)
                let message = row.atIndex(6)?.stringValue ?? "Unknown Apple Mail error"
                print("[JunkMailCleaner] Content unavailable for Message-ID \(messageID): \(message)")
            }
        }

        return fieldsByMessageID
    }

    nonisolated private static func executeMoveScript(
        _ references: [MailMessageReference]
    ) throws -> MailMoveResult {
        guard let firstReference = references.first else {
            return MailMoveResult(movedReferences: [], failures: [])
        }

        guard references.allSatisfy({ $0.accountIdentifier == firstReference.accountIdentifier }) else {
            throw MailServiceError.invalidSelection
        }

        var failures = references
            .filter { $0.messageID.isEmpty && $0.libraryIdentifier.isEmpty }
            .map {
                MailMoveFailure(
                    reference: $0,
                    message: "This message has no usable Mail identifier."
                )
            }
        let requests = references
            .filter { !$0.messageID.isEmpty || !$0.libraryIdentifier.isEmpty }
            .enumerated()
            .map { index, reference in
                MailMoveRequest(token: String(index), reference: reference)
            }
        let requestsByToken = Dictionary(uniqueKeysWithValues: requests.map { ($0.token, $0) })

        guard !requests.isEmpty else {
            return MailMoveResult(movedReferences: [], failures: failures)
        }

        let scriptSource = moveScript(
            accountIdentifier: firstReference.accountIdentifier,
            requests: requests
        )

        guard let script = NSAppleScript(source: scriptSource) else {
            throw MailServiceError.couldNotCreateScript
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            throw MailServiceError.appleScript(
                number: errorInfo[NSAppleScript.errorNumber] as? Int,
                message: errorInfo[NSAppleScript.errorMessage] as? String
            )
        }

        var movedReferences: Set<MailMessageReference> = []
        if result.numberOfItems > 0 {
            for index in 1...result.numberOfItems {
                guard let row = result.atIndex(index),
                      row.numberOfItems == 3,
                      let token = row.atIndex(1)?.stringValue,
                      let request = requestsByToken[token] else {
                    continue
                }

                if row.atIndex(2)?.booleanValue == true {
                    movedReferences.insert(request.reference)
                } else {
                    failures.append(
                        MailMoveFailure(
                            reference: request.reference,
                            message: row.atIndex(3)?.stringValue ?? "Unknown Apple Mail error"
                        )
                    )
                }
            }
        }

        let reportedReferences = movedReferences.union(failures.map(\.reference))
        for request in requests where !reportedReferences.contains(request.reference) {
            failures.append(
                MailMoveFailure(
                    reference: request.reference,
                    message: "Apple Mail did not return a result for this message."
                )
            )
        }

        return MailMoveResult(movedReferences: movedReferences, failures: failures)
    }

    nonisolated private static let scanScript = #"""
    using terms from application "Mail"
        tell application id "com.apple.mail"
            set hotmailAccount to missing value

            repeat with mailAccount in accounts
                set accountAddresses to email addresses of mailAccount
                repeat with accountAddress in accountAddresses
                    ignoring case
                        if accountAddress ends with "@hotmail.com" or accountAddress ends with "@outlook.com" or accountAddress ends with "@live.com" or accountAddress ends with "@msn.com" then
                            set hotmailAccount to mailAccount
                            exit repeat
                        end if
                    end ignoring
                end repeat

                if hotmailAccount is not missing value then exit repeat
            end repeat

            if hotmailAccount is missing value then
                error "No Hotmail, Outlook.com, Live.com, or MSN account was found in Apple Mail." number 1001
            end if

            set junkMailboxName to missing value
            repeat with candidateMailbox in mailboxes of hotmailAccount
                set mailboxName to name of candidateMailbox
                ignoring case
                    if mailboxName is "Junk" or mailboxName is "Junk E-mail" or mailboxName is "Junk Email" or mailboxName is "Spam" then
                        set junkMailboxName to mailboxName
                        exit repeat
                    end if
                end ignoring
            end repeat

            if junkMailboxName is missing value then
                error "The Junk mailbox for the Hotmail account could not be found in Apple Mail." number 1002
            end if

            set hotmailJunkMailbox to mailbox junkMailboxName of hotmailAccount
            set messageRows to {}
            set accountIdentifier to id of hotmailAccount
            repeat with mailMessage in messages of hotmailJunkMailbox
                set senderText to sender of mailMessage
                set senderName to extract name from senderText
                set senderAddress to extract address from senderText
                set libraryIdentifier to (id of mailMessage) as text
                set stableMessageID to ""
                try
                    set stableMessageID to message id of mailMessage
                    if stableMessageID is missing value then set stableMessageID to ""
                end try
                set replyToAddress to ""
                try
                    set replyToAddress to reply to of mailMessage
                    if replyToAddress is missing value then set replyToAddress to ""
                end try
                set end of messageRows to {accountIdentifier, libraryIdentifier, stableMessageID, senderName, senderAddress, replyToAddress, subject of mailMessage, date received of mailMessage}
            end repeat

            return messageRows
        end tell
    end using terms from
    """#

    nonisolated private static func contentScript(
        accountIdentifier: String,
        bodyMessageIDs: [String],
        authenticationMessageIDs: [String],
        imageMessageIDs: [String]
    ) -> String {
        let bodyIdentifierList = bodyMessageIDs.map(appleScriptString).joined(separator: ", ")
        let authenticationIdentifierList = authenticationMessageIDs
            .map(appleScriptString)
            .joined(separator: ", ")
        let imageIdentifierList = imageMessageIDs.map(appleScriptString).joined(separator: ", ")
        let requestedIdentifierList = Set(
            bodyMessageIDs + authenticationMessageIDs + imageMessageIDs
        )
            .sorted()
            .map(appleScriptString)
            .joined(separator: ", ")

        return #"""
        using terms from application "Mail"
            tell application id "com.apple.mail"
                set scannedAccountID to \#(appleScriptString(accountIdentifier))
                set requestedMessageIDs to {\#(requestedIdentifierList)}
                set requestedBodyMessageIDs to {\#(bodyIdentifierList)}
                set requestedAuthenticationMessageIDs to {\#(authenticationIdentifierList)}
                set requestedImageMessageIDs to {\#(imageIdentifierList)}
                set hotmailAccount to missing value

                repeat with candidateAccount in accounts
                    if ((id of candidateAccount) as text) is scannedAccountID then
                        set hotmailAccount to candidateAccount
                        exit repeat
                    end if
                end repeat

                if hotmailAccount is missing value then
                    error "The scanned Mail account could not be found." number 1003
                end if

                set junkMailboxName to missing value
                repeat with candidateMailbox in mailboxes of hotmailAccount
                    set mailboxName to name of candidateMailbox
                    ignoring case
                        if mailboxName is "Junk" or mailboxName is "Junk E-mail" or mailboxName is "Junk Email" or mailboxName is "Spam" then
                            set junkMailboxName to mailboxName
                            exit repeat
                        end if
                    end ignoring
                end repeat

                if junkMailboxName is missing value then
                    error "The Junk mailbox for the scanned account could not be found." number 1002
                end if

                set hotmailJunkMailbox to mailbox junkMailboxName of hotmailAccount
                set resultRows to {}
                set foundMessageIDs to {}
                repeat with candidateMessage in messages of hotmailJunkMailbox
                    try
                        set candidateMessageID to message id of candidateMessage
                        if candidateMessageID is not missing value and requestedMessageIDs contains candidateMessageID then
                            if foundMessageIDs contains candidateMessageID then
                                set end of resultRows to {candidateMessageID, false, "", "", "", "Message-ID is not unique in the Junk mailbox. (1006)"}
                            else
                                set end of foundMessageIDs to candidateMessageID
                                set messageBody to ""
                                if requestedBodyMessageIDs contains candidateMessageID then
                                    try
                                        set messageBody to content of candidateMessage as text
                                        if messageBody is missing value then set messageBody to ""
                                    end try
                                end if

                                set authenticationText to ""
                                if requestedAuthenticationMessageIDs contains candidateMessageID then
                                    try
                                        repeat with messageHeader in headers of candidateMessage
                                            ignoring case
                                                if ((name of messageHeader) as text) is "Authentication-Results" then
                                                    set authenticationText to authenticationText & " " & ((content of messageHeader) as text)
                                                end if
                                            end ignoring
                                        end repeat
                                    end try
                                end if

                                set messageSource to ""
                                if requestedImageMessageIDs contains candidateMessageID then
                                    try
                                        set messageSource to source of candidateMessage as text
                                        if messageSource is missing value then set messageSource to ""
                                    end try
                                end if
                                set end of resultRows to {candidateMessageID, true, messageBody, authenticationText, messageSource, ""}
                            end if
                        end if
                    on error errorMessage number errorNumber
                        set failedMessageID to "unknown"
                        try
                            set failedMessageID to message id of candidateMessage
                        end try
                        set end of resultRows to {failedMessageID, false, "", "", "", errorMessage & " (" & errorNumber & ")"}
                    end try
                end repeat

                repeat with requestedMessageID in requestedMessageIDs
                    set requestedIDText to requestedMessageID as text
                    if foundMessageIDs does not contain requestedIDText then
                        set end of resultRows to {requestedIDText, false, "", "", "", "Message is no longer in the Junk mailbox. (1005)"}
                    end if
                end repeat

                return resultRows
            end tell
        end using terms from
        """#
    }

    nonisolated private static func moveScript(
        accountIdentifier: String,
        requests: [MailMoveRequest]
    ) -> String {
        let requestList = requests.map { request in
            "{\(appleScriptString(request.token)), "
                + "\(appleScriptString(request.reference.messageID)), "
                + "\(appleScriptString(request.reference.libraryIdentifier))}"
        }.joined(separator: ", ")

        return #"""
        using terms from application "Mail"
            tell application id "com.apple.mail"
                set scannedAccountID to \#(appleScriptString(accountIdentifier))
                set moveRequests to {\#(requestList)}
                set hotmailAccount to missing value

                repeat with candidateAccount in accounts
                    if ((id of candidateAccount) as text) is scannedAccountID then
                        set hotmailAccount to candidateAccount
                        exit repeat
                    end if
                end repeat

                if hotmailAccount is missing value then
                    error "The scanned Mail account could not be found." number 1003
                end if

                set junkMailboxName to missing value
                set trashMailboxName to missing value

                repeat with candidateMailbox in mailboxes of hotmailAccount
                    set mailboxName to name of candidateMailbox
                    ignoring case
                        if mailboxName is "Junk" or mailboxName is "Junk E-mail" or mailboxName is "Junk Email" or mailboxName is "Spam" then
                            set junkMailboxName to mailboxName
                        else if mailboxName is "Deleted Items" or mailboxName is "Trash" or mailboxName is "Deleted Messages" or mailboxName is "Bin" then
                            set trashMailboxName to mailboxName
                        end if
                    end ignoring
                end repeat

                if junkMailboxName is missing value then
                    error "The Junk mailbox for the scanned account could not be found." number 1002
                end if

                if trashMailboxName is missing value then
                    error "The Trash or Deleted Items mailbox for the scanned account could not be found." number 1004
                end if

                set hotmailJunkMailbox to mailbox junkMailboxName of hotmailAccount
                set accountTrashMailbox to mailbox trashMailboxName of hotmailAccount
                set resultRows to {}
                repeat with moveRequest in moveRequests
                    set requestToken to (item 1 of moveRequest) as text
                    set requestedMessageID to (item 2 of moveRequest) as text
                    set requestedLibraryID to (item 3 of moveRequest) as text
                    try
                        set matchingMessages to {}
                        if requestedMessageID is not "" then
                            try
                                set matchingMessages to every message of hotmailJunkMailbox whose message id is requestedMessageID
                            end try
                        end if
                        set matchingCount to count of matchingMessages

                        -- Malformed junk often omits or duplicates the internet Message-ID.
                        -- Fall back to Apple Mail's mailbox-local identifier captured during scanning.
                        if matchingCount is not 1 and requestedLibraryID is not "" then
                            set matchingMessages to {}
                            try
                                set requestedLibraryIDNumber to requestedLibraryID as integer
                                set matchingMessages to every message of hotmailJunkMailbox whose id is requestedLibraryIDNumber
                            end try
                            set matchingCount to count of matchingMessages
                        end if

                        if matchingCount is 0 then
                            error "Message is no longer in the Junk mailbox." number 1005
                        end if

                        if matchingCount is greater than 1 then
                            error "Message-ID is not unique in the Junk mailbox." number 1006
                        end if

                        set matchedMessage to item 1 of matchingMessages
                        move matchedMessage to accountTrashMailbox
                        set end of resultRows to {requestToken, true, ""}
                    on error errorMessage number errorNumber
                        set end of resultRows to {requestToken, false, errorMessage & " (" & errorNumber & ")"}
                    end try
                end repeat

                return resultRows
            end tell
        end using terms from
        """#
    }

    nonisolated private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    nonisolated private static func logAnalysis(for message: JunkMailMessage) {
        let categories = message.contentAnalysis.categories
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")

        print(
            "[JunkMailCleaner] Sender=\(message.senderAddress); "
            + "ReplyTo=\(message.contentAnalysis.replyToAddress ?? "none"); "
            + "SenderScore=\(message.senderAnalysis.score); "
            + "ContentSkipped=\(message.senderAnalysis.riskLevel == .high); "
            + "ContentScore=\(message.contentAnalysis.score); "
            + "BodyTextScore=\(message.bodyTextAnalysis.score); "
            + "ObfuscatedTokens=\(message.bodyTextAnalysis.suspiciousTokens.count); "
            + "Categories=\(categories.isEmpty ? "none" : categories); "
            + "MicrosoftClaim=\(message.microsoftImpersonationAnalysis.claimsMicrosoftIdentity); "
            + "MicrosoftDomain=\(message.microsoftImpersonationAnalysis.senderDomain ?? "none"); "
            + "SPF=\(message.microsoftImpersonationAnalysis.spfResult ?? "unknown"); "
            + "DKIM=\(message.microsoftImpersonationAnalysis.dkimResult ?? "unknown"); "
            + "DMARC=\(message.microsoftImpersonationAnalysis.dmarcResult ?? "unknown"); "
            + "ImpersonationScore=\(message.microsoftImpersonationAnalysis.score); "
            + "CalendarFraudScore=\(message.calendarInviteFraudAnalysis.score); "
            + "CommercialMessageScore=\(message.commercialMessageAnalysis.score); "
            + "SenderListStatus=\(message.senderListStatus.rawValue); "
            + "FinalRisk=\(message.combinedAnalysis.riskLevel.rawValue) "
            + "(\(message.combinedAnalysis.score)); "
            + "AutoDeleteCandidate=\(message.combinedAnalysis.isAutoDeleteCandidate)"
        )
        if let brand = message.brandImpersonationAnalysis.claimedBrand {
            print(
                "[JunkMailCleaner] Brand=\(brand); "
                    + "FromDomain=\(message.brandImpersonationAnalysis.senderDomain ?? "none"); "
                    + "TrustedBrandDomain="
                    + "\(message.brandImpersonationAnalysis.isTrustedBrandDomain == true); "
                    + "BrandImpersonationScore=\(message.brandImpersonationAnalysis.score)"
            )
        }
        for indicator in message.commercialMessageAnalysis.indicators {
            print(
                "[JunkMailCleaner] CommercialIndicator=\(indicator.reason); "
                    + "IndicatorScore=\(indicator.score); "
                    + "Matches=\(indicator.matches.joined(separator: ", "))"
            )
        }
    }

}

private enum MailServiceError: LocalizedError {
    case couldNotCreateScript
    case invalidSelection
    case appleScript(number: Int?, message: String?)

    var errorDescription: String? {
        switch self {
        case .couldNotCreateScript:
            return "The Apple Mail scan could not be prepared."
        case .invalidSelection:
            return "The selected messages do not belong to the same Mail account."
        case .appleScript(let number, let message):
            if number == -1743 {
                return "Junk Mail Cleaner does not have permission to access Apple Mail. Open System Settings > Privacy & Security > Automation, then allow Junk Mail Cleaner to control Mail."
            }

            if number == -600 {
                return "Junk Mail Cleaner could not connect to Apple Mail. Make sure Mail is open, then quit and reopen Junk Mail Cleaner before trying again."
            }

            if let message, !message.isEmpty {
                return message
            }

            return "Apple Mail could not be scanned. Make sure Mail is configured and try again."
        }
    }
}
