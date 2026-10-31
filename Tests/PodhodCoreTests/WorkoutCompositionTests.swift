import XCTest
@testable import PodhodCore

final class WorkoutCompositionTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Composition-\(UUID())/training.json")
    }

    private func plan() -> TrainingDay {
        var exercise = Exercise.catalog[0]
        exercise.cue = "Личная заметка, сохранить"
        return TrainingDay(weekday: 1, title: "Тест", exercises: [
            PlannedExercise(exercise: exercise, setCount: 3, restSeconds: 90),
            PlannedExercise(exercise: Exercise.catalog[2], setCount: 2)
        ])
    }

    @MainActor func testReplacementPreservesCompletedDraftsNotesAndStartsFreshRemainingSets() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        let start = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(store.start(day: plan(), date: start))
        let session = try XCTUnwrap(store.archive.active)
        let exercise = session.exercises[0]
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[0].id, reps: "8", weight: "60", date: start.addingTimeInterval(10))
        XCTAssertTrue(store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[0].id, date: start.addingTimeInterval(20)))
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[1].id, reps: "6", weight: "62,5", date: start.addingTimeInterval(25))
        XCTAssertTrue(store.setRepetitionsInReserve(exerciseID: exercise.id, setID: exercise.sets[1].id, reserve: .two))
        let original = try XCTUnwrap(store.archive.active?.exercises[0])
        let deadline = store.archive.restUntil
        let before = store.archive
        let replacement = Exercise.catalog[1]
        XCTAssertTrue(store.replaceActiveExercise(sessionID: session.id, original: original, with: replacement, date: start.addingTimeInterval(30)))
        let active = try XCTUnwrap(WorkoutStore(fileURL: url).archive.active)
        var preserved = original
        preserved.isSkipped = true
        XCTAssertEqual(active.id, session.id)
        XCTAssertEqual(active.exercises[0], preserved)
        XCTAssertEqual(active.exercises[1].exercise, replacement)
        XCTAssertEqual(active.exercises[1].sets.count, 2)
        XCTAssertTrue(active.exercises[1].sets.allSatisfy { !$0.isCompleted && $0.reps.isEmpty && $0.weight.isEmpty && $0.repsInReserve == nil })
        XCTAssertTrue(Set(active.exercises[1].sets.map(\.id)).isDisjoint(with: original.sets.map(\.id)))
        XCTAssertNotEqual(active.exercises[1].id, original.id)
        XCTAssertEqual(active.currentExercise, 1)
        XCTAssertEqual(store.archive.restUntil, deadline)
        XCTAssertEqual(store.archive.restExerciseID, original.id)
        XCTAssertEqual(store.archive.week, before.week)
        XCTAssertEqual(store.archive.scheduledWeeks, before.scheduledWeeks)
        XCTAssertEqual(store.archive.history, before.history)
        XCTAssertTrue(active.containsCompletedSets(from: try XCTUnwrap(before.active)))
        XCTAssertTrue(active.timing?.isValid(for: active) == true)
        XCTAssertTrue(store.setExerciseSkipped(sessionID: active.id, exerciseID: original.id, isSkipped: false))
        XCTAssertEqual(store.archive.active?.exercises[0].sets, original.sets)
    }

    @MainActor func testReplacementPreservesLegacyRestOwnerAndExerciseTimeBoundaries() async throws {
        let store = WorkoutStore(fileURL: location())
        let start = Date(timeIntervalSince1970: 30_000)
        store.start(day: plan(), date: start)
        var state = try XCTUnwrap(store.activeWorkoutState)
        let original = state.session.exercises[0]
        state.restUntil = start.addingTimeInterval(100)
        state.restKind = .betweenSets
        state.restExerciseID = nil
        XCTAssertTrue(store.restoreActiveWorkout(state, date: start.addingTimeInterval(10)))
        let before = store.archive.active?.timing
        XCTAssertTrue(store.replaceActiveExercise(sessionID: state.session.id, original: original,
            with: Exercise.catalog[1], date: start.addingTimeInterval(20)))
        XCTAssertEqual(store.archive.restUntil, state.restUntil)
        XCTAssertEqual(store.archive.restExerciseID, original.id)
        XCTAssertEqual(store.archive.active?.timing, before)
        XCTAssertTrue(store.stopRest(date: start.addingTimeInterval(30)))
        let newID = try XCTUnwrap(store.archive.active?.exercises[1].id)
        XCTAssertEqual(store.archive.active?.timing?.intervals.last?.exerciseID, newID)
        let totals = try XCTUnwrap(store.archive.active?.timingTotals(at: start.addingTimeInterval(40)))
        XCTAssertEqual(totals.exercises[original.id]?.exerciseSeconds, 10)
        XCTAssertEqual(totals.exercises[original.id]?.restSeconds, 20)
        XCTAssertEqual(totals.exercises[newID]?.exerciseSeconds, 10)
    }

    @MainActor func testReplacementRejectsStaleSnapshotResolvedAndForeignSession() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: plan())
        let session = try XCTUnwrap(store.archive.active)
        let original = session.exercises[0]
        store.updateSet(exerciseID: original.id, setID: original.sets[0].id, reps: "12")
        let changed = store.archive
        XCTAssertFalse(store.replaceActiveExercise(sessionID: session.id, original: original, with: Exercise.catalog[1]))
        XCTAssertFalse(store.replaceActiveExercise(sessionID: UUID(), original: original, with: Exercise.catalog[1]))
        XCTAssertEqual(store.archive, changed)
        XCTAssertTrue(store.setExerciseSkipped(sessionID: session.id, exerciseID: original.id, isSkipped: true))
        let skipped = try XCTUnwrap(store.archive.active?.exercises[0])
        XCTAssertFalse(store.replaceActiveExercise(sessionID: session.id, original: skipped, with: Exercise.catalog[1]))
        XCTAssertEqual(store.archive.active?.exercises.count, 2)
        XCTAssertTrue(store.setExerciseSkipped(sessionID: session.id, exerciseID: original.id, isSkipped: false))
        for set in original.sets {
            store.updateSet(exerciseID: original.id, setID: set.id, reps: "10", weight: "60")
            XCTAssertTrue(store.toggleSet(exerciseID: original.id, setID: set.id))
        }
        let completed = try XCTUnwrap(store.archive.active?.exercises[0])
        XCTAssertTrue(completed.isCompleted)
        let beforeCompletedReplacement = store.archive
        XCTAssertFalse(store.replaceActiveExercise(sessionID: session.id, original: completed, with: Exercise.catalog[1]))
        XCTAssertEqual(store.archive, beforeCompletedReplacement)
    }

    @MainActor func testAddingAndReorderingKeepsCurrentIdentityTimingRestAndSnapshots() async throws {
        let store = WorkoutStore(fileURL: location())
        let date = Date(timeIntervalSince1970: 20_000)
        store.start(day: plan(), date: date)
        let session = try XCTUnwrap(store.archive.active)
        let originalWeek = store.archive.week
        XCTAssertTrue(store.addActiveExercise(sessionID: session.id,
            plan: PlannedExercise(exercise: Exercise.catalog[4], setCount: 4, targetReps: "12–15", restSeconds: 60), date: date.addingTimeInterval(10)))
        let added = try XCTUnwrap(store.archive.active?.exercises.last)
        XCTAssertEqual(added.sets.count, 4)
        XCTAssertTrue(added.sets.allSatisfy { !$0.isCompleted && $0.reps.isEmpty && $0.repsInReserve == nil })
        let before = try XCTUnwrap(store.archive.active)
        let expected = before.exercises.map(\.id)
        XCTAssertTrue(store.reorderActiveExercises(sessionID: before.id, expectedIDs: expected, orderedIDs: expected.reversed(), date: date.addingTimeInterval(20)))
        let after = try XCTUnwrap(store.archive.active)
        XCTAssertEqual(after.exercises[after.currentExercise].id, session.exercises[0].id)
        XCTAssertEqual(after.exercises, before.exercises.reversed())
        XCTAssertEqual(after.timing, before.timing)
        XCTAssertEqual(store.archive.week, originalWeek)
        XCTAssertFalse(store.reorderActiveExercises(sessionID: before.id, expectedIDs: expected, orderedIDs: expected))
        XCTAssertFalse(store.reorderActiveExercises(sessionID: before.id, expectedIDs: after.exercises.map(\.id), orderedIDs: [added.id]))
        XCTAssertEqual(store.archive.active, after)
    }

    @MainActor func testCompositionLimitsAndFailedWritesAreAtomic() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        store.start(day: plan())
        let session = try XCTUnwrap(store.archive.active)
        XCTAssertFalse(store.addActiveExercise(sessionID: session.id, plan: PlannedExercise(exercise: Exercise.catalog[1], setCount: 13)))
        for _ in 2..<50 {
            XCTAssertTrue(store.addActiveExercise(sessionID: session.id, plan: PlannedExercise(exercise: Exercise.catalog[1], setCount: 1)))
        }
        let before = store.archive
        XCTAssertFalse(store.addActiveExercise(sessionID: session.id, plan: PlannedExercise(exercise: Exercise.catalog[1])))
        XCTAssertFalse(store.replaceActiveExercise(sessionID: session.id, original: session.exercises[0], with: Exercise.catalog[1]))
        XCTAssertEqual(store.archive, before)
        let other = WorkoutStore(fileURL: location())
        other.start(day: plan())
        let original = try XCTUnwrap(other.archive.active)
        let archive = other.archive
        try FileManager.default.removeItem(at: other.fileURL)
        try FileManager.default.createDirectory(at: other.fileURL, withIntermediateDirectories: true)
        XCTAssertFalse(other.replaceActiveExercise(sessionID: original.id, original: original.exercises[0], with: Exercise.catalog[1]))
        XCTAssertFalse(other.addActiveExercise(sessionID: original.id, plan: PlannedExercise(exercise: Exercise.catalog[1])))
        XCTAssertFalse(other.reorderActiveExercises(sessionID: original.id, expectedIDs: original.exercises.map(\.id), orderedIDs: original.exercises.reversed().map(\.id)))
        XCTAssertEqual(other.archive, archive)
    }

    func testReplacementCandidatesUseExactAliasesPrimaryMusclesAndEquipmentFilters() throws {
        let catalog = ExerciseCatalog.bundled
        let alias = try XCTUnwrap(catalog.exerciseIDAliases.first)
        let canonical = try XCTUnwrap(catalog.entry(for: alias.exerciseID))
        var old = canonical.exercise
        old.id = alias.id
        let candidates = catalog.replacements(for: old)
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertEqual(candidates, catalog.replacements(for: canonical.exercise))
        XCTAssertTrue(candidates.allSatisfy { $0.id != canonical.id && !Set($0.primaryMuscles).isDisjoint(with: canonical.primaryMuscles) })
        for equipment in catalog.equipment {
            XCTAssertTrue(catalog.replacements(for: old, equipmentID: equipment.id).allSatisfy { $0.equipment.contains(equipment.id) })
        }
        XCTAssertTrue(catalog.replacements(for: old, query: "несуществующееупражнение").isEmpty)
        old.id = UUID()
        XCTAssertTrue(catalog.replacements(for: old).isEmpty)
    }
}
