import Foundation
import XCTest
@testable import JunkMailCleaner

@MainActor
final class NukeStatisticsStoreTests: XCTestCase {
    func testRecordsTotalsAndSentDateBuckets() throws {
        try withStore { store in
            store.recordNukedMessages(sentDates: [
                try date(2026, 9, 30, hour: 23),
                try date(2026, 10, 1, hour: 1),
                try date(2026, 10, 1, hour: 8)
            ])

            XCTAssertEqual(store.totalNuked, 3)
            XCTAssertEqual(store.countsByMonth, ["2026-09": 1, "2026-10": 2])
            XCTAssertEqual(store.countsByDay, ["2026-09-30": 1, "2026-10-01": 2])
            XCTAssertEqual(store.averagePerDay, 1.5)
        }
    }

    func testStatisticsSurviveReload() throws {
        try withStore { store, defaults in
            store.recordNukedMessages(sentDates: [try date(2026, 10, 1, hour: 1)])

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            let reloaded = NukeStatisticsStore(defaults: defaults, calendar: calendar)

            XCTAssertEqual(reloaded.totalNuked, 1)
            XCTAssertEqual(reloaded.countsByMonth["2026-10"], 1)
            XCTAssertEqual(reloaded.countsByDay["2026-10-01"], 1)
            XCTAssertEqual(reloaded.averagePerDay, 1)
        }
    }

    func testEmptyRecordDoesNotChangeStatistics() {
        withStore { store in
            store.recordNukedMessages(sentDates: [])

            XCTAssertEqual(store.totalNuked, 0)
            XCTAssertEqual(store.averagePerDay, 0)
            XCTAssertTrue(store.countsByMonth.isEmpty)
            XCTAssertTrue(store.countsByDay.isEmpty)
        }
    }

    private func withStore(_ body: (NukeStatisticsStore) throws -> Void) rethrows {
        try withStore { store, _ in try body(store) }
    }

    private func withStore(
        _ body: (NukeStatisticsStore, UserDefaults) throws -> Void
    ) rethrows {
        let suiteName = "NukeStatisticsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        try body(NukeStatisticsStore(defaults: defaults, calendar: calendar), defaults)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        return try XCTUnwrap(
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
        )
    }
}
