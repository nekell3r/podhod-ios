import XCTest
@testable import PodhodCore

final class ProteinTrackerTests: XCTestCase {
    private let calendar = TrainingCalendar(timezone: "Europe/Moscow")

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ProteinTests-\(UUID())/protein.json")
    }

    private func moment(_ day: String, hour: Int) throws -> Date {
        let date = try XCTUnwrap(calendar.date(from: day))
        return try XCTUnwrap(calendar.calendar.date(bySettingHour: hour, minute: 30, second: 0, of: date))
    }

    @MainActor func testFreshDayIsEmptyWithoutWritingPlaceholder() async throws {
        let url = location()
        let tracker = ProteinTracker(fileURL: url, calendar: calendar)
        let today = try moment("2026-10-26", hour: 9)
        let record = tracker.day(on: today)
        XCTAssertEqual(record.date, "2026-10-26")
        XCTAssertEqual(record.revision, 0)
        XCTAssertFalse(record.isTaken(.morning))
        XCTAssertFalse(record.isTaken(.evening))
        XCTAssertTrue(tracker.days.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testMorningAndEveningAreIndependentAndPersistAfterRestart() async throws {
        let url = location()
        let tracker = ProteinTracker(fileURL: url, calendar: calendar)
        let morning = try moment("2026-10-26", hour: 9)
        let evening = try moment("2026-10-26", hour: 21)
        XCTAssertTrue(tracker.setTaken(period: .morning, on: morning, taken: true))
        XCTAssertTrue(tracker.day(on: morning).isTaken(.morning))
        XCTAssertFalse(tracker.day(on: morning).isTaken(.evening))
        XCTAssertTrue(tracker.setTaken(period: .evening, on: evening, taken: true))
        let restored = ProteinTracker(fileURL: url, calendar: calendar)
        XCTAssertEqual(restored.day(on: morning).morningTakenAt, morning)
        XCTAssertEqual(restored.day(on: morning).eveningTakenAt, evening)
        XCTAssertEqual(restored.days.count, 1)
        XCTAssertTrue(restored.setTaken(period: .morning, on: morning, taken: false))
        XCTAssertNil(restored.day(on: morning).morningTakenAt)
        XCTAssertEqual(restored.day(on: morning).eveningTakenAt, evening)
    }

    @MainActor func testRepeatedMarkRetainsOriginalTimestamp() async throws {
        let tracker = ProteinTracker(fileURL: location(), calendar: calendar)
        let initial = try moment("2026-10-26", hour: 9)
        let repeated = initial.addingTimeInterval(600)
        XCTAssertTrue(tracker.setTaken(period: .morning, on: initial, taken: true))
        XCTAssertTrue(tracker.setTaken(period: .morning, on: repeated, taken: true))
        XCTAssertEqual(tracker.day(on: initial).morningTakenAt, initial)
        XCTAssertEqual(tracker.days.count, 1)
    }

    @MainActor func testNewDayStartsEmptyAndPreviousDayRemains() async throws {
        let tracker = ProteinTracker(fileURL: location(), calendar: calendar)
        let yesterday = try moment("2026-10-26", hour: 21)
        let today = try moment("2026-10-27", hour: 9)
        tracker.setTaken(period: .evening, on: yesterday, taken: true)
        XCTAssertFalse(tracker.day(on: today).isTaken(.evening))
        XCTAssertFalse(tracker.day(on: today).isTaken(.morning))
        tracker.setTaken(period: .morning, on: today, taken: true)
        XCTAssertEqual(tracker.days.map(\.date), ["2026-10-26", "2026-10-27"])
        XCTAssertEqual(tracker.day(on: yesterday).eveningTakenAt, yesterday)
    }

    @MainActor func testDateUsesTrainingCalendarTimezoneAtUTCMidnightBoundary() async throws {
        let tracker = ProteinTracker(fileURL: location(), calendar: calendar)
        let utc = ISO8601DateFormatter()
        let date = try XCTUnwrap(utc.date(from: "2026-10-26T22:00:00Z"))
        XCTAssertTrue(tracker.setTaken(period: .morning, on: date, taken: true))
        XCTAssertEqual(tracker.days.first?.date, "2026-10-27")
    }

    @MainActor func testReplaceDayPreservesOtherDatesAndServerRevisionDuringLocalEdits() async throws {
        let url = location()
        let tracker = ProteinTracker(fileURL: url, calendar: calendar)
        let morning = try moment("2026-10-26", hour: 9)
        let next = try moment("2026-10-27", hour: 9)
        let remote = ProteinDayRecord(date: "2026-10-26", revision: 7, morningTakenAt: morning)
        XCTAssertTrue(tracker.replaceDay(remote))
        XCTAssertTrue(tracker.setTaken(period: .morning, on: next, taken: true))
        XCTAssertTrue(tracker.setTaken(period: .morning, on: morning, taken: false))
        XCTAssertEqual(tracker.day(on: morning).revision, 7)
        XCTAssertNil(tracker.day(on: morning).morningTakenAt)
        XCTAssertEqual(tracker.day(on: next).morningTakenAt, next)
        let restored = ProteinTracker(fileURL: url, calendar: calendar)
        XCTAssertEqual(restored.days, tracker.days)
    }

    @MainActor func testOlderServerRevisionCannotOverwriteCurrentDay() async throws {
        let tracker = ProteinTracker(fileURL: location(), calendar: calendar)
        let morning = try moment("2026-10-26", hour: 9)
        let current = ProteinDayRecord(date: "2026-10-26", revision: 4, morningTakenAt: morning)
        XCTAssertTrue(tracker.replaceDay(current))
        XCTAssertFalse(tracker.replaceDay(ProteinDayRecord(date: "2026-10-26", revision: 3)))
        XCTAssertEqual(tracker.day(on: morning), current)
    }

    @MainActor func testInvalidDateOrRevisionIsRejectedWithoutChangingState() async throws {
        let tracker = ProteinTracker(fileURL: location(), calendar: calendar)
        XCTAssertFalse(tracker.replaceDay(ProteinDayRecord(date: "2026-02-30")))
        XCTAssertFalse(tracker.replaceDay(ProteinDayRecord(date: "2026-10-26", revision: -1)))
        XCTAssertTrue(tracker.days.isEmpty)
    }

    @MainActor func testCorruptArchiveIsNotSilentlyResetOrOverwritten() async throws {
        let url = location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("corrupt protein archive".utf8)
        try original.write(to: url)
        let tracker = ProteinTracker(fileURL: url, calendar: calendar)
        XCTAssertTrue(tracker.loadFailed)
        XCTAssertFalse(tracker.setTaken(period: .morning, on: try moment("2026-10-26", hour: 9), taken: true))
        XCTAssertFalse(tracker.replaceDay(ProteinDayRecord(date: "2026-10-26")))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertNotNil(tracker.errorMessage)
    }

    @MainActor func testUnknownFutureVersionIsProtected() async throws {
        let url = location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"version":2,"days":[]}"#.utf8)
        try original.write(to: url)
        let tracker = ProteinTracker(fileURL: url, calendar: calendar)
        XCTAssertTrue(tracker.loadFailed)
        XCTAssertFalse(tracker.replaceDay(ProteinDayRecord(date: "2026-10-26")))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor func testMissingOptionalRecordFieldsMigrateWithDefaults() async throws {
        let url = location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"days":[{"date":"2026-10-26"}]}"#.utf8).write(to: url)
        let tracker = ProteinTracker(fileURL: url, calendar: calendar)
        XCTAssertFalse(tracker.loadFailed)
        let date = try moment("2026-10-26", hour: 9)
        XCTAssertEqual(tracker.day(on: date), ProteinDayRecord(date: "2026-10-26"))
        XCTAssertTrue(tracker.setTaken(period: .morning, on: date, taken: true))
        XCTAssertEqual(ProteinTracker(fileURL: url, calendar: calendar).day(on: date).morningTakenAt, date)
    }

    @MainActor func testDuplicateDayRecordsAreRejected() async throws {
        let url = location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"version":1,"days":[{"date":"2026-10-26"},{"date":"2026-10-26"}]}"#.utf8)
        try original.write(to: url)
        let tracker = ProteinTracker(fileURL: url, calendar: calendar)
        XCTAssertTrue(tracker.loadFailed)
        XCTAssertFalse(tracker.replaceDay(ProteinDayRecord(date: "2026-10-26")))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor func testFailedAtomicWriteDoesNotApplyUnsavedMark() async throws {
        let tracker = ProteinTracker(fileURL: URL(fileURLWithPath: "/dev/null/protein.json"), calendar: calendar)
        XCTAssertFalse(tracker.setTaken(period: .morning, on: try moment("2026-10-26", hour: 9), taken: true))
        XCTAssertTrue(tracker.days.isEmpty)
        XCTAssertNotNil(tracker.errorMessage)
    }
}
