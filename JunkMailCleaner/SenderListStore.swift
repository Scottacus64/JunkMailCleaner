import Combine
import Foundation

nonisolated enum SenderListStatus: String, Sendable {
    case whitelisted
    case blacklisted
    case neither
}

@MainActor
final class SenderListStore: ObservableObject {
    @Published private(set) var blacklistedAddresses: Set<String>
    @Published private(set) var whitelistedAddresses: Set<String>

    var blacklistCount: Int { blacklistedAddresses.count }

    private let defaults: UserDefaults
    private let blacklistKey: String
    private let whitelistKey: String

    init(
        defaults: UserDefaults = .standard,
        blacklistKey: String = "senderBlacklist",
        whitelistKey: String = "senderWhitelist"
    ) {
        self.defaults = defaults
        self.blacklistKey = blacklistKey
        self.whitelistKey = whitelistKey
        let blacklist = Set(
            (defaults.stringArray(forKey: blacklistKey) ?? [])
                .compactMap(Self.normalize)
        )
        let whitelist = Set(
            (defaults.stringArray(forKey: whitelistKey) ?? [])
                .compactMap(Self.normalize)
        )
        // A persisted whitelist wins if data from an older version ever conflicts.
        whitelistedAddresses = whitelist
        blacklistedAddresses = blacklist.subtracting(whitelist)
        persist()
    }

    func status(for address: String) -> SenderListStatus {
        guard let normalized = Self.normalize(address) else { return .neither }
        if whitelistedAddresses.contains(normalized) { return .whitelisted }
        if blacklistedAddresses.contains(normalized) { return .blacklisted }
        return .neither
    }

    @discardableResult
    func addToBlacklist(_ address: String) -> Bool {
        guard let normalized = Self.normalize(address) else { return false }
        whitelistedAddresses.remove(normalized)
        let inserted = blacklistedAddresses.insert(normalized).inserted
        persist()
        return inserted
    }

    func removeFromBlacklist(_ address: String) {
        guard let normalized = Self.normalize(address) else { return }
        blacklistedAddresses.remove(normalized)
        persist()
    }

    @discardableResult
    func addToWhitelist(_ address: String) -> Bool {
        guard let normalized = Self.normalize(address) else { return false }
        blacklistedAddresses.remove(normalized)
        let inserted = whitelistedAddresses.insert(normalized).inserted
        persist()
        return inserted
    }

    func removeFromWhitelist(_ address: String) {
        guard let normalized = Self.normalize(address) else { return }
        whitelistedAddresses.remove(normalized)
        persist()
    }

    nonisolated static func normalize(_ address: String) -> String? {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let opening = value.lastIndex(of: "<"),
           let closing = value[opening...].firstIndex(of: ">") {
            value = String(value[value.index(after: opening)..<closing])
        }
        if value.hasPrefix("mailto:") {
            value.removeFirst("mailto:".count)
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              !value.contains(where: { $0.isWhitespace }) else {
            return nil
        }
        return value
    }

    private func persist() {
        defaults.set(blacklistedAddresses.sorted(), forKey: blacklistKey)
        defaults.set(whitelistedAddresses.sorted(), forKey: whitelistKey)
    }
}
