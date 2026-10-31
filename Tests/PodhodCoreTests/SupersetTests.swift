import XCTest
@testable import PodhodCore

final class SupersetTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SupersetQA-\(UUID())/training.json")
    }

    private func day() -> TrainingDay {
        var day = TrainingDay(weekday: 1, title: "Суперсет", exercises: [
            PlannedExercise(exercise: Exercise.catalog[0], setCount: 2),
            PlannedExercise(exercise: Exercise.catalog[2], setCount: 2)
        ])
        day.supersets = [PlannedSuperset(exerciseIDs: day.exercises.map(\.id), restSeconds: 90)]
        return day
    }

    @MainActor private func complete(_ store: WorkoutStore, card: Int, set: Int, at date: Date) throws {
        let exercise = try XCTUnwrap(store.archive.active?.exercises[card])
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[set].id, reps: "8", weight: "20", date: date)
        XCTAssertTrue(store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[set].id, date: date))
    }

    func testPlannedGroupValidationAndSessionLinksUseFreshPhysicalIDs() {
        let plan = day()
        XCTAssertTrue(plan.hasValidPlannedStructure)
        let session = WorkoutSession(day: plan)
        XCTAssertTrue(session.hasValidStructure)
        XCTAssertEqual(session.structureVersion, 1)
        XCTAssertEqual(session.supersets?.first?.rounds.count, 2)
        XCTAssertNotEqual(session.supersets?.first?.exerciseIDs, plan.supersets?.first?.exerciseIDs)
        XCTAssertEqual(session.supersets?.first?.rounds[0].setIDs, session.exercises.map { $0.sets[0].id })
        var invalid = plan
        invalid.exercises[0].setCount = 3
        XCTAssertFalse(invalid.hasValidPlannedStructure)
        invalid = plan
        invalid.supersets?[0].exerciseIDs[1] = invalid.exercises[0].id
        XCTAssertFalse(invalid.hasValidPlannedStructure)
        invalid = plan
        invalid.supersets?[0].restSeconds = 601
        XCTAssertFalse(invalid.hasValidPlannedStructure)
    }

    @MainActor func testRoundAlternatesMembersAndStartsRestOnlyAfterWholeRound() async throws {
        let store = WorkoutStore(fileURL: location())
        XCTAssertTrue(store.start(day: day(), date: date))
        try complete(store, card: 0, set: 0, at: date)
        XCTAssertNil(store.archive.restUntil)
        XCTAssertEqual(store.archive.active?.currentExercise, 1)
        try complete(store, card: 1, set: 0, at: date.addingTimeInterval(10))
        XCTAssertEqual(store.archive.restUntil, date.addingTimeInterval(100))
        XCTAssertEqual(store.archive.active?.currentExercise, 0)
        let session = try XCTUnwrap(store.archive.active)
        XCTAssertTrue(store.stopRest(sessionID: session.id, expectedDeadline: date.addingTimeInterval(100), date: date.addingTimeInterval(40)))
        try complete(store, card: 0, set: 1, at: date.addingTimeInterval(50))
        XCTAssertNil(store.archive.restUntil)
        try complete(store, card: 1, set: 1, at: date.addingTimeInterval(60))
        XCTAssertNil(store.archive.restUntil)
        XCTAssertTrue(store.archive.active?.isCompleted == true)
        XCTAssertTrue(store.finish(date: date.addingTimeInterval(70)))
        XCTAssertTrue(store.archive.history[0].hasValidStructure)
        XCTAssertEqual(store.archive.history[0].supersets?.first?.rounds.count, 2)
    }

    @MainActor func testReplacementPreservesCompletedSourcesReserveAndRestDeadline() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        XCTAssertTrue(store.start(day: day(), date: date))
        try complete(store, card: 0, set: 0, at: date)
        try complete(store, card: 1, set: 0, at: date.addingTimeInterval(10))
        let before = try XCTUnwrap(store.archive.active)
        let original = before.exercises[0]
        XCTAssertTrue(store.setRepetitionsInReserve(exerciseID: original.id, setID: original.sets[0].id, reserve: .failure))
        let assessed = try XCTUnwrap(store.archive.active)
        XCTAssertTrue(store.replaceActiveExercise(sessionID: assessed.id, original: assessed.exercises[0],
            with: Exercise.catalog[3], date: date.addingTimeInterval(20)))
        let replaced = try XCTUnwrap(store.archive.active)
        XCTAssertTrue(replaced.hasValidStructure)
        XCTAssertTrue(replaced.preservesSupersetLinks(from: assessed))
        XCTAssertEqual(replaced.exercises[0].sets, assessed.exercises[0].sets)
        XCTAssertEqual(replaced.supersets?.first?.rounds[0].setIDs, assessed.supersets?.first?.rounds[0].setIDs)
        XCTAssertEqual(replaced.supersets?.first?.exerciseIDs[0], replaced.exercises[1].id)
        XCTAssertEqual(replaced.supersets?.first?.rounds[1].setIDs[0], replaced.exercises[1].sets[0].id)
        XCTAssertEqual(store.archive.restUntil, date.addingTimeInterval(100))
        XCTAssertEqual(store.archive.restExerciseID, before.exercises[1].id)
        XCTAssertEqual(WorkoutStore(fileURL: url).archive, store.archive)
    }

    @MainActor func testCloseAndSkipKeepCompletedLinksAndAllDrafts() async throws {
        for skip in [false, true] {
            let store = WorkoutStore(fileURL: location())
            XCTAssertTrue(store.start(day: day(), date: date))
            try complete(store, card: 0, set: 0, at: date)
            let before = try XCTUnwrap(store.archive.active)
            let other = before.exercises[1]
            store.updateSet(exerciseID: other.id, setID: other.sets[0].id, reps: "черновик", weight: "12,5", date: date)
            if skip {
                XCTAssertTrue(store.setExerciseSkipped(sessionID: before.id, exerciseID: other.id, isSkipped: true, date: date))
            } else {
                XCTAssertTrue(store.closeActiveSuperset(sessionID: before.id, expected: before.supersets![0], date: date))
            }
            let after = try XCTUnwrap(store.archive.active)
            XCTAssertTrue(after.hasValidStructure)
            XCTAssertTrue(after.preservesSupersetLinks(from: before))
            XCTAssertEqual(after.supersets?.first?.isClosed, true)
            XCTAssertEqual(after.supersets?.first?.rounds.count, 1)
            XCTAssertNil(after.supersets?.first?.rounds[0].setIDs[1])
            XCTAssertEqual(after.exercises[1].sets[0].reps, "черновик")
            XCTAssertEqual(after.exercises.map { $0.sets.count }, [2, 2])
            if skip {
                XCTAssertTrue(store.setExerciseSkipped(sessionID: after.id, exerciseID: other.id, isSkipped: false, date: date))
                XCTAssertEqual(store.archive.active?.supersets?.first?.isClosed, true)
            }
        }
    }

    @MainActor func testExplicitSetRemovalPrunesOnlyLinkAndKeepsRemovalIntent() async throws {
        let store = WorkoutStore(fileURL: location())
        XCTAssertTrue(store.start(day: day(), date: date))
        let before = try XCTUnwrap(store.archive.active)
        let card = before.exercises[0]
        let removed = card.sets[0].id
        XCTAssertTrue(store.setRepetitionsInReserve(exerciseID: card.id, setID: removed, reserve: .two))
        XCTAssertTrue(store.removeActiveSet(sessionID: before.id, exerciseID: card.id, setID: removed, date: date))
        let after = try XCTUnwrap(store.archive.active)
        XCTAssertTrue(after.hasValidStructure)
        XCTAssertNil(after.supersets?.first?.rounds[0].setIDs[0])
        XCTAssertEqual(after.supersets?.first?.rounds[1], before.supersets?.first?.rounds[1])
        XCTAssertTrue(store.removedSetIDs(for: after).contains(removed))
    }

    @MainActor func testAddingRoundIsAtomicAndStandaloneAdditionStaysOutsideGroup() async throws {
        let store = WorkoutStore(fileURL: location())
        XCTAssertTrue(store.start(day: day(), date: date))
        let session = try XCTUnwrap(store.archive.active)
        let group = try XCTUnwrap(session.supersets?.first)
        XCTAssertTrue(store.addSupersetRound(sessionID: session.id, expected: group, date: date))
        XCTAssertEqual(store.archive.active?.exercises.map { $0.sets.count }, [3, 3])
        XCTAssertEqual(store.archive.active?.supersets?.first?.rounds.last?.ordinal, 3)
        XCTAssertFalse(store.addSupersetRound(sessionID: session.id, expected: group, date: date))
        XCTAssertTrue(store.addActiveSet(sessionID: session.id, exerciseID: session.exercises[0].id, date: date))
        let updated = try XCTUnwrap(store.archive.active)
        XCTAssertEqual(updated.supersets?.first?.rounds.count, 3)
        XCTAssertFalse(updated.supersets!.flatMap(\.rounds).flatMap(\.setIDs).contains(updated.exercises[0].sets.last!.id))
        XCTAssertTrue(updated.hasValidStructure)
    }

    @MainActor func testCreatingGroupMidWorkoutUsesOnlyPendingSetsAndRejectsStaleSelection() async throws {
        let store = WorkoutStore(fileURL: location())
        var source = day()
        source.supersets = nil
        XCTAssertTrue(store.start(day: source, date: date))
        let before = try XCTUnwrap(store.archive.active)
        try complete(store, card: 0, set: 0, at: date)
        XCTAssertFalse(store.createActiveSuperset(sessionID: before.id, expectedExercises: before.exercises, restSeconds: 90, date: date))
        try complete(store, card: 1, set: 0, at: date)
        let current = try XCTUnwrap(store.archive.active)
        XCTAssertTrue(store.createActiveSuperset(sessionID: current.id, expectedExercises: current.exercises, restSeconds: 90, date: date))
        let group = try XCTUnwrap(store.archive.active?.supersets?.first)
        XCTAssertEqual(group.rounds.count, 1)
        XCTAssertEqual(group.rounds[0].setIDs, current.exercises.map { $0.sets[1].id })
        XCTAssertEqual(store.archive.active?.completedSets, 2)
    }

    func testMalformedGroupsAndReassignedCompletedSourceCannotBeAccepted() {
        var session = WorkoutSession(day: day())
        session.exercises[0].sets[0].isCompleted = true
        var changed = session
        changed.exercises[0].exercise.id = UUID()
        XCTAssertFalse(changed.preservesSupersetLinks(from: session))
        changed = session
        changed.supersets?[0].rounds[0].ordinal = 10
        XCTAssertFalse(changed.preservesSupersetLinks(from: session))
        changed = session
        let duplicate = changed.supersets?[0].rounds[0].setIDs[0]
        changed.supersets?[0].rounds[1].setIDs[0] = duplicate
        XCTAssertFalse(changed.hasValidStructure)
        changed = session
        changed.structureVersion = nil
        XCTAssertFalse(changed.hasValidStructure)
        XCTAssertFalse(changed.preservesSupersetLinks(from: session))
    }

    func testPlannedRoundCountChangesTogetherWithoutChangingOtherCards() {
        var plan = day()
        plan.exercises.append(PlannedExercise(exercise: Exercise.catalog[3], setCount: 5))
        plan.setPlannedSetCount(exerciseID: plan.exercises[0].id, count: 4)
        XCTAssertEqual(plan.exercises.map(\.setCount), [4, 4, 5])
        XCTAssertTrue(plan.hasValidPlannedStructure)
        plan.setPlannedSetCount(exerciseID: plan.exercises[0].id, count: 13)
        XCTAssertEqual(plan.exercises.map(\.setCount), [4, 4, 5])
    }

    @MainActor func testDeclaredGroupOrderStartsWithFirstMemberAndClosedCompletionIsProtected() async throws {
        var source = day()
        source.supersets?[0].exerciseIDs.reverse()
        let store = WorkoutStore(fileURL: location())
        XCTAssertTrue(store.start(day: source, date: date))
        XCTAssertEqual(store.archive.active?.currentExercise, 1)
        try complete(store, card: 1, set: 0, at: date)
        let current = try XCTUnwrap(store.archive.active)
        XCTAssertTrue(store.closeActiveSuperset(sessionID: current.id, expected: current.supersets![0], date: date))
        let closed = store.archive
        let card = current.exercises[1]
        XCTAssertFalse(store.toggleSet(exerciseID: card.id, setID: card.sets[0].id, date: date))
        XCTAssertEqual(store.archive, closed)
        XCTAssertTrue(store.setRepetitionsInReserve(exerciseID: card.id, setID: card.sets[0].id, reserve: .one))
        XCTAssertEqual(store.archive.active?.exercises[1].sets[0].repsInReserve, .one)
    }
}
