import XCTest
@testable import PodhodCore

final class WorkoutEditingTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutEditing-\(UUID())/training.json")
    }

    private func plan(sets: Int = 2) -> TrainingDay {
        TrainingDay(weekday: 1, title: "Рабочая тренировка", exercises: [
            PlannedExercise(exercise: Exercise.catalog[0], setCount: sets, restSeconds: 60)
        ])
    }

    @MainActor func testAddAndRemoveSetPersistWithoutChangingProgramOrWeek() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        XCTAssertTrue(store.saveDay(plan()))
        XCTAssertTrue(store.ensureWeek(containing: Date()))
        let template = store.archive.week
        let weeks = store.archive.scheduledWeeks
        XCTAssertTrue(store.start(day: plan()))
        let session = try XCTUnwrap(store.archive.active)
        let exercise = session.exercises[0]
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[0].id, reps: "10", weight: "60")
        XCTAssertTrue(store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[0].id))
        let completed = try XCTUnwrap(store.archive.active?.exercises[0].sets[0])
        XCTAssertTrue(store.addActiveSet(sessionID: session.id, exerciseID: exercise.id))
        let added = try XCTUnwrap(store.archive.active?.exercises[0].sets.last)
        XCTAssertFalse(exercise.sets.contains { $0.id == added.id })
        XCTAssertEqual(added.weight, "")
        XCTAssertEqual(added.reps, "")
        XCTAssertNil(added.repsInReserve)
        XCTAssertFalse(added.isCompleted)
        XCTAssertTrue(store.removeActiveSet(sessionID: session.id, exerciseID: exercise.id, setID: exercise.sets[1].id))
        let restored = WorkoutStore(fileURL: url)
        XCTAssertEqual(restored.archive.active?.exercises[0].sets, [completed, added])
        XCTAssertEqual(restored.archive.week, template)
        XCTAssertEqual(restored.archive.scheduledWeeks, weeks)
        XCTAssertTrue(restored.archive.history.isEmpty)
        let wire = try JSONEncoder().encode(try XCTUnwrap(store.activeWorkoutState))
        XCTAssertEqual(try JSONDecoder().decode(ActiveWorkoutState.self, from: wire), store.activeWorkoutState)
    }

    @MainActor func testEditingProtectsCompletedLastSkippedAndForeignSessionSets() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: plan())
        let session = try XCTUnwrap(store.archive.active)
        let exercise = session.exercises[0]
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[0].id, reps: "8", weight: "0")
        XCTAssertTrue(store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[0].id))
        let before = store.archive
        XCTAssertFalse(store.removeActiveSet(sessionID: session.id, exerciseID: exercise.id, setID: exercise.sets[0].id))
        XCTAssertFalse(store.removeActiveSet(sessionID: UUID(), exerciseID: exercise.id, setID: exercise.sets[1].id))
        XCTAssertFalse(store.addActiveSet(sessionID: UUID(), exerciseID: exercise.id))
        XCTAssertEqual(store.archive, before)
        XCTAssertTrue(store.setExerciseSkipped(sessionID: session.id, exerciseID: exercise.id, isSkipped: true))
        let skipped = store.archive
        XCTAssertFalse(store.addActiveSet(sessionID: session.id, exerciseID: exercise.id))
        XCTAssertFalse(store.removeActiveSet(sessionID: session.id, exerciseID: exercise.id, setID: exercise.sets[1].id))
        XCTAssertEqual(store.archive, skipped)
        XCTAssertTrue(store.setExerciseSkipped(sessionID: session.id, exerciseID: exercise.id, isSkipped: false))
        XCTAssertTrue(store.removeActiveSet(sessionID: session.id, exerciseID: exercise.id, setID: exercise.sets[1].id))
        XCTAssertTrue(store.finish())
        let finished = store.archive
        XCTAssertFalse(store.addActiveSet(sessionID: session.id, exerciseID: exercise.id))
        XCTAssertFalse(store.removeActiveSet(sessionID: session.id, exerciseID: exercise.id, setID: exercise.sets[0].id))
        XCTAssertEqual(store.archive, finished)

        store.start(day: plan(sets: 1))
        let single = try XCTUnwrap(store.archive.active)
        XCTAssertFalse(store.removeActiveSet(sessionID: single.id, exerciseID: single.exercises[0].id, setID: single.exercises[0].sets[0].id))
    }

    @MainActor func testAddSetEnforcesServerLimitWithoutWriting() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: plan(sets: 12))
        let session = try XCTUnwrap(store.archive.active)
        let before = store.archive
        XCTAssertFalse(store.addActiveSet(sessionID: session.id, exerciseID: session.exercises[0].id))
        XCTAssertEqual(store.archive, before)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor func testReuseFillsOnlyEmptyFieldsAndNeverCopiesEffortOrCompletion() async throws {
        let store = WorkoutStore(fileURL: location())
        var history = WorkoutSession(day: plan(), date: Date(timeIntervalSince1970: 1000))
        history.finishedAt = Date(timeIntervalSince1970: 1100)
        history.exercises[0].sets[0] = LoggedSet(reps: "10", weight: "62,5", isCompleted: true, repsInReserve: .failure)
        history.exercises[0].sets[1] = LoggedSet(reps: "999", weight: "999")
        XCTAssertTrue(store.mergeHistory([history]))
        store.start(day: plan())
        let session = try XCTUnwrap(store.archive.active)
        let exercise = session.exercises[0]
        let setID = exercise.sets[0].id
        store.updateSet(exerciseID: exercise.id, setID: setID, weight: "70")
        store.setRepetitionsInReserve(exerciseID: exercise.id, setID: setID, reserve: .two)
        XCTAssertTrue(store.reusePreviousSet(sessionID: session.id, exerciseID: exercise.id, setID: setID))
        let reused = try XCTUnwrap(store.archive.active?.exercises[0].sets[0])
        XCTAssertEqual(reused.weight, "70")
        XCTAssertEqual(reused.reps, "10")
        XCTAssertEqual(reused.repsInReserve, .two)
        XCTAssertFalse(reused.isCompleted)
        XCTAssertEqual(store.archive.active?.volume, 0)
        let before = store.archive
        XCTAssertFalse(store.reusePreviousSet(sessionID: session.id, exerciseID: exercise.id, setID: setID))
        XCTAssertFalse(store.reusePreviousSet(sessionID: session.id, exerciseID: exercise.id, setID: exercise.sets[1].id))
        XCTAssertFalse(store.reusePreviousSet(sessionID: UUID(), exerciseID: exercise.id, setID: setID))
        XCTAssertEqual(store.archive, before)
        XCTAssertEqual(store.archive.history, [history])
    }

    @MainActor func testPreviousSetUsesExactAliasesAndRejectsUnperformedDrafts() async throws {
        let store = WorkoutStore(fileURL: location())
        let alias = try XCTUnwrap(ExerciseCatalog.bundled.exerciseIDAliases.first)
        let canonical = try XCTUnwrap(ExerciseCatalog.bundled.entry(for: alias.exerciseID)?.exercise)
        var legacy = canonical
        legacy.id = alias.id
        var history = WorkoutSession(day: TrainingDay(weekday: 1, title: "История", exercises: [PlannedExercise(exercise: legacy)]))
        history.finishedAt = history.startedAt.addingTimeInterval(100)
        history.exercises[0].sets[0] = LoggedSet(reps: "8", weight: "60", isCompleted: true)
        history.exercises[0].sets[1] = LoggedSet(reps: "10", weight: "900")
        XCTAssertTrue(store.mergeHistory([history]))
        XCTAssertEqual(store.previousSet(for: canonical, index: 0)?.weight, "60")
        XCTAssertNil(store.previousSet(for: canonical, index: 1))
        XCTAssertNil(store.previousSet(for: canonical, index: -1))
        var different = canonical
        different.id = UUID()
        XCTAssertNil(store.previousSet(for: different, index: 0))
    }

    @MainActor func testAddingToResolvedExerciseResumesTimingAtTheAction() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: plan(sets: 1), date: Date(timeIntervalSince1970: 1000))
        let session = try XCTUnwrap(store.archive.active)
        let exercise = session.exercises[0]
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[0].id, reps: "10", weight: "60", date: Date(timeIntervalSince1970: 1005))
        store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[0].id, date: Date(timeIntervalSince1970: 1010))
        XCTAssertTrue(store.addActiveSet(sessionID: session.id, exerciseID: exercise.id, date: Date(timeIntervalSince1970: 1020)))
        let added = try XCTUnwrap(store.archive.active?.exercises[0].sets.last)
        XCTAssertTrue(store.removeActiveSet(sessionID: session.id, exerciseID: exercise.id, setID: added.id, date: Date(timeIntervalSince1970: 1030)))
        let active = try XCTUnwrap(store.archive.active)
        let totals = try XCTUnwrap(active.timingTotals(at: Date(timeIntervalSince1970: 1040)))
        XCTAssertEqual(totals.exerciseSeconds, 20)
        XCTAssertEqual(totals.otherSeconds, 20)
        XCTAssertTrue(try XCTUnwrap(active.timing).isValid(for: active))
    }

    @MainActor func testAdjustRestPreservesPastDeadlinesAndPlan() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        store.start(day: plan(), date: Date(timeIntervalSince1970: 1000))
        let session = try XCTUnwrap(store.archive.active)
        let exercise = session.exercises[0]
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[0].id, reps: "10", weight: "60", date: Date(timeIntervalSince1970: 1005))
        store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[0].id, date: Date(timeIntervalSince1970: 1010))
        let oldDeadline = try XCTUnwrap(store.archive.restUntil)
        XCTAssertTrue(store.adjustRest(sessionID: session.id, expectedDeadline: oldDeadline, seconds: 30, date: Date(timeIntervalSince1970: 1020)))
        XCTAssertEqual(store.archive.restUntil, Date(timeIntervalSince1970: 1100))
        let firstRest = try XCTUnwrap(store.archive.active?.timing?.intervals.first { $0.kind == .rest })
        XCTAssertEqual(firstRest.restDeadline, oldDeadline)
        XCTAssertEqual(firstRest.endedAt, Date(timeIntervalSince1970: 1020))
        XCTAssertEqual(store.archive.active?.exercises[0].restSeconds, 60)
        let before = store.archive
        XCTAssertFalse(store.adjustRest(sessionID: session.id, expectedDeadline: oldDeadline, seconds: 30))
        XCTAssertFalse(store.stopRest(sessionID: session.id, expectedDeadline: oldDeadline))
        XCTAssertFalse(store.adjustRest(sessionID: UUID(), expectedDeadline: Date(timeIntervalSince1970: 1100), seconds: 30))
        XCTAssertEqual(store.archive, before)
        XCTAssertTrue(store.adjustRest(sessionID: session.id, expectedDeadline: Date(timeIntervalSince1970: 1100), seconds: -30, date: Date(timeIntervalSince1970: 1030)))
        let restored = WorkoutStore(fileURL: url)
        XCTAssertEqual(restored.archive.restUntil, oldDeadline)
        let active = try XCTUnwrap(restored.archive.active)
        XCTAssertTrue(try XCTUnwrap(active.timing).isValid(for: active))
        XCTAssertEqual(active.timingTotals(at: Date(timeIntervalSince1970: 1040))?.restSeconds, 30)
    }

    @MainActor func testExpiredRestStartsNewIntervalWithoutBackfillingTheGap() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: plan(), date: Date(timeIntervalSince1970: 1000))
        let session = try XCTUnwrap(store.archive.active)
        let exercise = session.exercises[0]
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[0].id, reps: "8", weight: "50", date: Date(timeIntervalSince1970: 1005))
        store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[0].id, date: Date(timeIntervalSince1970: 1010))
        let deadline = try XCTUnwrap(store.archive.restUntil)
        XCTAssertTrue(store.adjustRest(sessionID: session.id, expectedDeadline: deadline, seconds: 30, date: Date(timeIntervalSince1970: 1100)))
        XCTAssertEqual(store.archive.restUntil, Date(timeIntervalSince1970: 1130))
        let active = try XCTUnwrap(store.archive.active)
        let totals = try XCTUnwrap(active.timingTotals(at: Date(timeIntervalSince1970: 1110)))
        XCTAssertEqual(totals.restSeconds, 70)
        XCTAssertEqual(totals.exerciseSeconds, 40)
        XCTAssertTrue(try XCTUnwrap(active.timing).isValid(for: active))
        XCTAssertTrue(store.adjustRest(sessionID: session.id, expectedDeadline: Date(timeIntervalSince1970: 1130), seconds: -30, date: Date(timeIntervalSince1970: 1100)))
        XCTAssertNil(store.archive.restUntil)
        XCTAssertNil(store.archive.restKind)
        XCTAssertNil(store.archive.restExerciseID)
    }

    @MainActor func testRestLimitAndFailedWriteDoNotApplyChanges() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        store.start(day: plan(), date: Date(timeIntervalSince1970: 1000))
        let session = try XCTUnwrap(store.archive.active)
        let exercise = session.exercises[0]
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[0].id, reps: "8", weight: "50", date: Date(timeIntervalSince1970: 1005))
        store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[0].id, date: Date(timeIntervalSince1970: 1010))
        let deadline = try XCTUnwrap(store.archive.restUntil)
        let before = store.archive
        XCTAssertFalse(store.adjustRest(sessionID: session.id, expectedDeadline: deadline, seconds: 600, date: Date(timeIntervalSince1970: 1020)))
        XCTAssertEqual(store.archive, before)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertFalse(store.adjustRest(sessionID: session.id, expectedDeadline: deadline, seconds: 30, date: Date(timeIntervalSince1970: 1020)))
        XCTAssertFalse(store.addActiveSet(sessionID: session.id, exerciseID: exercise.id, date: Date(timeIntervalSince1970: 1020)))
        XCTAssertEqual(store.archive, before)
    }
}
