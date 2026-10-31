import XCTest
@testable import PodhodCore

final class SetEffortTests: XCTestCase {
    @MainActor func testReservePersistsBeforeAndAfterCompletionAndInHistory() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Effort-\(UUID())/training.json")
        let store = WorkoutStore(fileURL: url)
        let plan = TrainingDay(weekday: 1, title: "Жим", exercises: [PlannedExercise(exercise: Exercise.catalog[0], setCount: 1)])
        XCTAssertTrue(store.start(day: plan))
        let exercise = try XCTUnwrap(store.archive.active?.exercises.first)
        let setID = exercise.sets[0].id
        XCTAssertNil(exercise.sets[0].repsInReserve)
        XCTAssertTrue(store.setRepetitionsInReserve(exerciseID: exercise.id, setID: setID, reserve: .two))
        store.updateSet(exerciseID: exercise.id, setID: setID, reps: "10", weight: "60")
        XCTAssertTrue(store.toggleSet(exerciseID: exercise.id, setID: setID))
        let timing = store.archive.active?.timing
        XCTAssertTrue(store.setRepetitionsInReserve(exerciseID: exercise.id, setID: setID, reserve: .failure))
        XCTAssertEqual(store.archive.active?.timing, timing)
        XCTAssertEqual(store.archive.active?.volume, 600)
        XCTAssertEqual(WorkoutStore(fileURL: url).archive.active?.exercises[0].sets[0].repsInReserve, .failure)
        XCTAssertTrue(store.setRepetitionsInReserve(exerciseID: exercise.id, setID: setID, reserve: .notRecorded))
        XCTAssertEqual(store.archive.active?.exercises[0].sets[0].repsInReserve, .notRecorded)
        XCTAssertTrue(store.setRepetitionsInReserve(exerciseID: exercise.id, setID: setID, reserve: .fiveOrMore))
        XCTAssertTrue(store.finish())
        XCTAssertFalse(store.setRepetitionsInReserve(exerciseID: exercise.id, setID: setID, reserve: .one))
        let restored = WorkoutStore(fileURL: url)
        XCTAssertEqual(restored.archive.history[0].exercises[0].sets[0].repsInReserve, .fiveOrMore)
        XCTAssertEqual(restored.previousExercise(exercise.exercise)?.sets[0].repsInReserve, .fiveOrMore)
    }

    func testLegacySetAndAllReserveValuesRoundTrip() throws {
        let legacy = Data("{\"id\":\"\(UUID())\",\"reps\":\"10\",\"weight\":\"60\",\"isCompleted\":true}".utf8)
        let set = try JSONDecoder().decode(LoggedSet.self, from: legacy)
        XCTAssertNil(set.repsInReserve)
        XCTAssertTrue(set.isValid)
        for reserve in RepetitionsInReserve.allCases {
            var changed = set
            changed.repsInReserve = reserve
            let encoded = try JSONEncoder().encode(changed)
            XCTAssertEqual(try JSONDecoder().decode(LoggedSet.self, from: encoded), changed)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(json["repsInReserve"] as? Int, reserve.rawValue)
        }
    }

    @MainActor func testVersionThreeBackupPreservesUnknownReserveAndOriginalData() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EffortMigration-\(UUID())/training.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var archive = TrainingArchive()
        archive.version = 3
        archive.active = WorkoutSession(day: TrainingDay(weekday: 1, title: "Старый план", exercises: [PlannedExercise(exercise: Exercise.catalog[0])]))
        archive.active?.exercises[0].sets[0].weight = "62,5"
        let original = try JSONEncoder().encode(archive)
        try original.write(to: url)
        let store = WorkoutStore(fileURL: url)
        let exercise = try XCTUnwrap(store.archive.active?.exercises[0])
        XCTAssertEqual(store.archive.version, 5)
        XCTAssertNil(exercise.sets[0].repsInReserve)
        XCTAssertTrue(store.setRepetitionsInReserve(exerciseID: exercise.id, setID: exercise.sets[0].id, reserve: .one))
        XCTAssertEqual(try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("training-v3-backup.json")), original)
        XCTAssertEqual(store.archive.active?.id, archive.active?.id)
        XCTAssertEqual(store.archive.active?.exercises[0].sets[0].weight, "62,5")
    }

    @MainActor func testExerciseHistoryResolvesOnlyExactAliasesAndKeepsSnapshots() async throws {
        let store = WorkoutStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ExerciseHistory-\(UUID())/training.json"))
        let alias = try XCTUnwrap(ExerciseCatalog.bundled.exerciseIDAliases.first)
        let canonical = try XCTUnwrap(ExerciseCatalog.bundled.entry(for: alias.exerciseID)?.exercise)
        var legacy = canonical
        legacy.id = alias.id
        legacy.cue = "Личная заметка"
        var session = WorkoutSession(day: TrainingDay(weekday: 1, title: "История", exercises: [
            PlannedExercise(exercise: legacy), PlannedExercise(exercise: canonical)
        ]), date: Date(timeIntervalSince1970: 1_000))
        session.finishedAt = Date(timeIntervalSince1970: 2_000)
        session.exercises[0].sets[0] = LoggedSet(reps: "10", weight: "60", isCompleted: true, repsInReserve: .two)
        session.exercises[1].sets[0] = LoggedSet(reps: "8", weight: "65", isCompleted: true)
        session.exercises[1].sets[1] = LoggedSet(reps: "10", weight: "999")
        XCTAssertTrue(store.mergeHistory([session]))
        let history = store.exerciseHistory(for: canonical)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].exercises.count, 2)
        XCTAssertEqual(history[0].exercises[0].exercise.id, alias.id)
        XCTAssertEqual(history[0].exercises[0].exercise.cue, "Личная заметка")
        XCTAssertEqual(store.progress(for: canonical).map(\.weight), [65])
        var unrelated = canonical
        unrelated.id = UUID()
        XCTAssertTrue(store.exerciseHistory(for: unrelated).isEmpty)
        XCTAssertEqual(store.archive.history, [session])
    }
}
