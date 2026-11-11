import XCTest
@testable import PodhodCore

final class SavedTemplatesAndCreatineTests: XCTestCase {
    func testCreatineAcknowledgesSerializedTimestampAfterRestart() throws {
        let date = Date(timeIntervalSince1970: 1_794_420_000.123456)
        let document = CreatineDayDocument(date: "2026-11-11", takenAt: date)
        let original = RevisionedDocumentState(localDocument: document)
        let bytes = try JSONEncoder().encode(original)
        var restored = try JSONDecoder().decode(RevisionedDocumentState<CreatineDayDocument>.self, from: bytes)
        let pending = try XCTUnwrap(restored.pending)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let transmittedDate = try XCTUnwrap(formatter.date(from: formatter.string(from: date)))
        XCTAssertNotEqual(date, transmittedDate)
        let remote = RevisionedDocumentRecord(revision: Int64(1),
            document: CreatineDayDocument(date: document.date, takenAt: transmittedDate))

        try restored.acknowledge(requestID: pending.requestID, record: remote)

        XCTAssertNil(restored.pending)
        XCTAssertEqual(restored.acknowledged, remote)
        XCTAssertEqual(restored.document.takenAt, date)
        XCTAssertTrue(restored.isValid(documentIsValid: { $0.isValid }))
        try restored.receive(remote)
        XCTAssertNil(restored.conflict)
    }

    func testCreatineAcknowledgmentStillRejectsDifferentMark() throws {
        let date = Date(timeIntervalSince1970: 1_794_420_000.123456)
        let document = CreatineDayDocument(date: "2026-11-11", takenAt: date)
        var futureVersion = document
        futureVersion.version = 2
        let changed = [
            CreatineDayDocument(date: document.date),
            CreatineDayDocument(date: document.date, takenAt: date.addingTimeInterval(0.001)),
            CreatineDayDocument(date: "2026-11-12", takenAt: date),
            futureVersion,
        ]
        for other in changed {
            var state = RevisionedDocumentState(localDocument: document)
            let pending = try XCTUnwrap(state.pending)
            XCTAssertNotEqual(document, other)
            XCTAssertThrowsError(try state.acknowledge(requestID: pending.requestID,
                record: .init(revision: 1, document: other)))
            XCTAssertEqual(state.pending, pending)
            XCTAssertNil(state.acknowledged)
        }
        XCTAssertNotEqual(CreatineDayDocument(date: document.date), document)
    }

