import XCTest
@testable import PodhodCore

final class SupplementReminderScheduleTests: XCTestCase {
    private var calendar: Calendar {
        TrainingCalendar(timezone: "America/New_York").calendar
    }

    private func date(_ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    func testCreatineSkipsTheRemainingDayAndKeepsTomorrowAtLocalHoursAcrossDST() {
        let slots = SupplementReminderSchedule.slots(for: .creatine, mutedUntil: date(8),
            now: date(7, hour: 12), calendar: calendar)
        XCTAssertEqual(slots.filter { $0.date == nil }.map(\.hour), [9, 11])
        let deferred = slots.compactMap(\.date).sorted()
        XCTAssertEqual(deferred, (8...10).flatMap { day in
            stride(from: 13, through: 23, by: 2).map { date(day, hour: $0, minute: 30) }
        })
    }

    func testEachProteinPeriodCanBeMutedIndependentlyAndUndoRestoresDailySchedule() {
        let now = date(7, hour: 8)
        let periods: [(SupplementReminderSchedule.Series, SupplementReminderSchedule.Series)] = [
            (.proteinMorning, .proteinEvening), (.proteinEvening, .proteinMorning)
        ]
        for (muted, other) in periods {
            let mutedSlots = SupplementReminderSchedule.slots(for: muted, mutedUntil: date(8), now: now, calendar: calendar)
            XCTAssertEqual(mutedSlots.compactMap(\.date).sorted(), (8...10).flatMap { day in
                muted.hours.map { date(day, hour: $0, minute: 30) }
            })
            for series in [other, muted] {
                let slots = SupplementReminderSchedule.slots(for: series, mutedUntil: nil, now: now, calendar: calendar)
                XCTAssertEqual(slots.map(\.hour), series.hours)
                XCTAssertTrue(slots.allSatisfy { $0.date == nil })
            }
        }
    }

    func testDeferringEverySeriesStaysWithinTheLocalNotificationBudget() {
        let slots = SupplementReminderSchedule.Series.allCases.flatMap { series in
            SupplementReminderSchedule.slots(for: series, mutedUntil: date(8), now: date(7), calendar: calendar)
        }
        XCTAssertEqual(slots.count, 48)
        XCTAssertTrue(slots.allSatisfy { slot in slot.date.map { $0 >= date(8) } == true })
        let nextDay = SupplementReminderSchedule.slots(for: .creatine, mutedUntil: date(8), now: date(8), calendar: calendar)
        XCTAssertEqual(nextDay.map(\.hour), [9, 11, 13, 15, 17, 19, 21, 23])
        XCTAssertTrue(nextDay.allSatisfy { $0.date == nil })
    }
}
