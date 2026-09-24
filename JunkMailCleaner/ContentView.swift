import SwiftUI

struct ContentView: View {
    @State private var messages: [JunkMailMessage] = []
    @State private var selectedMessageIDs: Set<MailMessageReference> = []
    @State private var isScanning = false
    @State private var isMoving = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var hasScanned = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 1_250, minHeight: 520)
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
                Button("Clear Selection", action: clearSelection)
                    .disabled(selectedMessageIDs.isEmpty || isMoving)

                Divider()
                    .frame(height: 20)

                Button("Nuke", action: moveSelectedMessages)
                    .disabled(selectedMessageIDs.isEmpty || isMoving)

                if isMoving {
                    ProgressView()
                        .controlSize(.small)
                }

                Text("\(selectedMessageIDs.count) selected")
                    .foregroundStyle(.secondary)

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
                        "Select message from \(message.senderAddress)",
                        isOn: selectionBinding(for: message.reference)
                    )
                    .labelsHidden()
                    .disabled(isMoving)
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

                TableColumn("Auto-delete Candidate") { message in
                    Text(message.combinedAnalysis.isAutoDeleteCandidate ? "YES" : "NO")
                        .fontWeight(message.combinedAnalysis.isAutoDeleteCandidate ? .semibold : .regular)
                }
                .width(min: 135, ideal: 150)
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

    private func selectionBinding(for reference: MailMessageReference) -> Binding<Bool> {
        Binding {
            selectedMessageIDs.contains(reference)
        } set: { isSelected in
            if isSelected {
                selectedMessageIDs.insert(reference)
            } else {
                selectedMessageIDs.remove(reference)
            }
        }
    }

    private func clearSelection() {
        selectedMessageIDs.removeAll()
    }

    private func highRiskReferences(
        in messages: [JunkMailMessage]
    ) -> Set<MailMessageReference> {
        Set(
            messages
                .filter { $0.combinedAnalysis.riskLevel == .high }
                .map(\.reference)
        )
    }

    private func scanJunkMail() {
        isScanning = true
        errorMessage = nil
        resultMessage = nil
        selectedMessageIDs.removeAll()

        Task {
            do {
                messages = try await MailService.fetchJunkMessages()
                selectedMessageIDs = highRiskReferences(in: messages)
                hasScanned = true
            } catch {
                messages = []
                errorMessage = error.localizedDescription
            }
            isScanning = false
        }
    }

    private func moveSelectedMessages() {
        let selectedMessages = messages.filter { selectedMessageIDs.contains($0.reference) }
        guard !selectedMessages.isEmpty else { return }

        isMoving = true
        resultMessage = nil

        Task {
            do {
                let moveResult = try await MailService.moveMessagesToTrash(
                    selectedMessages.map(\.reference)
                )
                resultMessage = moveResultDescription(moveResult, selectedMessages: selectedMessages)

                do {
                    messages = try await MailService.fetchJunkMessages()
                    hasScanned = true
                    selectedMessageIDs = highRiskReferences(in: messages)
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
            for failure in result.failures {
                let message = messagesByReference[failure.reference]
                let sender = message?.senderAddress ?? "Unknown sender"
                let subject = message?.subject.isEmpty == false ? message?.subject ?? "" : "(No Subject)"
                print(
                    "[JunkMailCleaner] Move failed for \(sender) — \(subject) "
                    + "[Message-ID: \(failure.reference.messageID)]: \(failure.message)"
                )
            }

            parts.append(
                "\(result.failures.count) failed. See the Xcode console for details."
            )
        }

        return parts.joined(separator: " ")
    }
}

#Preview {
    ContentView()
}
