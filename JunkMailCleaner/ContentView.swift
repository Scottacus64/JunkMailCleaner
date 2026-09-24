import SwiftUI

struct ContentView: View {
    @State private var messages: [JunkMailMessage] = []
    @State private var isScanning = false
    @State private var isMoving = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var hasScanned = false
    @State private var hasStartedInitialScan = false

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
                Button("Nuke", action: movePositiveRiskMessages)
                    .disabled(positiveRiskMessages.isEmpty || isMoving)

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
                        "Included when using Nuke because risk is greater than zero",
                        isOn: .constant(message.combinedAnalysis.score > 0)
                    )
                    .labelsHidden()
                    .allowsHitTesting(false)
                    .help(
                        message.combinedAnalysis.score > 0
                            ? "Included when using Nuke"
                            : "Not included when using Nuke"
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

    private var positiveRiskMessages: [JunkMailMessage] {
        messages.filter { $0.combinedAnalysis.score > 0 }
    }

    private func scanJunkMail() {
        isScanning = true
        errorMessage = nil
        resultMessage = nil

        Task {
            do {
                messages = try await MailService.fetchJunkMessages()
                hasScanned = true
            } catch {
                messages = []
                errorMessage = error.localizedDescription
            }
            isScanning = false
        }
    }

    private func movePositiveRiskMessages() {
        moveMessagesToTrash(positiveRiskMessages)
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
                    messages = try await MailService.fetchJunkMessages()
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