    func testCreatineUndoDuringDeliveryRemainsPendingAfterSerializedAcknowledgment() throws {
        let date = Date(timeIntervalSince1970: 1_794_420_000.123456)
        let document = CreatineDayDocument(date: "2026-11-11", takenAt: date)
        var state = RevisionedDocumentState(localDocument: document)
        let sent = try XCTUnwrap(state.pending)
        state.edit(CreatineDayDocument(date: document.date))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let transmittedDate = try XCTUnwrap(formatter.date(from: formatter.string(from: date)))

        try state.acknowledge(requestID: sent.requestID, record: .init(revision: 1,
            document: CreatineDayDocument(date: document.date, takenAt: transmittedDate)))

        XCTAssertNil(state.document.takenAt)
        XCTAssertNil(state.pending?.document.takenAt)
        XCTAssertEqual(state.pending?.expectedRevision, 1)
        XCTAssertNotEqual(state.pending?.requestID, sent.requestID)
    }

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TemplatesCreatine-\(UUID())/training.json")
    }

    @MainActor func testMultipleSnapshotsApplyWithoutChangingExistingWorkouts() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = WorkoutStore(fileURL: url)
        store.loadExample()
        XCTAssertTrue(store.saveTemplateSnapshot(name: "Первый"))
        let first = try XCTUnwrap(store.savedTemplatesState.document.templates.first)
        let monday = try XCTUnwrap(first.days.first)
        var edited = monday
        edited.title = "Другой план"
        XCTAssertTrue(store.saveDay(edited, expected: monday))
        XCTAssertTrue(store.saveTemplateSnapshot(name: "Второй"))
        XCTAssertTrue(store.ensureWeek(containing: Date()))
        XCTAssertTrue(store.start(day: edited))
        let weeks = store.archive.scheduledWeeks
        let active = store.archive.active
        let history = store.archive.history
        XCTAssertTrue(store.applyTemplateSnapshot(first, expected: store.archive.week))
        XCTAssertEqual(store.archive.week, first.days)
        XCTAssertEqual(store.archive.scheduledWeeks, weeks)
        XCTAssertEqual(store.archive.active, active)
        XCTAssertEqual(store.archive.history, history)
        XCTAssertEqual(WorkoutStore(fileURL: url).savedTemplatesState, store.savedTemplatesState)
        XCTAssertTrue(store.deleteTemplateSnapshot(first))
        XCTAssertEqual(store.savedTemplatesState.document.templates.map(\.name), ["Второй"])
        XCTAssertEqual(store.archive.week, first.days)
        XCTAssertFalse(store.applyTemplateSnapshot(first, expected: store.archive.week))
    }

    @MainActor func testStaleSnapshotUpdateAndInvalidNamePreserveCollection() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = WorkoutStore(fileURL: url)
        XCTAssertTrue(store.saveTemplateSnapshot(name: "Начало"))
        let original = try XCTUnwrap(store.savedTemplatesState.document.templates.first)
        XCTAssertTrue(store.saveTemplateSnapshot(name: "Обновлённый", replacing: original))
        let saved = store.savedTemplatesState
        XCTAssertFalse(store.saveTemplateSnapshot(name: "Устаревший", replacing: original))
        XCTAssertFalse(store.deleteTemplateSnapshot(original))
        XCTAssertFalse(store.saveTemplateSnapshot(name: "  "))
        XCTAssertEqual(store.savedTemplatesState, saved)
    }

    @MainActor func testCreatineIsOneDailyMarkWithUndoRestartAndStablePendingWrite() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = WorkoutStore(fileURL: url)
        let calendar = store.trainingCalendar
        let date = try XCTUnwrap(calendar.date(from: "2026-11-11"))
        let next = try XCTUnwrap(calendar.calendar.date(byAdding: .day, value: 1, to: date))
        let key = calendar.dayKey(for: date)
        XCTAssertTrue(store.setCreatineTaken(on: date, taken: true))
        let pending = try XCTUnwrap(store.creatineState(on: key).pending)
        XCTAssertTrue(store.setCreatineTaken(on: date.addingTimeInterval(60), taken: true))
        XCTAssertEqual(store.creatineState(on: key).pending, pending)
        XCTAssertTrue(store.setCreatineTaken(on: date, taken: false))
        var state = WorkoutStore(fileURL: url).creatineState(on: key)
        XCTAssertNil(state.document.takenAt)
        XCTAssertEqual(state.pending, pending)
        try state.acknowledge(requestID: pending.requestID, record: .init(revision: 1, document: pending.document))
        XCTAssertNotEqual(state.pending?.requestID, pending.requestID)
        XCTAssertNil(state.pending?.document.takenAt)
        XCTAssertTrue(store.saveCreatineState(state, on: key))
        XCTAssertTrue(store.setCreatineTaken(on: next, taken: true))
        XCTAssertEqual(store.archive.creatineDays?.count, 2)
        XCTAssertNil(store.creatineState(on: key).document.takenAt)
    }

    @MainActor func testV6MigrationBacksUpExactBytesAndNewResourcesRemainAtomic() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var archive = TrainingArchive()
        archive.version = 6
        archive.week = TrainingDay.exampleWeek()
        archive.active = WorkoutSession(day: archive.week.first { !$0.exercises.isEmpty }!)
        let bytes = try JSONEncoder().encode(archive)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        let store = WorkoutStore(fileURL: url)
        XCTAssertFalse(store.loadFailed)
        XCTAssertTrue(store.saveTemplateSnapshot(name: "Старый шаблон"))
        XCTAssertEqual(try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("training-v6-backup.json")), bytes)
        XCTAssertEqual(store.archive.active, archive.active)
        XCTAssertEqual(store.archive.version, 7)
        XCTAssertFalse(WorkoutStore(fileURL: url).loadFailed)
    }

    @MainActor func testConflictingCreatinePreservesBothVersionsAndRequiresExplicitChoice() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = WorkoutStore(fileURL: url)
        let date = try XCTUnwrap(store.trainingCalendar.date(from: "2026-11-11"))
        let key = store.trainingCalendar.dayKey(for: date)
        XCTAssertTrue(store.setCreatineTaken(on: date, taken: true))
        var state = store.creatineState(on: key)
        let remote = RevisionedDocumentRecord(revision: Int64(2), document: CreatineDayDocument(date: key))
        try state.receive(remote)
        XCTAssertTrue(store.saveCreatineState(state, on: key))
        let restored = WorkoutStore(fileURL: url).creatineState(on: key)
        XCTAssertEqual(restored.conflict, remote)
        XCTAssertNotNil(restored.document.takenAt)
        let backups = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().appendingPathComponent("Conflicts").path)
        XCTAssertEqual(backups.count, 2)
        try state.resolve(usingServer: true, expected: remote)
        XCTAssertTrue(store.saveCreatineState(state, on: key))
        XCTAssertNil(store.creatineState(on: key).document.takenAt)
    }
}
