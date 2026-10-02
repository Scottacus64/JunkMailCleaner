import AppKit
import SwiftUI

struct MessageInspectorView: View {
    @State private var message: JunkMailMessage
    @ObservedObject var senderLists: SenderListStore
    let senderStatusChanged: (String) -> Void
    let messageDeleted: (JunkMailMessage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var inspectionData: MessageInspectionData?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var allowsRemoteImages = false
    @State private var pendingLink: EmailLink?
    @State private var isDeleting = false
    @State private var deleteError: String?

    init(
        message: JunkMailMessage,
        senderLists: SenderListStore,
        senderStatusChanged: @escaping (String) -> Void,
        messageDeleted: @escaping (JunkMailMessage) -> Void
    ) {
        _message = State(initialValue: message)
        self.senderLists = senderLists
        self.senderStatusChanged = senderStatusChanged
        self.messageDeleted = messageDeleted
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView {
                messageTab
                    .tabItem { Label("Message", systemImage: "envelope.open") }
                analysisTab
                    .tabItem { Label("Analysis", systemImage: "waveform.path.ecg") }
                headersTab
                    .tabItem { Label("Headers", systemImage: "list.bullet.rectangle") }
                rawSourceTab
                    .tabItem { Label("Raw Source", systemImage: "chevron.left.forwardslash.chevron.right") }
            }
            .padding([.horizontal, .bottom])
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Keep the inspector bounded independently of the email document's
        // intrinsic size. Long messages scroll inside the content region.
        .frame(
            minWidth: 920,
            idealWidth: 1000,
            maxWidth: 1400,
            minHeight: 700,
            idealHeight: 750,
            maxHeight: 850
        )
        .task(id: message.reference) {
            await loadInspectionData()
        }
        .alert("Open link externally?", item: $pendingLink) { link in
            Button("Cancel", role: .cancel) {}
            Button("Open Link") {
                let destination = link.actualDestination ?? link.destination
                if let url = URL(string: destination) {
                    NSWorkspace.shared.open(url)
                }
            }
        } message: { link in
            if let actualDestination = link.actualDestination {
                Text("Protected URL:\n\(link.destination)\n\nActual destination:\n\(actualDestination)")
            } else {
                Text("Destination:\n\(link.destination)")
            }
        }
        .alert(
            "Unable to Delete Message",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "The message could not be moved to Trash.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    metadataRow("From:", fromValue)
                    metadataRow("Reply-To:", headerValue("Reply-To") ?? optional(message.replyToAddress))
                    metadataRow("To:", headerValue("To"))
                    metadataRow("Subject:", headerValue("Subject") ?? optional(message.subject))
                    metadataRow(
                        "Date:",
                        headerValue("Date")
                            ?? message.dateReceived.formatted(date: .abbreviated, time: .standard)
                    )
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 12) {
                        senderStatusLabel
                        Button(role: .destructive, action: deleteMessage) {
                            if isDeleting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Delete Message", systemImage: "trash")
                            }
                        }
                        .disabled(isDeleting)
                        Button("Close") {
                            dismiss()
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                    HStack {
                        Button("Blacklist Sender") {
                            senderLists.addToBlacklist(message.senderAddress)
                            updateSenderStatus()
                        }
                        .disabled(message.senderListStatus == .blacklisted)

                        Button("Whitelist Sender") {
                            senderLists.addToWhitelist(message.senderAddress)
                            updateSenderStatus()
                        }
                        .disabled(message.senderListStatus == .whitelisted)

                        if message.senderListStatus != .neither {
                            Button("Clear Status") {
                                senderLists.removeFromBlacklist(message.senderAddress)
                                senderLists.removeFromWhitelist(message.senderAddress)
                                updateSenderStatus()
                            }
                        }
                    }
                }
            }
        }
        .padding()
    }

    private var messageTab: some View {
        Group {
            if isLoading {
                ProgressView("Loading selected message from Apple Mail…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView(
                    "Message Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else if let inspectionData {
                VStack(alignment: .leading, spacing: 10) {
                    if inspectionData.originalHTML != nil {
                        HStack {
                            Label(
                                allowsRemoteImages
                                    ? "Remote images enabled for this message"
                                    : "Remote content is blocked",
                                systemImage: allowsRemoteImages
                                    ? "photo.badge.checkmark"
                                    : "shield.fill"
                            )
                            .foregroundStyle(allowsRemoteImages ? .orange : .secondary)
                            Spacer()
                            Button("Load Remote Images") {
                                allowsRemoteImages = true
                            }
                            .disabled(allowsRemoteImages)
                        }
                    }

                    if let renderedHTML = inspectionData.renderedHTML(
                        allowsRemoteImages: allowsRemoteImages
                    ), !renderedHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        SafeEmailWebView(
                            html: renderedHTML,
                            allowsRemoteImages: allowsRemoteImages,
                            linkActivated: showLink
                        )
                        .id(allowsRemoteImages)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minHeight: 320)
                        .layoutPriority(1)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.quaternary)
                        }
                    } else {
                        bodyFallback(inspectionData)
                        .frame(maxHeight: .infinity)
                    }

                    if !inspectionData.attachments.isEmpty || !inspectionData.links.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                        attachmentsSection(inspectionData.attachments)
                        linksSection(inspectionData.links)
                            }
                        }
                        .frame(maxHeight: 220)
                    }
                }
                .padding(.vertical)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func bodyFallback(_ data: MessageInspectionData) -> some View {
        let body = !data.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? data.plainText
            : data.mailBody
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "Message body could not be extracted.",
                systemImage: "doc.questionmark"
            )
        } else {
            ScrollView {
                Text(body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.quaternary.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var analysisTab: some View {
        let analysis = MessageInspectorAnalysisSnapshot(message: message)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Scores and status") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                        analysisRow("Final Risk", "\(analysis.finalRisk.rawValue) (\(analysis.finalScore))")
                        analysisRow("Auto Delete Candidate", yesNo(analysis.isAutoDeleteCandidate))
                        analysisRow("Nuke Candidate", yesNo(message.combinedAnalysis.isNukeCandidate))
                        analysisRow("Sender Score", String(analysis.senderScore))
                        analysisRow("Content Score", String(analysis.contentScore))
                        analysisRow("Body Text Score", String(analysis.bodyTextScore))
                        analysisRow("Microsoft Impersonation Score", String(analysis.microsoftImpersonationScore))
                        analysisRow("Brand Impersonation Score", String(analysis.brandImpersonationScore))
                        analysisRow("Invoice Fraud Score", String(analysis.invoiceFraudScore))
                        analysisRow("Calendar Fraud Score", String(analysis.calendarFraudScore))
                        analysisRow("Commercial Message Score", String(analysis.commercialMessageScore))
                        analysisRow("Whitelist/Blacklist", statusTitle(analysis.senderListStatus))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("Authentication") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                        analysisRow("SPF", analysis.spf ?? "unknown / not analyzed")
                        analysisRow("DKIM", analysis.dkim ?? "unknown / not analyzed")
                        analysisRow("DMARC", analysis.dmarc ?? "unknown / not analyzed")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("Analyzer details") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                        analysisRow("Sender/domain analysis", message.senderAnalysis.reason)
                        analysisRow(
                            "Brand impersonation",
                            brandResult(analysis)
                        )
                        analysisRow(
                            "Microsoft account/security impersonation",
                            message.microsoftImpersonationAnalysis.reason ?? "Not detected"
                        )
                        analysisRow(
                            "Email-administrator impersonation",
                            "No dedicated analyzer result"
                        )
                        analysisRow(
                            "Reply-To mismatch",
                            yesNo(message.contentAnalysis.categories.contains(.replyToMismatch))
                        )
                        analysisRow("Reply-To", analysis.replyToAddress ?? "none")
                        analysisRow(
                            "Recipient mismatch",
                            "Not analyzed by the current analyzer set"
                        )
                        analysisRow(
                            "Suspicious subject indicators",
                            subjectIndicators(analysis)
                        )
                        analysisRow(
                            "Detected categories",
                            analysis.categories.isEmpty
                                ? "none"
                                : analysis.categories.joined(separator: ", ")
                        )
                        analysisRow(
                            "Obfuscated-word indicators",
                            analysis.suspiciousTokens.isEmpty
                                ? "none"
                                : analysis.suspiciousTokens.joined(separator: ", ")
                        )
                        analysisRow(
                            "Protected obfuscated terms",
                            analysis.protectedTokens.isEmpty
                                ? "none"
                                : analysis.protectedTokens.joined(separator: ", ")
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("All scoring reasons") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(analysis.reasons.enumerated()), id: \.offset) { _, reason in
                            Text("• \(reason)")
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding(.vertical)
        }
    }

    private var headersTab: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let inspectionData {
                ReadOnlyTextView(text: formattedHeaders(inspectionData.headers), monospaced: true)
                    .overlay(alignment: .topTrailing) {
                        Text("Selectable • Copyable • Command-F to search")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
            } else {
                Text(loadError ?? "No headers available.")
                    .textSelection(.enabled)
            }
        }
    }

    private var rawSourceTab: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let inspectionData {
                ReadOnlyTextView(text: inspectionData.rawSource, monospaced: true)
                    .overlay(alignment: .topTrailing) {
                        Text("Plain text only • Command-F to search")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
            } else {
                Text(loadError ?? "No raw source available.")
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func attachmentsSection(_ attachments: [EmailAttachmentMetadata]) -> some View {
        if !attachments.isEmpty {
            GroupBox("Attachments (not opened)") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                        HStack {
                            Image(systemName: attachment.isInline ? "photo" : "paperclip")
                            Text(attachment.filename)
                                .textSelection(.enabled)
                            Spacer()
                            Text(attachment.mimeType)
                                .foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func linksSection(_ links: [EmailLink]) -> some View {
        GroupBox("Links (not opened)") {
            if links.isEmpty {
                Text("No HTTP or HTTPS links found.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(links) { link in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(link.visibleText)
                                    .fontWeight(.medium)
                                    .textSelection(.enabled)
                                if link.hasDisplayDestinationMismatch {
                                    Label("Display/destination mismatch", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                            if let actualDestination = link.actualDestination {
                                Text("Protected URL: \(link.destination)")
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Text("Actual destination: \(actualDestination)")
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            } else {
                                Text("Destination: \(link.destination)")
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            Text("Domain: \(link.destinationDomain ?? "unknown")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func loadInspectionData() async {
        isLoading = true
        loadError = nil
        allowsRemoteImages = false
        do {
            let source: MessageInspectionSource
            if let cachedInspectionSource = message.cachedInspectionSource {
                source = cachedInspectionSource
                #if DEBUG
                print(
                    "[JunkMailCleaner][Inspector][View] using cached source; "
                        + "chars=\(source.rawSource.count) bytes=\(source.rawSource.utf8.count)"
                )
                #endif
            } else {
                source = try await MailService.fetchMessageInspectionSource(
                    for: message.reference
                )
                #if DEBUG
                print("[JunkMailCleaner][Inspector][View] using on-demand Mail source")
                #endif
            }
            inspectionData = await Task.detached(priority: .userInitiated) {
                MessageInspectorParser.parse(source)
            }.value
            #if DEBUG
            if let inspectionData {
                print(
                    "[JunkMailCleaner][Inspector][View] model htmlChars="
                        + "\(inspectionData.originalHTML?.count ?? 0) "
                        + "plainChars=\(inspectionData.plainText.count)"
                )
            }
            #endif
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func showLink(_ destination: String) {
        pendingLink = EmailLinkExtractor.describe(destination: destination)
            ?? EmailLink(
                visibleText: "Clicked link",
                destination: destination,
                actualDestination: nil,
                destinationDomain: URL(string: destination)?.host,
                hasDisplayDestinationMismatch: false
            )
    }

    private func updateSenderStatus() {
        message.updateSenderListStatus(senderLists.status(for: message.senderAddress))
        senderStatusChanged(message.senderAddress)
    }

    private func deleteMessage() {
        guard !isDeleting else { return }
        isDeleting = true
        deleteError = nil

        Task {
            do {
                let result = try await MailService.moveMessagesToTrash([message.reference])
                if result.movedReferences.contains(message.reference) {
                    messageDeleted(message)
                    dismiss()
                } else {
                    deleteError = result.failures.first?.message
                        ?? "Apple Mail did not confirm that the message was moved to Trash."
                }
            } catch {
                deleteError = error.localizedDescription
            }
            isDeleting = false
        }
    }

    private var fromValue: String {
        if let headerFrom = headerValue("From") { return headerFrom }
        if message.senderName.isEmpty { return message.senderAddress }
        return "\(message.senderName) <\(message.senderAddress)>"
    }

    private func headerValue(_ name: String) -> String? {
        inspectionData?.firstHeader(named: name)
    }

    private func optional(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private func metadataRow(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label).fontWeight(.semibold)
            Text(value ?? "—")
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }

    private func analysisRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).fontWeight(.semibold)
            Text(value).textSelection(.enabled)
        }
    }

    private var senderStatusLabel: some View {
        Label(
            statusTitle(message.senderListStatus),
            systemImage: statusIcon(message.senderListStatus)
        )
        .foregroundStyle(statusColor(message.senderListStatus))
    }

    private func statusTitle(_ status: SenderListStatus) -> String {
        switch status {
        case .whitelisted: "Whitelisted"
        case .blacklisted: "Blacklisted"
        case .neither: "Neither whitelisted nor blacklisted"
        }
    }

    private func statusIcon(_ status: SenderListStatus) -> String {
        switch status {
        case .whitelisted: "checkmark.shield.fill"
        case .blacklisted: "hand.raised.fill"
        case .neither: "minus.circle"
        }
    }

    private func statusColor(_ status: SenderListStatus) -> Color {
        switch status {
        case .whitelisted: .green
        case .blacklisted: .red
        case .neither: .secondary
        }
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private func brandResult(_ analysis: MessageInspectorAnalysisSnapshot) -> String {
        guard let brand = analysis.claimedBrand else { return "Not detected" }
        let trust = analysis.isTrustedBrandDomain == true
            ? "trusted sender domain"
            : "untrusted sender domain"
        return "\(brand) — \(trust)"
    }

    private func subjectIndicators(_ analysis: MessageInspectorAnalysisSnapshot) -> String {
        let subjectCategories = analysis.categories.filter {
            ["urgency", "gift-card/reward"].contains($0)
        }
        return subjectCategories.isEmpty ? "none" : subjectCategories.joined(separator: ", ")
    }

    private func formattedHeaders(_ headers: [EmailHeaderField]) -> String {
        let importantNames = [
            "from", "reply-to", "return-path", "to", "cc", "subject", "date",
            "message-id", "received", "authentication-results", "received-spf",
            "dkim-signature"
        ]
        let isSecurityHeader: (EmailHeaderField) -> Bool = { header in
            let name = header.name.lowercased()
            return importantNames.contains(name)
                || name.hasPrefix("x-ms-exchange")
                || name.hasPrefix("x-forefront-antispam")
                || name == "x-microsoft-antispam"
                || name == "scl"
                || name == "bcl"
        }
        let important = headers.filter(isSecurityHeader)
        let other = headers.filter { !isSecurityHeader($0) }
        let format: ([EmailHeaderField]) -> String = { fields in
            fields.map { "\($0.name): \($0.value)" }.joined(separator: "\n\n")
        }
        var sections: [String] = []
        if !important.isEmpty {
            sections.append("IMPORTANT AND SECURITY HEADERS\n\n" + format(important))
        }
        if !other.isEmpty {
            sections.append("OTHER HEADERS\n\n" + format(other))
        }
        return sections.joined(separator: "\n\n────────────────────────────────────────\n\n")
    }
}
