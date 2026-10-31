import XCTest
@testable import PodhodCore

final class SetRemovalIntentTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SetRemovals-\(UUID())/training.json")
    }

    private func plan() -> TrainingDay {
        TrainingDay(weekday: 1, title: "Удаление подхода", exercises: [PlannedExercise(exercise: Exercise.catalog[0], setCount: 2)])
    }

    @MainActor func testAssessedDraftRemovalSurvivesRestartAndFinishingOffline() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        store.start(day: plan())
        let session = try XCTUnwrap(store.archive.active)
        let exercise = session.exercises[0]
        let removedID = exercise.sets[1].id
        store.setRepetitionsInReserve(exerciseID: exercise.id, setID: removedID, reserve: .two)
        let beforeRemoval = try XCTUnwrap(store.archive.active)
        XCTAssertTrue(store.removeActiveSet(sessionID: session.id, exerciseID: exercise.id, setID: removedID))
        let restored = WorkoutStore(fileURL: url)
        XCTAssertFalse(restored.loadFailed)
        XCTAssertEqual(restored.removedSetIDs(for: try XCTUnwrap(restored.archive.active)), [removedID])
        XCTAssertTrue(restored.removedSetIDs(for: beforeRemoval).isEmpty)
        XCTAssertTrue(restored.acknowledgeFinishedSetRemovals(sessionIDs: [session.id]))
        XCTAssertEqual(restored.archive.setRemovalIntents?.count, 1)
        restored.updateSet(exerciseID: exercise.id, setID: exercise.sets[0].id, reps: "10", weight: "60")
        XCTAssertTrue(restored.toggleSet(exerciseID: exercise.id, setID: exercise.sets[0].id))
        XCTAssertTrue(restored.finish())
        let finished = try XCTUnwrap(WorkoutStore(fileURL: url).archive.history.first)
        XCTAssertEqual(restored.removedSetIDs(for: finished), [removedID])
        XCTAssertTrue(restored.acknowledgeFinishedSetRemovals(sessionIDs: [UUID()]))
        XCTAssertEqual(restored.archive.setRemovalIntents?.count, 1)
        XCTAssertTrue(restored.acknowledgeFinishedSetRemovals(sessionIDs: [finished.id]))
        XCTAssertNil(WorkoutStore(fileURL: url).archive.setRemovalIntents)
        XCTAssertEqual(restored.archive.history.first, finished)
    }

    @MainActor func testServerChoiceDiscardsOnlyIntentsThatWereRestored() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: plan())
        let initial = try XCTUnwrap(store.activeWorkoutState)
        let exercise = initial.session.exercises[0]
        XCTAssertTrue(store.removeActiveSet(sessionID: initial.session.id, exerciseID: exercise.id, setID: exercise.sets[1].id))
        XCTAssertTrue(store.restoreActiveWorkout(initial))
        XCTAssertNil(store.archive.setRemovalIntents)
        XCTAssertEqual(store.archive.active?.exercises[0].sets.count, 2)
        XCTAssertTrue(store.removeActiveSet(sessionID: initial.session.id, exerciseID: exercise.id, setID: exercise.sets[1].id))
        XCTAssertTrue(store.discardActive())
        XCTAssertNil(store.archive.setRemovalIntents)
        store.start(day: plan())
        XCTAssertTrue(store.removedSetIDs(for: try XCTUnwrap(store.archive.active)).isEmpty)
    }

    @MainActor func testFailedRemovalDoesNotApplyIntentOrLoseDraft() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        store.start(day: plan())
        let session = try XCTUnwrap(store.archive.active)
        let exercise = session.exercises[0]
        store.setRepetitionsInReserve(exerciseID: exercise.id, setID: exercise.sets[1].id, reserve: .failure)
        let before = store.archive
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertFalse(store.removeActiveSet(sessionID: session.id, exerciseID: exercise.id, setID: exercise.sets[1].id))
        XCTAssertEqual(store.archive, before)
    }

    @MainActor func testVersionFourIsBackedUpBeforePersistingRemovalIntent() async throws {
        let url = location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var archive = TrainingArchive()
        archive.version = 4
        archive.active = WorkoutSession(day: plan())
        let original = try JSONEncoder().encode(archive)
        try original.write(to: url)
        let store = WorkoutStore(fileURL: url)
        let session = try XCTUnwrap(store.archive.active)
        XCTAssertTrue(store.removeActiveSet(sessionID: session.id, exerciseID: session.exercises[0].id, setID: session.exercises[0].sets[1].id))
        XCTAssertEqual(store.archive.version, 5)
        XCTAssertEqual(try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("training-v4-backup.json")), original)
        XCTAssertEqual(store.archive.active?.id, session.id)
    }

    @MainActor func testCorruptRemovalJournalIsProtectedFromOverwrite() async throws {
        let url = location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var archive = TrainingArchive()
        archive.setRemovalIntents = [SetRemovalIntent(sessionID: UUID(), setID: UUID())]
        let original = try JSONEncoder().encode(archive)
        try original.write(to: url)
        let store = WorkoutStore(fileURL: url)
        XCTAssertTrue(store.loadFailed)
        XCTAssertFalse(store.start(day: plan()))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
