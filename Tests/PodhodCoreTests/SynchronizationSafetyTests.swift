import XCTest
@testable import PodhodCore

final class SynchronizationSafetyTests: XCTestCase {
    let calendar = TrainingCalendar(timezone: "Europe/Moscow")
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SyncSafety-\(UUID())/training.json")
    }

    func testImportedTemplateReplacesUntouchedEmptyWeek() throws {
        let monday = try XCTUnwrap(calendar.date(from: "2026-11-02"))
        let empty = TrainingWeek(containing: monday, template: TrainingDay.initialWeek(), calendar: calendar)
        let rebased = try empty.applyingTemplate(TrainingDay.exampleWeek())
        XCTAssertEqual(rebased.weekStart, empty.weekStart)
        XCTAssertEqual(rebased.workouts.count, 3)
        XCTAssertFalse(rebased.day(on: monday, calendar: calendar).exercises.isEmpty)
    }

    func testRefreshingTemplateKeepsOccurrenceIdentity() throws {
        let date = try XCTUnwrap(calendar.date(from: "2026-11-02"))
        let original = TrainingWeek(containing: date, template: TrainingDay.exampleWeek(), calendar: calendar)
        var changed = TrainingDay.exampleWeek()
        changed[0].title = "Новый шаблон"
        let rebased = try original.applyingTemplate(changed)
        XCTAssertEqual(rebased.workouts.first?.id, original.workouts.first?.id)
        XCTAssertEqual(rebased.workouts.first?.title, "Новый шаблон")
    }

    @MainActor func testStaleTemplateEditorCannotOverwritePulledProgram() async throws {
        let store = WorkoutStore(fileURL: location())
        store.loadExample()
        let original = store.archive.week[0]
        var incoming = store.archive.week
        incoming[0].exercises[0].restSeconds = 180
        XCTAssertTrue(store.replaceTemplate(incoming))
        var draft = original
        draft.title = "Мой черновик"
        XCTAssertFalse(store.saveDay(draft, expected: original))
        XCTAssertEqual(store.archive.week, incoming)
        XCTAssertEqual(draft.title, "Мой черновик")
    }

    @MainActor func testStaleDatedEditorCannotRecreateMovedWorkout() async throws {
        let store = WorkoutStore(fileURL: location())
        store.loadExample()
        let calendar = store.trainingCalendar
        let monday = try XCTUnwrap(calendar.date(from: "2026-11-02"))
        let tuesday = try XCTUnwrap(calendar.date(from: "2026-11-03"))
        store.ensureWeek(containing: monday)
        let week = store.scheduledWeek(containing: monday)
        let original = week.day(on: monday, calendar: calendar)
        let id = try XCTUnwrap(week.workouts.first { $0.plannedDate == "2026-11-02" }?.id)
        XCTAssertTrue(store.moveScheduledWorkout(id: id, in: week.weekStart, to: tuesday))
        var draft = original
        draft.title = "Старый понедельник"
        XCTAssertFalse(store.saveScheduledDay(draft, on: monday, expected: original))
        XCTAssertTrue(store.scheduledWeek(containing: monday).day(on: monday, calendar: calendar).exercises.isEmpty)
        XCTAssertEqual(store.scheduledWeek(containing: monday).workouts.first { $0.id == id }?.plannedDate, "2026-11-03")
    }

    func testCompletedSetProtectionIsSymmetric() {
        var local = WorkoutSession(day: TrainingDay.exampleWeek()[0])
        local.exercises[0].sets[0].weight = "60"
        local.exercises[0].sets[0].reps = "10"
        local.exercises[0].sets[0].isCompleted = true
        var remote = local
        remote.exercises[0].sets[1].weight = "60"
        remote.exercises[0].sets[1].reps = "8"
        remote.exercises[0].sets[1].isCompleted = true
        XCTAssertTrue(remote.containsCompletedSets(from: local))
        XCTAssertFalse(local.containsCompletedSets(from: remote))
        remote.exercises[0].isSkipped = true
        XCTAssertTrue(remote.containsCompletedSets(from: local))
        remote.exercises[0].sets[0].isCompleted = false
        XCTAssertFalse(remote.containsCompletedSets(from: local))
        XCTAssertFalse(local.containsCompletedSets(from: remote))
    }

    @MainActor func testBackupFailureLeavesOriginalAndInMemoryStateUnchanged() async throws {
        let url = location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var archive = TrainingArchive()
        archive.version = 1
        let data = try JSONEncoder().encode(archive)
        try data.write(to: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent().appendingPathComponent("training-v1-backup.json"), withIntermediateDirectories: true)
        let store = WorkoutStore(fileURL: url)
        let before = store.archive
        XCTAssertFalse(store.saveDay(TrainingDay(weekday: 1, title: "Не сохранится", exercises: [])))
        XCTAssertEqual(store.archive, before)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    @MainActor func testInvalidRemoteStateCannotEraseCurrentWorkout() async {
        let store = WorkoutStore(fileURL: location())
        store.start(day: TrainingDay.exampleWeek()[0])
        let before = store.archive
        var invalid = store.activeWorkoutState!
        invalid.session.currentExercise = 999
        XCTAssertFalse(store.restoreActiveWorkout(invalid))
        XCTAssertEqual(store.archive, before)
    }

    @MainActor func testOfflineFinishSurvivesReopenAndConflictingServerHistory() async throws {
        let root = location().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = AccountWorkspaces(rootURL: root)
        let directory = try account.prepare(accountID: "owner", legacyAccountID: nil)
        let url = directory.appending(path: "training.json")
        try account.commit(accountID: "owner")
        let workout = WorkoutStore(fileURL: url)
        let startedAt = try XCTUnwrap(calendar.date(from: "2026-11-24"))
        XCTAssertTrue(workout.start(day: TrainingDay.exampleWeek()[0], date: startedAt))
        let exercise = try XCTUnwrap(workout.archive.active?.exercises.first)
        let set = try XCTUnwrap(exercise.sets.first)
        workout.updateSet(exerciseID: exercise.id, setID: set.id, reps: "8", weight: "65", date: startedAt)
        XCTAssertTrue(workout.toggleSet(exerciseID: exercise.id, setID: set.id, date: startedAt))
        XCTAssertTrue(workout.finish(allowPartial: true, date: startedAt.addingTimeInterval(120)))
        let finished = try XCTUnwrap(workout.archive.history.first)

        let reopened = AccountWorkspaces(rootURL: root)
        XCTAssertEqual(reopened.accountID, "owner")
        let local = WorkoutStore(fileURL: reopened.currentDirectory.appending(path: "training.json"))
        XCTAssertEqual(local.archive.history, [finished])
        XCTAssertNil(local.archive.active)

        var conflicting = finished
        conflicting.exercises[0].sets[0].weight = "40"
        var unrelated = conflicting
        unrelated.id = UUID()
        XCTAssertTrue(local.mergeHistory([conflicting, unrelated]))
        XCTAssertEqual(local.archive.history.first { $0.id == finished.id }, finished)
        XCTAssertEqual(WorkoutStore(fileURL: url).archive.history.count, 2)

        var staleChoice = finished
        staleChoice.title = "Уже не совпадает"
        XCTAssertFalse(local.acceptRecoveredHistory(conflicting, replacing: staleChoice))
        XCTAssertEqual(local.archive.history.first { $0.id == finished.id }, finished)
        XCTAssertTrue(local.acceptRecoveredHistory(conflicting, replacing: finished))
        let recovered = WorkoutStore(fileURL: url)
        XCTAssertEqual(recovered.archive.history.first { $0.id == finished.id }, conflicting)
        XCTAssertTrue(recovered.archive.history.contains(unrelated))
    }
}
