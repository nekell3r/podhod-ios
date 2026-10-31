import XCTest
@testable import PodhodCore

final class WorkoutStoreTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PodhodTests-\(UUID())/training.json")
    }

    private func day(sets: Int = 2) -> TrainingDay {
        TrainingDay(weekday: 1, title: "Тестовая тренировка", exercises: [
            PlannedExercise(exercise: Exercise.catalog[0], setCount: sets, targetReps: "8–12", restSeconds: 90)
        ])
    }

    @MainActor func testWeekdaysUseMondayAsFirstDay() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26))!
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        XCTAssertEqual(TrainingDay.weekday(for: monday, calendar: calendar), 1)
        XCTAssertEqual(TrainingDay.weekday(for: sunday, calendar: calendar), 7)
    }

    @MainActor func testFreshStoreHasSevenEmptyDaysAndNoFabricatedHistory() async {
        let store = WorkoutStore(fileURL: location())
        XCTAssertEqual(store.archive.week.map(\.weekday), Array(1...7))
        XCTAssertTrue(store.archive.history.isEmpty)
        XCTAssertTrue(store.archive.week.allSatisfy { $0.exercises.isEmpty })
    }

    @MainActor func testDayEditsPersistAndActiveSessionKeepsSnapshot() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        var plan = day()
        XCTAssertTrue(store.saveDay(plan))
        XCTAssertTrue(store.start(day: plan))
        plan.exercises[0].setCount = 4
        plan.exercises[0].exercise.name = "Изменённое название"
        XCTAssertTrue(store.saveDay(plan))
        let restored = WorkoutStore(fileURL: url)
        XCTAssertEqual(restored.archive.week[0].exercises[0].setCount, 4)
        XCTAssertEqual(restored.archive.active?.exercises[0].sets.count, 2)
        XCTAssertEqual(restored.archive.active?.exercises[0].exercise.name, "Жим штанги лёжа")
    }

    @MainActor func testEmptyDayCannotStart() async {
        let store = WorkoutStore(fileURL: location())
        XCTAssertFalse(store.start(day: TrainingDay.initialWeek()[0]))
        XCTAssertNil(store.archive.active)
    }

    @MainActor func testRestartRestoresDraftCompletedSetsAndRestDeadline() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        let date = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(store.start(day: day(), date: date))
        let exercise = try XCTUnwrap(store.archive.active?.exercises.first)
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[0].id, reps: "10", weight: "62,5")
        XCTAssertTrue(store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[0].id, date: date))
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[1].id, reps: "8", weight: "60")
        let restored = WorkoutStore(fileURL: url)
        XCTAssertEqual(restored.archive.active?.completedSets, 1)
        XCTAssertEqual(restored.archive.active?.exercises[0].sets[1].reps, "8")
        XCTAssertEqual(restored.archive.restUntil, date.addingTimeInterval(90))
        XCTAssertEqual(restored.archive.active?.volume, 625)
    }

    @MainActor func testInvalidNumbersCannotBeCompleted() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: day())
        let exercise = try XCTUnwrap(store.archive.active?.exercises.first)
        for values in [("0", "50"), ("-1", "50"), ("10", "-2"), ("10", "nan"), ("10", "inf"), ("1.5", "50"), ("10000", "50"), ("10", "2001"), ("", "50"), ("10", "")] {
            store.updateSet(exerciseID: exercise.id, setID: exercise.sets[0].id, reps: values.0, weight: values.1)
            XCTAssertFalse(store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[0].id), "\(values)")
        }
        XCTAssertEqual(store.archive.active?.completedSets, 0)
    }

    @MainActor func testBodyweightAndUndoCompletion() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: day())
        let exercise = try XCTUnwrap(store.archive.active?.exercises.first)
        let id = exercise.sets[0].id
        store.updateSet(exerciseID: exercise.id, setID: id, reps: "12", weight: "0")
        XCTAssertTrue(store.toggleSet(exerciseID: exercise.id, setID: id))
        store.updateSet(exerciseID: exercise.id, setID: id, reps: "99")
        XCTAssertEqual(store.archive.active?.exercises[0].sets[0].reps, "12")
        XCTAssertTrue(store.toggleSet(exerciseID: exercise.id, setID: id))
        store.updateSet(exerciseID: exercise.id, setID: id, reps: "15")
        XCTAssertEqual(store.archive.active?.exercises[0].sets[0].reps, "15")
        XCTAssertNil(store.archive.restUntil)
    }

    @MainActor func testPartialFinishRequiresExplicitChoiceAndOnlyCountsCompletedSets() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        store.start(day: day())
        let exercise = try XCTUnwrap(store.archive.active?.exercises.first)
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[0].id, reps: "10", weight: "50")
        store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[0].id)
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[1].id, reps: "20", weight: "100")
        XCTAssertFalse(store.finish())
        XCTAssertNotNil(store.archive.active)
        XCTAssertTrue(store.finish(allowPartial: true))
        XCTAssertNil(store.archive.active)
        XCTAssertEqual(store.archive.history.count, 1)
        XCTAssertEqual(store.archive.history[0].volume, 500)
        XCTAssertEqual(store.progress(for: exercise.exercise).first?.weight, 50)
        XCTAssertEqual(WorkoutStore(fileURL: url).archive.history.count, 1)
        XCTAssertFalse(store.finish(allowPartial: true))
        XCTAssertEqual(store.archive.history.count, 1)
    }

    @MainActor func testFinishAllSetsAndPreviousExercise() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: day(sets: 1))
        let exercise = try XCTUnwrap(store.archive.active?.exercises.first)
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[0].id, reps: "8", weight: "80")
        store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[0].id)
        XCTAssertTrue(store.finish())
        XCTAssertEqual(store.previousExercise(exercise.exercise)?.sets[0].repValue, 8)
        XCTAssertNotNil(store.archive.history[0].finishedAt)
    }

    @MainActor func testStartingWhileActiveResumesRatherThanReplaces() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: day())
        let originalID = try XCTUnwrap(store.archive.active?.id)
        store.start(day: TrainingDay.exampleWeek()[2])
        XCTAssertEqual(store.archive.active?.id, originalID)
    }

    @MainActor func testNoEmptySessionInHistoryAndDiscardClearsRest() async {
        let store = WorkoutStore(fileURL: location())
        store.start(day: day())
        XCTAssertFalse(store.finish(allowPartial: true))
        XCTAssertTrue(store.discardActive())
        XCTAssertNil(store.archive.active)
        XCTAssertNil(store.archive.restUntil)
        XCTAssertTrue(store.archive.history.isEmpty)
    }

    @MainActor func testDamagedSaveIsNeverOverwritten() async throws {
        let url = location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("damaged archive".utf8)
        try original.write(to: url)
        let store = WorkoutStore(fileURL: url)
        XCTAssertTrue(store.loadFailed)
        XCTAssertFalse(store.saveDay(day()))
        XCTAssertFalse(store.start(day: day()))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor func testDiskFailureDoesNotApplyUnsavedState() async {
        let store = WorkoutStore(fileURL: URL(fileURLWithPath: "/dev/null/training.json"))
        let original = store.archive
        XCTAssertFalse(store.start(day: day()))
        XCTAssertEqual(store.archive, original)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor func testProgramRejectsInvalidSetCount() async {
        let store = WorkoutStore(fileURL: location())
        XCTAssertFalse(store.saveDay(day(sets: 0)))
        XCTAssertFalse(store.saveDay(day(sets: 13)))
    }

    @MainActor func testExampleDoesNotReplaceUserProgram() async {
        let store = WorkoutStore(fileURL: location())
        store.saveDay(day())
        let original = store.archive.week
        store.loadExample()
        XCTAssertEqual(store.archive.week, original)
    }
    @MainActor func testCustomExerciseCanBeReusedWithSameIdentity() async {
        let store = WorkoutStore(fileURL: location())
        let custom = Exercise(name: "Моё упражнение", muscle: "Спина", illustration: "row", cue: "")
        let plan = TrainingDay(weekday: 2, title: "Спина", exercises: [PlannedExercise(exercise: custom)])
        XCTAssertTrue(store.saveDay(plan))
        XCTAssertEqual(store.exerciseLibrary.filter { $0.id == custom.id }.count, 1)
        XCTAssertEqual(store.exerciseLibrary.count, Exercise.catalog.count + 1)
    }

    @MainActor func testFutureArchiveIsProtectedFromOverwrite() async throws {
        let url = location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var archive = TrainingArchive()
        archive.version = 6
        let original = try JSONEncoder().encode(archive)
        try original.write(to: url)
        let store = WorkoutStore(fileURL: url)
        XCTAssertTrue(store.loadFailed)
        XCTAssertFalse(store.saveDay(day()))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor func testExerciseNavigationPersistsAndRejectsOutOfRange() async {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        store.start(day: TrainingDay.exampleWeek()[0])
        store.selectExercise(2)
        store.selectExercise(99)
        XCTAssertEqual(WorkoutStore(fileURL: url).archive.active?.currentExercise, 2)
    }

    private func twoExerciseDay(sets: Int = 2) -> TrainingDay {
        TrainingDay(weekday: 1, title: "Два упражнения", exercises: [
            PlannedExercise(exercise: Exercise.catalog[0], setCount: sets, restSeconds: 60, restAfterExerciseSeconds: 120),
            PlannedExercise(exercise: Exercise.catalog[1], setCount: sets, restSeconds: 45, restAfterExerciseSeconds: 150)
        ])
    }

    @MainActor func testVersionOneArchiveMigratesWithoutLosingHistoryOrDrafts() async throws {
        let url = location()
        var archive = TrainingArchive()
        archive.version = 1
        archive.week[0] = day()
        var session = WorkoutSession(day: day())
        session.exercises[0].sets[0].reps = "10"
        session.exercises[0].sets[0].weight = "50"
        session.exercises[0].sets[0].isCompleted = true
        session.exercises[0].sets[1].reps = "8"
        session.exercises[0].sets[1].weight = "45"
        archive.active = session
        var past = session
        past.id = UUID()
        past.finishedAt = Date()
        archive.history = [past]
        archive.restUntil = Date(timeIntervalSince1970: 1_000)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        var week = try XCTUnwrap(legacy["week"] as? [[String: Any]])
        var plans = try XCTUnwrap(week[0]["exercises"] as? [[String: Any]])
        plans[0].removeValue(forKey: "restAfterExerciseSeconds")
        week[0]["exercises"] = plans
        legacy["week"] = week
        var active = try XCTUnwrap(legacy["active"] as? [String: Any])
        var snapshots = try XCTUnwrap(active["exercises"] as? [[String: Any]])
        snapshots[0].removeValue(forKey: "restAfterExerciseSeconds")
        snapshots[0].removeValue(forKey: "isSkipped")
        active["exercises"] = snapshots
        legacy["active"] = active
        var history = try XCTUnwrap(legacy["history"] as? [[String: Any]])
        history[0]["exercises"] = snapshots
        legacy["history"] = history
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)

        let store = WorkoutStore(fileURL: url)
        XCTAssertFalse(store.loadFailed)
        XCTAssertEqual(store.archive.version, 5)
        XCTAssertEqual(store.archive.week[0].exercises[0].restAfterExerciseSeconds, 90)
        XCTAssertEqual(store.archive.active?.id, session.id)
        XCTAssertEqual(store.archive.active?.exercises[0].restAfterExerciseSeconds, 90)
        XCTAssertEqual(store.archive.active?.exercises[0].isSkipped, false)
        XCTAssertEqual(store.archive.active?.exercises[0].sets[1].reps, "8")
        XCTAssertEqual(store.archive.history[0].id, past.id)
        XCTAssertEqual(store.archive.history[0].volume, 500)
        XCTAssertEqual(store.archive.restUntil, archive.restUntil)
        store.stopRest()
        let saved = try JSONDecoder().decode(TrainingArchive.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.version, 5)
        XCTAssertEqual(saved.history[0].volume, 500)
    }

    @MainActor func testRestChangesFromBetweenSetsToBetweenExercisesAndEndsWithWorkout() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        let date = Date(timeIntervalSince1970: 1_000)
        store.start(day: twoExerciseDay(), date: date)
        let session = try XCTUnwrap(store.archive.active)
        let first = session.exercises[0]
        store.updateSet(exerciseID: first.id, setID: first.sets[0].id, reps: "10", weight: "50")
        XCTAssertTrue(store.toggleSet(exerciseID: first.id, setID: first.sets[0].id, date: date))
        XCTAssertEqual(store.archive.restUntil, date.addingTimeInterval(60))
        XCTAssertEqual(store.archive.restKind, .betweenSets)
        store.updateSet(exerciseID: first.id, setID: first.sets[1].id, reps: "8", weight: "50")
        XCTAssertTrue(store.toggleSet(exerciseID: first.id, setID: first.sets[1].id, date: date.addingTimeInterval(100)))
        let deadline = date.addingTimeInterval(220)
        XCTAssertEqual(store.archive.restUntil, deadline)
        XCTAssertEqual(store.archive.restKind, .betweenExercises)
        XCTAssertEqual(store.archive.restExerciseID, first.id)
        store.selectExercise(1)
        XCTAssertEqual(store.archive.restUntil, deadline)
        let restored = WorkoutStore(fileURL: url)
        XCTAssertEqual(restored.archive.restKind, .betweenExercises)
        XCTAssertEqual(restored.archive.restExerciseID, first.id)
        XCTAssertEqual(restored.archive.restUntil, deadline)
        let last = session.exercises[1]
        for set in last.sets {
            store.updateSet(exerciseID: last.id, setID: set.id, reps: "10", weight: "40")
            XCTAssertTrue(store.toggleSet(exerciseID: last.id, setID: set.id, date: date))
        }
        XCTAssertEqual(store.archive.active?.isCompleted, true)
        XCTAssertNil(store.archive.restUntil)
        XCTAssertNil(store.archive.restKind)
        XCTAssertNil(store.archive.restExerciseID)
    }

    @MainActor func testSingleFinalExerciseDoesNotStartRest() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: day(sets: 1))
        let exercise = try XCTUnwrap(store.archive.active?.exercises[0])
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[0].id, reps: "10", weight: "50")
        XCTAssertTrue(store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[0].id))
        XCTAssertNil(store.archive.restUntil)
        XCTAssertNil(store.archive.restKind)
    }

    @MainActor func testActiveRestSettingsDoNotRestartDeadlineOrChangeProgram() async throws {
        let store = WorkoutStore(fileURL: location())
        let plan = twoExerciseDay()
        store.saveDay(plan)
        store.start(day: plan)
        let session = try XCTUnwrap(store.archive.active)
        let exercise = session.exercises[0]
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[0].id, reps: "10", weight: "50")
        store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[0].id)
        let deadline = store.archive.restUntil
        XCTAssertTrue(store.updateActiveRest(sessionID: session.id, exerciseID: exercise.id, restSeconds: 30, restAfterExerciseSeconds: 180))
        XCTAssertEqual(store.archive.restUntil, deadline)
        XCTAssertEqual(store.archive.active?.exercises[0].restSeconds, 30)
        XCTAssertEqual(store.archive.active?.exercises[0].restAfterExerciseSeconds, 180)
        XCTAssertEqual(store.archive.week[0], plan)
        XCTAssertFalse(store.updateActiveRest(sessionID: session.id, exerciseID: exercise.id, restSeconds: -1, restAfterExerciseSeconds: 180))
        XCTAssertFalse(store.updateActiveRest(sessionID: UUID(), exerciseID: exercise.id, restSeconds: 30, restAfterExerciseSeconds: 180))
        XCTAssertEqual(store.archive.restUntil, deadline)
    }

    @MainActor func testSkipAndReturnPreserveCompletedSetsDraftsAndPlan() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        let plan = twoExerciseDay()
        store.saveDay(plan)
        store.start(day: plan)
        let session = try XCTUnwrap(store.archive.active)
        let exercise = session.exercises[0]
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[0].id, reps: "10", weight: "50")
        store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[0].id)
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[1].id, reps: "7", weight: "45")
        XCTAssertTrue(store.setExerciseSkipped(sessionID: session.id, exerciseID: exercise.id, isSkipped: true))
        XCTAssertEqual(store.archive.active?.currentExercise, 1)
        XCTAssertEqual(store.archive.active?.completedSets, 1)
        XCTAssertEqual(store.archive.active?.skippedSets, 1)
        XCTAssertEqual(store.archive.active?.volume, 500)
        XCTAssertEqual(store.archive.week[0], plan)
        XCTAssertNil(store.archive.restUntil)
        XCTAssertTrue(store.setExerciseSkipped(sessionID: session.id, exerciseID: exercise.id, isSkipped: true))
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[1].id, reps: "99")
        XCTAssertFalse(store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[1].id))
        XCTAssertEqual(store.archive.active?.exercises[0].sets[1].reps, "7")
        let restored = WorkoutStore(fileURL: url)
        XCTAssertEqual(restored.archive.active?.skippedSets, 1)
        XCTAssertTrue(restored.setExerciseSkipped(sessionID: session.id, exerciseID: exercise.id, isSkipped: false))
        XCTAssertEqual(restored.archive.active?.currentExercise, 0)
        XCTAssertEqual(restored.archive.active?.skippedSets, 0)
        XCTAssertEqual(restored.archive.active?.completedSets, 1)
        XCTAssertEqual(restored.archive.active?.exercises[0].sets[1].reps, "7")
        XCTAssertNil(restored.archive.restUntil)
    }

    @MainActor func testResolvedSessionCanFinishWithoutClaimingSkippedSetsCompleted() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: twoExerciseDay())
        let session = try XCTUnwrap(store.archive.active)
        let first = session.exercises[0]
        store.updateSet(exerciseID: first.id, setID: first.sets[0].id, reps: "10", weight: "50")
        store.toggleSet(exerciseID: first.id, setID: first.sets[0].id)
        store.updateSet(exerciseID: first.id, setID: first.sets[1].id, reps: "10", weight: "500")
        XCTAssertTrue(store.setExerciseSkipped(sessionID: session.id, exerciseID: first.id, isSkipped: true))
        XCTAssertTrue(store.setExerciseSkipped(sessionID: session.id, exerciseID: session.exercises[1].id, isSkipped: true))
        XCTAssertEqual(store.archive.active?.isResolved, true)
        XCTAssertEqual(store.archive.active?.isCompleted, false)
        XCTAssertTrue(store.finish())
        let saved = try XCTUnwrap(store.archive.history.first)
        XCTAssertEqual(saved.completedSets, 1)
        XCTAssertEqual(saved.skippedSets, 3)
        XCTAssertEqual(saved.volume, 500)
        XCTAssertEqual(store.progress(for: first.exercise).first?.weight, 50)
        XCTAssertEqual(store.previousExercise(first.exercise)?.sets.filter(\.isCompleted).count, 1)
        XCTAssertTrue(store.progress(for: session.exercises[1].exercise).isEmpty)
        XCTAssertNil(store.previousExercise(session.exercises[1].exercise))
    }

    @MainActor func testAllSkippedSessionDoesNotCreateWorkoutHistory() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: twoExerciseDay())
        let session = try XCTUnwrap(store.archive.active)
        for exercise in session.exercises {
            XCTAssertTrue(store.setExerciseSkipped(sessionID: session.id, exerciseID: exercise.id, isSkipped: true))
        }
        XCTAssertEqual(store.archive.active?.isResolved, true)
        XCTAssertEqual(store.archive.active?.isCompleted, false)
        XCTAssertFalse(store.finish())
        XCTAssertTrue(store.archive.history.isEmpty)
        XCTAssertTrue(store.discardActive())
    }

    @MainActor func testSkipRejectsStaleSessionAndCompletedExercise() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: day(sets: 1))
        let session = try XCTUnwrap(store.archive.active)
        let exercise = session.exercises[0]
        XCTAssertFalse(store.setExerciseSkipped(sessionID: UUID(), exerciseID: exercise.id, isSkipped: true))
        XCTAssertFalse(store.setExerciseSkipped(sessionID: session.id, exerciseID: UUID(), isSkipped: true))
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[0].id, reps: "10", weight: "50")
        store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[0].id)
        XCTAssertFalse(store.setExerciseSkipped(sessionID: session.id, exerciseID: exercise.id, isSkipped: true))
        XCTAssertEqual(store.archive.active?.skippedSets, 0)
    }

    @MainActor func testSkippingAnotherExercisePreservesCurrentRest() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: twoExerciseDay())
        let session = try XCTUnwrap(store.archive.active)
        let first = session.exercises[0]
        store.updateSet(exerciseID: first.id, setID: first.sets[0].id, reps: "10", weight: "50")
        store.toggleSet(exerciseID: first.id, setID: first.sets[0].id)
        let deadline = store.archive.restUntil
        XCTAssertTrue(store.setExerciseSkipped(sessionID: session.id, exerciseID: session.exercises[1].id, isSkipped: true))
        XCTAssertEqual(store.archive.restUntil, deadline)
        XCTAssertEqual(store.archive.active?.currentExercise, 0)
    }

    @MainActor func testFullySkippedExerciseDoesNotReplacePreviousResultOrProgress() async throws {
        let store = WorkoutStore(fileURL: location())
        let firstPlan = day(sets: 1)
        store.start(day: firstPlan)
        let first = try XCTUnwrap(store.archive.active?.exercises[0])
        store.updateSet(exerciseID: first.id, setID: first.sets[0].id, reps: "8", weight: "80")
        store.toggleSet(exerciseID: first.id, setID: first.sets[0].id)
        XCTAssertTrue(store.finish())
        store.start(day: twoExerciseDay(sets: 1))
        let session = try XCTUnwrap(store.archive.active)
        let skipped = session.exercises[0]
        store.updateSet(exerciseID: skipped.id, setID: skipped.sets[0].id, reps: "10", weight: "500")
        store.setExerciseSkipped(sessionID: session.id, exerciseID: skipped.id, isSkipped: true)
        let performed = session.exercises[1]
        store.updateSet(exerciseID: performed.id, setID: performed.sets[0].id, reps: "10", weight: "40")
        store.toggleSet(exerciseID: performed.id, setID: performed.sets[0].id)
        XCTAssertTrue(store.finish())
        XCTAssertEqual(store.previousExercise(skipped.exercise)?.sets[0].weightValue, 80)
        XCTAssertEqual(store.progress(for: skipped.exercise).map(\.weight), [80])
    }

    @MainActor func testProgramRejectsInvalidRestAfterExercise() async {
        let store = WorkoutStore(fileURL: location())
        var plan = day()
        plan.exercises[0].restAfterExerciseSeconds = 601
        XCTAssertFalse(store.saveDay(plan))
        plan.exercises[0].restAfterExerciseSeconds = -1
        XCTAssertFalse(store.saveDay(plan))
    }

}
