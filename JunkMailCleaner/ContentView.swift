import SwiftUI

struct ContentView: View {
    @StateObject private var senderLists = SenderListStore()
    @State private var messages: [JunkMailMessage] = []
    @State private var selectedReferences: Set<MailMessageReference> = []
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
        Table(messages) {
                TableColumn("") { message in
                    Toggle(
                        "Include this message when using Nuke",
                        isOn: selectionBinding(for: message.reference)
                    )
                    .labelsHidden()
                    .disabled(isMoving)
                    .help(
                        selectedReferences.contains(message.reference)
                            ? "Included when using Nuke"
                            : "Check to include when using Nuke"
                    )
                }
                .width(28)

                TableColumn("Sender") { message in
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
                .width(min: 190, ideal: 230)

                TableColumn("Sender Status") { message in
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
                .width(min: 125, ideal: 145)

                TableColumn("Subject") { message in
                    Text(message.subject.isEmpty ? "(No Subject)" : message.subject)
                        .lineLimit(2)
                }
                .width(min: 260, ideal: 360)

                TableColumn("Date Received") { message in
                    Text(message.dateReceived, format: .dateTime.month().day().year().hour().minute())
                }
                .width(min: 155, ideal: 175)

                TableColumn("Risk") { message in
                    Text("\(message.combinedAnalysis.riskLevel.rawValue) (\(message.combinedAnalysis.score))")
                        .fontWeight(message.combinedAnalysis.riskLevel == .high ? .semibold : .regular)
                }
                .width(min: 85, ideal: 95)

                TableColumn("Reason") { message in
                    Text(message.combinedAnalysis.reason)
                        .lineLimit(2)
                        .help(message.combinedAnalysis.reason)
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

    private func selectionBinding(for reference: MailMessageReference) -> Binding<Bool> {
        Binding(
            get: { selectedReferences.contains(reference) },
            set: { isSelected in
                if isSelected {
                    selectedReferences.insert(reference)
                } else {
                    selectedReferences.remove(reference)
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
            if messages[index].combinedAnalysis.isNukeCandidate {
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
        let automaticReferences = scannedMessages.compactMap { message in
            message.combinedAnalysis.isNukeCandidate ? message.reference : nil
        }
        selectedReferences = Set(automaticReferences)
            .union(references.intersection(displayedReferences))
    }

    private func scanJunkMail() {
        isScanning = true
        errorMessage = nil
        resultMessage = nil

        Task {
            do {
                replaceMessages(
                    with: try await MailService.fetchJunkMessages(
                        blacklistedAddresses: senderLists.blacklistedAddresses,
                        whitelistedAddresses: senderLists.whitelistedAddresses
                    )
                )
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

    private func moveMessagesToTrash(_ messagesToMove: [JunkMailMessage]) {
        guard !messagesToMove.isEmpty else { return }

        isMoving = true
        resultMessage = nil

        Task {
            do {
                let moveResult = try await MailService.moveMessagesToTrash(
                    messagesToMove.map(\.reference)
                )
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
