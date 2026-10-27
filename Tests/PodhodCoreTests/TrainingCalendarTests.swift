import XCTest
@testable import PodhodCore

final class TrainingCalendarTests: XCTestCase {
    let calendar = TrainingCalendar(timezone: "Europe/Moscow")

    func testMondayWeekAcrossYearBoundary() throws {
        let sunday = try XCTUnwrap(calendar.date(from: "2027-01-03"))
        XCTAssertEqual(calendar.dayKey(for: calendar.weekStart(containing: sunday)), "2026-12-28")
        XCTAssertEqual(calendar.weekDates(containing: sunday).map { calendar.dayKey(for: $0) },
                       ["2026-12-28", "2026-12-29", "2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02", "2027-01-03"])
    }

    func testInvalidDateIsRejectedRatherThanNormalized() {
        XCTAssertNil(calendar.date(from: "2026-02-30"))
        XCTAssertNil(calendar.date(from: "2026-13-01"))
        XCTAssertNil(calendar.date(from: "2026-1-01"))
        XCTAssertNotNil(calendar.date(from: "2028-02-29"))
    }

    func testWeekDatesRespectDST() throws {
        let berlin = TrainingCalendar(timezone: "Europe/Berlin")
        let date = try XCTUnwrap(berlin.date(from: "2026-10-25"))
        let dates = berlin.weekDates(containing: date)
        XCTAssertEqual(dates.map { berlin.dayKey(for: $0) },
                       ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24", "2026-10-25"])
    }

    @MainActor func testDatedEditDoesNotChangeTemplateOtherWeekOrHistory() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CalendarTests-\(UUID())/training.json")
        let store = WorkoutStore(fileURL: url)
        store.loadExample()
        let monday = try XCTUnwrap(calendar.date(from: "2026-11-02"))
        let nextMonday = try XCTUnwrap(calendar.date(from: "2026-11-09"))
        store.ensureWeek(containing: monday)
        store.ensureWeek(containing: nextMonday)
        let template = store.archive.week
        let next = store.scheduledWeek(containing: nextMonday)
        var day = store.scheduledWeek(containing: monday).day(on: monday, calendar: calendar)
        day.title = "Только эта неделя"
        XCTAssertTrue(store.saveScheduledDay(day, on: monday))
        XCTAssertEqual(store.archive.week, template)
        XCTAssertEqual(store.scheduledWeek(containing: nextMonday), next)
        XCTAssertTrue(store.archive.history.isEmpty)
        let restored = WorkoutStore(fileURL: url)
        XCTAssertEqual(restored.scheduledWeek(containing: monday).day(on: monday, calendar: calendar).title, "Только эта неделя")
    }

    @MainActor func testMovePreservesIdentityAndRejectsOccupiedOrOtherWeek() async throws {
        let store = WorkoutStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("CalendarTests-\(UUID())/training.json"))
        store.loadExample()
        let monday = try XCTUnwrap(calendar.date(from: "2026-11-02"))
        let tuesday = try XCTUnwrap(calendar.date(from: "2026-11-03"))
        let wednesday = try XCTUnwrap(calendar.date(from: "2026-11-04"))
        let nextMonday = try XCTUnwrap(calendar.date(from: "2026-11-09"))
        store.ensureWeek(containing: monday)
        let week = store.scheduledWeek(containing: monday)
        let workout = try XCTUnwrap(week.workouts.first { $0.plannedDate == "2026-11-02" })
        XCTAssertFalse(store.moveScheduledWorkout(id: workout.id, in: week.weekStart, to: wednesday))
        XCTAssertEqual(store.scheduledWeek(containing: monday), week)
        XCTAssertFalse(store.moveScheduledWorkout(id: workout.id, in: week.weekStart, to: nextMonday))
        XCTAssertTrue(store.moveScheduledWorkout(id: workout.id, in: week.weekStart, to: tuesday))
        let moved = try XCTUnwrap(store.scheduledWeek(containing: monday).workouts.first { $0.id == workout.id })
        XCTAssertEqual(moved.plannedDate, "2026-11-03")
        XCTAssertEqual(moved.exercises, workout.exercises)
        XCTAssertTrue(store.scheduledWeek(containing: monday).day(on: monday, calendar: calendar).exercises.isEmpty)
    }

    @MainActor func testScheduledStartSnapshotsDateAndSurvivesPlanChange() async throws {
        let store = WorkoutStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("CalendarTests-\(UUID())/training.json"))
        store.loadExample()
        let monday = try XCTUnwrap(calendar.date(from: "2026-11-02"))
        XCTAssertTrue(store.startScheduled(on: monday))
        let active = try XCTUnwrap(store.archive.active)
        XCTAssertEqual(active.plannedDate, "2026-11-02")
        XCTAssertNotNil(active.scheduledWorkoutID)
        var day = store.scheduledWeek(containing: monday).day(on: monday, calendar: calendar)
        day.title = "Новое название"
        day.exercises.removeLast()
        XCTAssertTrue(store.saveScheduledDay(day, on: monday))
        XCTAssertEqual(store.archive.active, active)
    }

    @MainActor func testFirstMigrationCreatesBackupBeforeOverwrite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CalendarTests-\(UUID())/training.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var archive = TrainingArchive()
        archive.version = 1
        let original = try JSONEncoder().encode(archive)
        try original.write(to: url)
        let store = WorkoutStore(fileURL: url)
        XCTAssertTrue(store.saveDay(TrainingDay(weekday: 1, title: "Изменено", exercises: [])))
        XCTAssertEqual(try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("training-v1-backup.json")), original)
    }
}
