import Combine
import Foundation

@MainActor
final class NukeStatisticsStore: ObservableObject {
    @Published private(set) var totalNuked: Int
    @Published private(set) var countsByMonth: [String: Int]
    @Published private(set) var countsByDay: [String: Int]

    var averagePerDay: Double {
        guard !countsByDay.isEmpty else { return 0 }
        return Double(totalNuked) / Double(countsByDay.count)
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let calendar: Calendar

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "nukeStatistics",
        calendar: Calendar = .current
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.calendar = calendar

        if let data = defaults.data(forKey: storageKey),
           let statistics = try? JSONDecoder().decode(StoredStatistics.self, from: data) {
            totalNuked = statistics.totalNuked
            countsByMonth = statistics.countsByMonth
            countsByDay = statistics.countsByDay
        } else {
            totalNuked = 0
            countsByMonth = [:]
            countsByDay = [:]
        }
    }

    func recordNukedMessages(sentDates: [Date]) {
        guard !sentDates.isEmpty else { return }

        for date in sentDates {
            countsByMonth[monthKey(for: date), default: 0] += 1
            countsByDay[dayKey(for: date), default: 0] += 1
        }
        totalNuked += sentDates.count
        persist()
    }

    private func monthKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func persist() {
        let statistics = StoredStatistics(
            totalNuked: totalNuked,
            countsByMonth: countsByMonth,
            countsByDay: countsByDay
        )
        guard let data = try? JSONEncoder().encode(statistics) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

private struct StoredStatistics: Codable {
    let totalNuked: Int
    let countsByMonth: [String: Int]
    let countsByDay: [String: Int]
}
