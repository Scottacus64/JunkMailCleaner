import Foundation
import XCTest
@testable import JunkMailCleaner

@MainActor
final class SenderListStoreTests: XCTestCase {
    func testAddingBlacklistStoresNormalizedExactSenderAndAvoidsDuplicates() {
        withStore { store, _ in
            XCTAssertTrue(store.addToBlacklist("  Sales086@Sabeng.IT  "))
            XCTAssertFalse(store.addToBlacklist("sales086@sabeng.it"))
            XCTAssertEqual(store.blacklistedAddresses, ["sales086@sabeng.it"])
            XCTAssertEqual(store.blacklistCount, 1)
        }
    }

    func testBlacklistSurvivesStorageReload() {
        withStore { store, defaults in
            store.addToBlacklist("Sales086@Sabeng.IT")
            let reloaded = SenderListStore(defaults: defaults)

            XCTAssertEqual(reloaded.status(for: "sales086@sabeng.it"), .blacklisted)
            XCTAssertEqual(reloaded.blacklistCount, 1)
        }
    }

    func testMatchingIsCaseInsensitiveAndDoesNotBlockWholeDomain() {
        withStore { store, _ in
            store.addToBlacklist("Sales086@Sabeng.IT")

            XCTAssertEqual(store.status(for: "SALES086@SABENG.IT"), .blacklisted)
            XCTAssertEqual(store.status(for: "another@sabeng.it"), .neither)
        }
    }

    func testWhitelistAndBlacklistConflictsAreResolved() {
        withStore { store, _ in
            store.addToWhitelist("sales086@sabeng.it")
            store.addToBlacklist("SALES086@SABENG.IT")
            XCTAssertEqual(store.status(for: "sales086@sabeng.it"), .blacklisted)
            XCTAssertFalse(store.whitelistedAddresses.contains("sales086@sabeng.it"))

            store.addToWhitelist("sales086@sabeng.it")
            XCTAssertEqual(store.status(for: "sales086@sabeng.it"), .whitelisted)
            XCTAssertFalse(store.blacklistedAddresses.contains("sales086@sabeng.it"))
        }
    }

    func testBlacklistedSenderQualifiesForDeletionWithBlacklistReason() {
        withStore { store, _ in
            store.addToBlacklist("ordinary@example.com")
            var message = makeMessage(status: store.status(for: "ordinary@example.com"))

            XCTAssertEqual(message.combinedAnalysis.score, 100)
            XCTAssertEqual(message.combinedAnalysis.riskLevel, .high)
            XCTAssertEqual(message.combinedAnalysis.reason, "Blacklisted sender")
            XCTAssertTrue(message.combinedAnalysis.isAutoDeleteCandidate)
            XCTAssertTrue(message.combinedAnalysis.isNukeCandidate)

            store.removeFromBlacklist("ordinary@example.com")
            message.updateSenderListStatus(store.status(for: "ordinary@example.com"))
            XCTAssertEqual(message.combinedAnalysis.score, 0)
            XCTAssertEqual(message.combinedAnalysis.reason, "No suspicious sender-address patterns")
            XCTAssertFalse(message.combinedAnalysis.isAutoDeleteCandidate)
        }
    }

    func testAutomaticSpamDetectionDoesNotPopulateBlacklist() {
        withStore { store, _ in
            let message = JunkMailMessage(
                reference: reference,
                senderName: "AARP Opportunity",
                senderAddress: "member@salesurge.shop",
                senderAnalysis: SenderAddressAnalyzer.analyze("member@salesurge.shop"),
                analyzeContent: true,
                replyTo: "",
                subject: "Refresh your routine with AARP membership",
                dateReceived: Date(timeIntervalSince1970: 0),
                body: "",
                authenticationResults: ""
            )

            XCTAssertGreaterThan(message.combinedAnalysis.score, 0)
            XCTAssertTrue(store.blacklistedAddresses.isEmpty)
        }
    }

    private func withStore(
        _ body: (SenderListStore, UserDefaults) -> Void
    ) {
        let suiteName = "SenderListStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(SenderListStore(defaults: defaults), defaults)
    }

    private func makeMessage(status: SenderListStatus) -> JunkMailMessage {
        JunkMailMessage(
            reference: Self.reference,
            senderName: "Ordinary Sender",
            senderAddress: "ordinary@example.com",
            senderAnalysis: SenderAddressAnalyzer.analyze("ordinary@example.com"),
            analyzeContent: true,
            replyTo: "",
            subject: "Hello",
            dateReceived: Date(timeIntervalSince1970: 0),
            body: "",
            authenticationResults: "",
            senderListStatus: status
        )
    }

    private static let reference = MailMessageReference(
        accountIdentifier: "test-account",
        messageID: "message-id",
        libraryIdentifier: "library-id"
    )

    private var reference: MailMessageReference { Self.reference }
}
