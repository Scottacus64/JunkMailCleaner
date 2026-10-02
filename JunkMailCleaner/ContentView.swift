import SwiftUI

struct ContentView: View {
    @StateObject private var senderLists = SenderListStore()
    @StateObject private var nukeStatistics = NukeStatisticsStore()
    @State private var messages: [JunkMailMessage] = []
    @State private var selectedReferences: Set<MailMessageReference> = []
    @State private var tableSelection: MailMessageReference?
    @State private var inspectedMessage: JunkMailMessage?
    @State private var isScanning = false
    @State private var isMoving = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var hasScanned = false
    @State private var hasStartedInitialScan = false
    @State private var isShowingBlacklist = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 1_250, minHeight: 520)
        .task {
            guard !hasStartedInitialScan else { return }
            hasStartedInitialScan = true
            scanJunkMail()
        }
        .sheet(isPresented: $isShowingBlacklist) {
            BlacklistManagementView(senderLists: senderLists) { address in
                removeFromBlacklist(address)
            }
        }
        .sheet(item: $inspectedMessage) { message in
            MessageInspectorView(
                message: message,
                senderLists: senderLists,
                senderStatusChanged: refreshSenderListStatus,
                messageDeleted: removeDeletedMessage
            )
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Junk Mail Cleaner")
                    .font(.title2.bold())
                Text("Review Junk mail and manually move selected messages to Trash")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            headerStatistic("Total nuked", value: nukeStatistics.totalNuked.formatted())
            headerStatistic(
                "Average per day",
                value: nukeStatistics.averagePerDay.formatted(.number.precision(.fractionLength(1)))
            )

            Button {
                isShowingBlacklist = true
            } label: {
                Label(
                    "Blacklist (\(senderLists.blacklistCount))",
                    systemImage: "hand.raised.fill"
                )
            }
            .disabled(isMoving)

            Button(action: scanJunkMail) {
                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Scan Junk Mail", systemImage: "envelope.badge.shield.half.filled")
                }
            }
            .disabled(isScanning || isMoving)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private func headerStatistic(_ title: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            ContentUnavailableView {
                Label("Unable to Scan Mail", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
                    .textSelection(.enabled)
            } actions: {
                Button("Try Again", action: scanJunkMail)
            }
        } else if messages.isEmpty {
            ContentUnavailableView {
                Label(
                    hasScanned ? "No Junk Mail" : "Ready to Scan",
                    systemImage: hasScanned ? "tray" : "envelope.open"
                )
            } description: {
                Text(hasScanned
                     ? "The Hotmail Junk mailbox in Apple Mail is empty."
                     : "Click Scan Junk Mail to load messages without changing them.")
            }
        } else {
            VStack(spacing: 0) {
                summary
                Divider()
                selectionControls
                Divider()
                messageTable
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 24) {
            summaryItem("Messages scanned", value: messages.count)
            summaryItem("High risk", value: count(for: .high))
            summaryItem("Medium risk", value: count(for: .medium))
            summaryItem("Low risk", value: count(for: .low))
            summaryItem(
                "Auto-delete candidates",
                value: messages.count { $0.combinedAnalysis.isAutoDeleteCandidate }
            )
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Nuke", action: moveSelectedMessages)
                    .disabled(selectedMessages.isEmpty || isMoving)

                if isMoving {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }

            if let resultMessage {
                Text(resultMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var messageTable: some View {
        Table(messages, selection: $tableSelection) {
                TableColumn("") { message in
                    Toggle(
                        "Include this message when using Nuke",
                        isOn: selectionBinding(for: message)
                    )
                    .labelsHidden()
                    .disabled(isMoving || message.senderListStatus == .whitelisted)
                    .help(
                        selectedReferences.contains(message.reference)
                            ? "Included when using Nuke"
                            : "Check to include when using Nuke"
                    )
                }
                .width(28)

                TableColumn("Sender") { message in
                    inspectableCell(message) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.senderName.isEmpty ? message.senderAddress : message.senderName)
                                .lineLimit(1)
                            if !message.senderName.isEmpty {
                                Text(message.senderAddress)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .width(min: 190, ideal: 230)

                TableColumn("Sender Status") { message in
                    inspectableCell(message) {
                        HStack(spacing: 6) {
                            Toggle(
                                "Blacklist exact sender",
                                isOn: blacklistBinding(for: message)
                            )
                            .labelsHidden()
                            .tint(.red)
                            .disabled(isMoving)

                            Label(
                                senderStatusTitle(message.senderListStatus),
                                systemImage: senderStatusIcon(message.senderListStatus)
                            )
                            .foregroundStyle(senderStatusColor(message.senderListStatus))
                            .font(.caption)
                            .lineLimit(1)
                        }
                    }
                }
                .width(min: 125, ideal: 145)

                TableColumn("Subject") { message in
                    inspectableCell(message) {
                        Text(message.subject.isEmpty ? "(No Subject)" : message.subject)
                            .lineLimit(2)
                    }
                }
                .width(min: 260, ideal: 360)

                TableColumn("Date Received") { message in
                    inspectableCell(message) {
                        Text(message.dateReceived, format: .dateTime.month().day().year().hour().minute())
                    }
                }
                .width(min: 155, ideal: 175)

                TableColumn("Risk") { message in
                    inspectableCell(message) {
                        Text("\(message.combinedAnalysis.riskLevel.rawValue) (\(message.combinedAnalysis.score))")
                            .fontWeight(message.combinedAnalysis.riskLevel == .high ? .semibold : .regular)
                    }
                }
                .width(min: 85, ideal: 95)

                TableColumn("Reason") { message in
                    inspectableCell(message) {
                        Text(message.combinedAnalysis.reason)
                            .lineLimit(2)
                            .help(message.combinedAnalysis.reason)
                    }
                }
                .width(min: 250, ideal: 320)

            }
    }

    private func summaryItem(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(.headline.monospacedDigit())
        }
    }

    private func count(for riskLevel: SenderRiskLevel) -> Int {
        messages.count { $0.combinedAnalysis.riskLevel == riskLevel }
    }

    private var selectedMessages: [JunkMailMessage] {
        messages.filter { selectedReferences.contains($0.reference) }
    }

    private func inspect(_ message: JunkMailMessage) {
        tableSelection = message.reference
        inspectedMessage = message
    }

    private func inspectableCell<Content: View>(
        _ message: JunkMailMessage,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    inspect(message)
                }
            )
            .contextMenu {
                Button("Inspect Message") {
                    inspect(message)
                }
            }
    }

    private func selectionBinding(for message: JunkMailMessage) -> Binding<Bool> {
        Binding(
            get: {
                message.senderListStatus != .whitelisted
                    && selectedReferences.contains(message.reference)
            },
            set: { isSelected in
                if isSelected, message.senderListStatus != .whitelisted {
                    selectedReferences.insert(message.reference)
                } else {
                    selectedReferences.remove(message.reference)
                }
            }
        )
    }

    private func blacklistBinding(for message: JunkMailMessage) -> Binding<Bool> {
        Binding(
            get: { senderLists.status(for: message.senderAddress) == .blacklisted },
            set: { isBlacklisted in
                if isBlacklisted {
                    senderLists.addToBlacklist(message.senderAddress)
                } else {
                    senderLists.removeFromBlacklist(message.senderAddress)
                }
                refreshSenderListStatus(for: message.senderAddress)
            }
        )
    }

    private func refreshSenderListStatus(for address: String) {
        guard let normalizedAddress = SenderListStore.normalize(address) else { return }
        for index in messages.indices
        where SenderListStore.normalize(messages[index].senderAddress) == normalizedAddress {
            let status = senderLists.status(for: messages[index].senderAddress)
            messages[index].updateSenderListStatus(status)
            if status != .whitelisted, messages[index].combinedAnalysis.isNukeCandidate {
                selectedReferences.insert(messages[index].reference)
            } else {
                selectedReferences.remove(messages[index].reference)
            }
        }
        messages.sort { first, second in
            if first.combinedAnalysis.score != second.combinedAnalysis.score {
                return first.combinedAnalysis.score > second.combinedAnalysis.score
            }
            return first.dateReceived > second.dateReceived
        }
    }

    private func removeFromBlacklist(_ address: String) {
        senderLists.removeFromBlacklist(address)
        refreshSenderListStatus(for: address)
    }

    private func senderStatusTitle(_ status: SenderListStatus) -> String {
        switch status {
        case .whitelisted: "Whitelisted"
        case .blacklisted: "Blacklisted"
        case .neither: "Neither"
        }
    }

    private func senderStatusIcon(_ status: SenderListStatus) -> String {
        switch status {
        case .whitelisted: "checkmark.shield.fill"
        case .blacklisted: "hand.raised.fill"
        case .neither: "minus.circle"
        }
    }

    private func senderStatusColor(_ status: SenderListStatus) -> Color {
        switch status {
        case .whitelisted: .green
        case .blacklisted: .red
        case .neither: .secondary
        }
    }

    private func replaceMessages(
        with scannedMessages: [JunkMailMessage],
        additionallySelecting references: Set<MailMessageReference> = []
    ) {
        messages = scannedMessages
        let displayedReferences = Set(scannedMessages.map(\.reference))
        if let tableSelection, !displayedReferences.contains(tableSelection) {
            self.tableSelection = nil
        }
        let automaticReferences = scannedMessages.compactMap { message in
            message.senderListStatus != .whitelisted && message.combinedAnalysis.isNukeCandidate
                ? message.reference
                : nil
        }
        let eligibleAdditionalReferences = references.filter { reference in
            scannedMessages.contains { message in
                message.reference == reference && message.senderListStatus != .whitelisted
            }
        }
        selectedReferences = Set(automaticReferences)
            .union(eligibleAdditionalReferences.intersection(displayedReferences))
    }

    private func scanJunkMail() {
        isScanning = true
        errorMessage = nil
        resultMessage = nil

        Task {
            do {
                let scannedMessages = try await MailService.fetchJunkMessages(
                        blacklistedAddresses: senderLists.blacklistedAddresses,
                        whitelistedAddresses: senderLists.whitelistedAddresses
                    )
                replaceMessages(with: scannedMessages)
                hasScanned = true
            } catch {
                messages = []
                selectedReferences = []
                errorMessage = error.localizedDescription
            }
            isScanning = false
        }
    }

    private func moveSelectedMessages() {
        moveMessagesToTrash(selectedMessages)
    }

    private func removeDeletedMessage(_ deletedMessage: JunkMailMessage) {
        messages.removeAll { $0.reference == deletedMessage.reference }
        selectedReferences.remove(deletedMessage.reference)
        if tableSelection == deletedMessage.reference {
            tableSelection = nil
        }
        resultMessage = "Message moved to Trash without nuking it."
    }

    private func moveMessagesToTrash(_ messagesToMove: [JunkMailMessage]) {
        guard !messagesToMove.isEmpty else { return }

        isMoving = true
        resultMessage = nil

        Task {
            do {
                let moveResult = try await MailService.moveMessagesToTrash(
                    messagesToMove.map(\.reference)
                )
                let movedSentDates = messagesToMove.compactMap { message in
                    moveResult.movedReferences.contains(message.reference) ? message.dateSent : nil
                }
                nukeStatistics.recordNukedMessages(sentDates: movedSentDates)
                resultMessage = moveResultDescription(moveResult, selectedMessages: messagesToMove)

                do {
                    replaceMessages(
                        with: try await MailService.fetchJunkMessages(
                            blacklistedAddresses: senderLists.blacklistedAddresses,
                            whitelistedAddresses: senderLists.whitelistedAddresses
                        ),
                        additionallySelecting: Set(moveResult.failures.map(\.reference))
                    )
                    hasScanned = true
                } catch {
                    resultMessage = "\(resultMessage ?? "") The Junk mailbox could not be rescanned: \(error.localizedDescription)"
                }
            } catch {
                resultMessage = "No messages were moved: \(error.localizedDescription)"
            }

            isMoving = false
        }
    }

    private func moveResultDescription(
        _ result: MailMoveResult,
        selectedMessages: [JunkMailMessage]
    ) -> String {
        let movedCount = result.movedReferences.count
        var parts = ["\(movedCount) \(movedCount == 1 ? "message" : "messages") moved to Trash."]

        if !result.failures.isEmpty {
            let messagesByReference = Dictionary(
                uniqueKeysWithValues: selectedMessages.map { ($0.reference, $0) }
            )
            var failureDescriptions: [String] = []
            for failure in result.failures {
                let message = messagesByReference[failure.reference]
                let sender = message?.senderAddress ?? "Unknown sender"
                let subject = message?.subject.isEmpty == false ? message?.subject ?? "" : "(No Subject)"
                failureDescriptions.append("\(sender) — \(subject): \(failure.message)")
                print(
                    "[JunkMailCleaner] Move failed for \(sender) — \(subject) "
                    + "[Message-ID: \(failure.reference.messageID)]: \(failure.message)"
                )
            }

            parts.append(
                "\(result.failures.count) failed:\n"
                    + failureDescriptions.joined(separator: "\n")
            )
        }

        return parts.joined(separator: " ")
    }
}

private struct BlacklistManagementView: View {
    @ObservedObject var senderLists: SenderListStore
    let remove: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sender Blacklist")
                        .font(.title2.bold())
                    Text("\(senderLists.blacklistCount) blacklisted \(senderLists.blacklistCount == 1 ? "address" : "addresses")")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if senderLists.blacklistedAddresses.isEmpty {
                ContentUnavailableView(
                    "No Blacklisted Senders",
                    systemImage: "hand.raised",
                    description: Text("Use the Blacklist checkbox beside a message to add its exact sender address.")
                )
            } else {
                List(senderLists.blacklistedAddresses.sorted(), id: \.self) { address in
                    HStack {
                        Text(address)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            remove(address)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
    }
}

#Preview {
    ContentView()
}
