import XCTest
@testable import PodhodCore

final class WorkoutTimingTests: XCTestCase {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TimingTests-\(UUID())/training.json")
    }
    private func day(sets: Int = 2, rest: Int = 60, after: Int = 20) -> TrainingDay {
        TrainingDay(weekday: 1, title: "Учёт времени", exercises: [
            PlannedExercise(exercise: Exercise.catalog[0], setCount: sets, restSeconds: rest, restAfterExerciseSeconds: after),
            PlannedExercise(exercise: Exercise.catalog[1], setCount: sets, restSeconds: rest, restAfterExerciseSeconds: after)
        ])
    }
    @MainActor private func complete(_ store: WorkoutStore, exercise: SessionExercise, set: Int, at seconds: Double) {
        store.updateSet(exerciseID: exercise.id, setID: exercise.sets[set].id, reps: "10", weight: "60", date: date(seconds))
        XCTAssertTrue(store.toggleSet(exerciseID: exercise.id, setID: exercise.sets[set].id, date: date(seconds)))
    }

    @MainActor func testSwitchingExerciseRecordsActualBoundaries() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: day(), date: date(1000))
        let initial = try XCTUnwrap(store.archive.active)
        store.selectExercise(1, date: date(1010))
        store.selectExercise(0, date: date(1025))
        let session = try XCTUnwrap(store.archive.active)
        let totals = try XCTUnwrap(session.timingTotals(at: date(1030)))
        XCTAssertEqual(totals.exerciseSeconds, 30, accuracy: 0.0001)
        XCTAssertEqual(totals.exercises[initial.exercises[0].id]?.exerciseSeconds, 15)
        XCTAssertEqual(totals.exercises[initial.exercises[1].id]?.exerciseSeconds, 15)
        XCTAssertEqual(totals.restSeconds, 0)
        XCTAssertEqual(totals.untrackedSeconds, 0)
        XCTAssertTrue(try XCTUnwrap(session.timing).isValid(for: session))
    }

    @MainActor func testEarlyRestStopCountsOnlyActualRest() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: day(), date: date(1000))
        let exercise = try XCTUnwrap(store.archive.active?.exercises[0])
        complete(store, exercise: exercise, set: 0, at: 1010)
        store.stopRest(date: date(1030))
        let totals = try XCTUnwrap(store.archive.active?.timingTotals(at: date(1040)))
        XCTAssertEqual(totals.exerciseSeconds, 20, accuracy: 0.0001)
        XCTAssertEqual(totals.restSeconds, 20, accuracy: 0.0001)
        XCTAssertEqual(totals.exercises[exercise.id]?.restSeconds, 20)
        XCTAssertNil(store.archive.restUntil)
    }

    @MainActor func testExpiredRestProjectionIsPureAndSettlesOnNextAction() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        store.start(day: day(), date: date(1000))
        let first = try XCTUnwrap(store.archive.active?.exercises[0])
        complete(store, exercise: first, set: 0, at: 1010)
        let before = store.archive
        let bytes = try Data(contentsOf: url)
        let totals = try XCTUnwrap(store.archive.active?.timingTotals(at: date(1100)))
        XCTAssertEqual(totals.restSeconds, 60, accuracy: 0.0001)
        XCTAssertEqual(totals.exerciseSeconds, 40, accuracy: 0.0001)
        XCTAssertEqual(store.archive, before)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(store.archive.active?.timing?.intervals.map(\.id), before.active?.timing?.intervals.map(\.id))
        store.selectExercise(1, date: date(1110))
        let session = try XCTUnwrap(store.archive.active)
        let settled = try XCTUnwrap(session.timingTotals(at: date(1120)))
        XCTAssertEqual(settled.exercises[first.id]?.exerciseSeconds, 50)
        XCTAssertEqual(settled.restSeconds, 60)
        XCTAssertEqual(settled.exerciseSeconds, 60)
        XCTAssertEqual(session.timing?.intervals.map(\.kind), [.exercise, .rest, .exercise, .exercise])
        XCTAssertEqual(session.timing?.intervals[1].endedAt, date(1070))
    }

    @MainActor func testFinalizedTotalsSeparateExerciseRestAndTransitions() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: day(sets: 1), date: date(1000))
        let session = try XCTUnwrap(store.archive.active)
        complete(store, exercise: session.exercises[0], set: 0, at: 1010)
        let afterExpiry = try XCTUnwrap(store.archive.active?.timingTotals(at: date(1040)))
        XCTAssertEqual(afterExpiry.otherSeconds, 10)
        store.selectExercise(1, date: date(1050))
        complete(store, exercise: session.exercises[1], set: 0, at: 1060)
        XCTAssertNil(store.archive.restUntil)
        XCTAssertTrue(store.finish(date: date(1070)))
        let saved = try XCTUnwrap(store.archive.history.first)
        let totals = try XCTUnwrap(saved.timingTotals(at: date(5000)))
        XCTAssertEqual(saved.duration, 70)
        XCTAssertEqual(totals.exerciseSeconds, 20)
        XCTAssertEqual(totals.restSeconds, 20)
        XCTAssertEqual(totals.otherSeconds, 30)
        XCTAssertEqual(totals.untrackedSeconds, 0)
        XCTAssertEqual(totals.exercises[session.exercises[0].id]?.restSeconds, 20)
        XCTAssertEqual(totals.exercises[session.exercises[1].id]?.restSeconds, 0)
        XCTAssertTrue(try XCTUnwrap(saved.timing).intervals.allSatisfy { $0.endedAt != nil })
        XCTAssertTrue(try XCTUnwrap(saved.timing).isValid(for: saved))
    }

    @MainActor func testSkipAndReturnMoveTimingAtTheActionMoment() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: day(), date: date(1000))
        let session = try XCTUnwrap(store.archive.active)
        XCTAssertTrue(store.setExerciseSkipped(sessionID: session.id, exerciseID: session.exercises[0].id, isSkipped: true, date: date(1010)))
        XCTAssertTrue(store.setExerciseSkipped(sessionID: session.id, exerciseID: session.exercises[0].id, isSkipped: false, date: date(1020)))
        let totals = try XCTUnwrap(store.archive.active?.timingTotals(at: date(1030)))
        XCTAssertEqual(totals.exercises[session.exercises[0].id]?.exerciseSeconds, 20)
        XCTAssertEqual(totals.exercises[session.exercises[1].id]?.exerciseSeconds, 10)
        XCTAssertEqual(totals.restSeconds, 0)
    }

    @MainActor func testChangingRestSettingsDoesNotRewriteRunningIntervalDeadline() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: day(), date: date(1000))
        let session = try XCTUnwrap(store.archive.active)
        complete(store, exercise: session.exercises[0], set: 0, at: 1010)
        store.updateActiveRest(sessionID: session.id, exerciseID: session.exercises[0].id,
                               restSeconds: 300, restAfterExerciseSeconds: 300, date: date(1020))
        XCTAssertEqual(store.archive.restUntil, date(1070))
        XCTAssertEqual(store.archive.active?.timing?.intervals.last?.restDeadline, date(1070))
        XCTAssertEqual(store.archive.active?.timingTotals(at: date(1100))?.restSeconds, 60)
    }

    @MainActor func testLongBackgroundAndRestartUsePersistedAbsoluteDates() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        store.start(day: day(), date: date(1000))
        let exercise = try XCTUnwrap(store.archive.active?.exercises[0])
        complete(store, exercise: exercise, set: 0, at: 1010)
        let restored = WorkoutStore(fileURL: url)
        XCTAssertFalse(restored.loadFailed)
        XCTAssertEqual(restored.archive.active?.timing, store.archive.active?.timing)
        let totals = try XCTUnwrap(restored.archive.active?.timingTotals(at: date(2000)))
        XCTAssertEqual(totals.restSeconds, 60)
        XCTAssertEqual(totals.exerciseSeconds, 940)
        restored.selectExercise(1, date: date(2000))
        XCTAssertEqual(restored.archive.active?.timingTotals(at: date(2010))?.exerciseSeconds, 950)
    }

    @MainActor func testLegacyActiveTracksOnlyFromFirstNewActionAndBacksUpVersionTwo() async throws {
        let url = location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var archive = TrainingArchive()
        archive.version = 2
        archive.active = WorkoutSession(day: day(), date: date(1000))
        var old = WorkoutSession(day: day(), date: date(500))
        old.exercises[0].sets[0].isCompleted = true
        old.exercises[0].sets[0].weight = "60"
        old.exercises[0].sets[0].reps = "10"
        old.finishedAt = date(600)
        archive.history = [old]
        let original = try JSONEncoder().encode(archive)
        try original.write(to: url)
        let store = WorkoutStore(fileURL: url)
        XCTAssertFalse(store.loadFailed)
        XCTAssertEqual(store.archive.version, 3)
        XCTAssertNil(store.archive.active?.timing)
        XCTAssertNil(store.archive.history[0].timingTotals())
        store.selectExercise(1, date: date(1100))
        let totals = try XCTUnwrap(store.archive.active?.timingTotals(at: date(1150)))
        XCTAssertEqual(store.archive.active?.timing?.trackedFrom, date(1100))
        XCTAssertEqual(totals.exerciseSeconds, 50)
        XCTAssertEqual(totals.untrackedSeconds, 100)
        XCTAssertEqual(try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("training-v2-backup.json")), original)
        XCTAssertNil(store.archive.history[0].timing)
    }

    @MainActor func testRemoteSkipSettlesOldPhoneContextUntilLocalApply() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: day(), date: date(1000))
        let session = try XCTUnwrap(store.archive.active)
        complete(store, exercise: session.exercises[0], set: 0, at: 1010)
        var incoming = try XCTUnwrap(store.activeWorkoutState)
        incoming.session.exercises[0].isSkipped = true
        incoming.session.currentExercise = 1
        incoming.restUntil = nil
        incoming.restKind = nil
        incoming.restExerciseID = nil
        XCTAssertTrue(store.restoreActiveWorkout(incoming, date: date(1100)))
        let applied = try XCTUnwrap(store.archive.active)
        let totals = try XCTUnwrap(applied.timingTotals(at: date(1120)))
        XCTAssertEqual(applied.completedSets, 1)
        XCTAssertEqual(applied.exercises[0].sets[0].weight, "60")
        XCTAssertEqual(totals.exercises[session.exercises[0].id]?.exerciseSeconds, 40)
        XCTAssertEqual(totals.exercises[session.exercises[1].id]?.exerciseSeconds, 20)
        XCTAssertEqual(totals.restSeconds, 60)
        XCTAssertTrue(try XCTUnwrap(applied.timing).isValid(for: applied))
        XCTAssertEqual(applied.timing?.intervals.last?.startedAt, date(1100))
    }

    @MainActor func testRestoreWithoutLocalContextDoesNotBackfillNewExerciseAfterExpiredRest() async throws {
        let store = WorkoutStore(fileURL: location())
        var session = WorkoutSession(day: day(), date: date(1000))
        session.currentExercise = 1
        session.timing = WorkoutTiming(trackedFrom: date(1000), intervals: [
            WorkoutTimingInterval(kind: .rest, exerciseID: session.exercises[0].id,
                                 restKind: .betweenSets, startedAt: date(1000), restDeadline: date(1060))
        ])
        let incoming = ActiveWorkoutState(session: session, restUntil: nil, restKind: nil, restExerciseID: nil)
        XCTAssertTrue(store.restoreActiveWorkout(incoming, date: date(1100)))
        let totals = try XCTUnwrap(store.archive.active?.timingTotals(at: date(1120)))
        XCTAssertEqual(totals.exerciseSeconds, 20)
        XCTAssertEqual(totals.restSeconds, 60)
        XCTAssertEqual(totals.untrackedSeconds, 40)
        XCTAssertEqual(totals.exercises[session.exercises[1].id]?.exerciseSeconds, 20)
    }

    @MainActor func testSubMillisecondEventsRemainPositiveAfterNetworkDateRoundTrip() async throws {
        let store = WorkoutStore(fileURL: location())
        store.start(day: day(sets: 1, rest: 0, after: 0), date: date(1000.0002))
        store.selectExercise(1, date: date(1000.0004))
        store.selectExercise(0, date: date(1000.0012))
        store.selectExercise(1, date: date(1000.0027))
        let exercise = try XCTUnwrap(store.archive.active?.exercises[1])
        complete(store, exercise: exercise, set: 0, at: 1000.0034)
        XCTAssertTrue(store.finish(allowPartial: true, date: date(1000.0038)))
        let session = try XCTUnwrap(store.archive.history.first)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            let text = try value.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return try XCTUnwrap(formatter.date(from: text))
        }
        let decoded = try decoder.decode(WorkoutSession.self, from: encoder.encode(session))
        XCTAssertTrue(try XCTUnwrap(decoded.timing).isValid(for: decoded))
        for interval in try XCTUnwrap(decoded.timing).intervals {
            XCTAssertGreaterThan(try XCTUnwrap(interval.endedAt), interval.startedAt)
        }
    }

    @MainActor func testFailedWriteDoesNotCommitTimingBoundary() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        store.start(day: day(), date: date(1000))
        let before = store.archive
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store.selectExercise(1, date: date(1010))
        XCTAssertEqual(store.archive, before)
        XCTAssertNotNil(store.errorMessage)
    }

    func testInvalidOverlappingOrNegativeClosedIntervalsAreRejected() {
        var session = WorkoutSession(day: day(), date: date(1000))
        let id = session.exercises[0].id
        session.timing = WorkoutTiming(trackedFrom: date(1000), intervals: [
            WorkoutTimingInterval(kind: .exercise, exerciseID: id, startedAt: date(1000), endedAt: date(1010)),
            WorkoutTimingInterval(kind: .exercise, exerciseID: id, startedAt: date(1009))
        ])
        XCTAssertFalse(session.timing!.isValid(for: session))
        session.timing?.intervals = [WorkoutTimingInterval(kind: .exercise, exerciseID: id, startedAt: date(1000), endedAt: date(999.9))]
        XCTAssertFalse(session.timing!.isValid(for: session))
        session.timing?.intervals = [WorkoutTimingInterval(kind: .rest, exerciseID: id, restKind: .betweenSets,
                                                       startedAt: date(1000), endedAt: date(1020), restDeadline: date(1010))]
        XCTAssertFalse(session.timing!.isValid(for: session))
    }

    @MainActor func testDiscardDoesNotAddTimingOrWorkoutToHistory() async {
        let store = WorkoutStore(fileURL: location())
        store.start(day: day(), date: date(1000))
        XCTAssertTrue(store.discardActive(date: date(1010)))
        XCTAssertNil(store.archive.active)
        XCTAssertTrue(store.archive.history.isEmpty)
    }
    func testWireZeroLengthBoundariesAreAcceptedWithoutAddingMeasuredTime() throws {
        var session = WorkoutSession(day: day(), date: date(1000))
        session.finishedAt = date(1010)
        let id = session.exercises[0].id
        session.timing = WorkoutTiming(trackedFrom: date(1000), intervals: [
            WorkoutTimingInterval(kind: .exercise, exerciseID: id, startedAt: date(1000), endedAt: date(1000)),
            WorkoutTimingInterval(kind: .rest, exerciseID: id, restKind: .betweenSets,
                                 startedAt: date(1000), endedAt: date(1000), restDeadline: date(1000)),
            WorkoutTimingInterval(kind: .other, startedAt: date(1000), endedAt: date(1010))
        ])
        let decoded = try JSONDecoder().decode(WorkoutSession.self, from: JSONEncoder().encode(session))
        XCTAssertTrue(try XCTUnwrap(decoded.timing).isValid(for: decoded))
        let totals = try XCTUnwrap(decoded.timingTotals())
        XCTAssertEqual(totals.exerciseSeconds, 0)
        XCTAssertEqual(totals.restSeconds, 0)
        XCTAssertEqual(totals.otherSeconds, 10)
        XCTAssertEqual(totals.untrackedSeconds, 0)
    }

    @MainActor func testLegacyFirstInputOrRestStopDoesNotBackfillTimeBeforeUpgrade() async throws {
        for stop in [false, true] {
            let url = location()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var archive = TrainingArchive()
            archive.version = 2
            archive.active = WorkoutSession(day: day(), date: date(1000))
            archive.restUntil = date(1200)
            try JSONEncoder().encode(archive).write(to: url)
            let store = WorkoutStore(fileURL: url)
            let exercise = try XCTUnwrap(store.archive.active?.exercises[0])
            if stop { store.stopRest(date: date(1100)) }
            else { store.updateSet(exerciseID: exercise.id, setID: exercise.sets[0].id, reps: "8", date: date(1100)) }
            let totals = try XCTUnwrap(store.archive.active?.timingTotals(at: date(1120)))
            XCTAssertEqual(store.archive.active?.timing?.trackedFrom, date(1100))
            XCTAssertEqual(totals.untrackedSeconds, 100)
            XCTAssertEqual(totals.restSeconds, stop ? 0 : 20)
            XCTAssertEqual(totals.exerciseSeconds, stop ? 20 : 0)
        }
    }

    @MainActor func testInvalidRemoteTimingCannotPoisonSavedHistory() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        store.start(day: day(), date: date(1000))
        let before = store.archive
        let bytes = try Data(contentsOf: url)
        var incoming = WorkoutSession(day: day(), date: date(500))
        incoming.finishedAt = date(600)
        incoming.exercises[0].sets[0].isCompleted = true
        incoming.exercises[0].sets[0].reps = "10"
        incoming.exercises[0].sets[0].weight = "60"
        incoming.timing = WorkoutTiming(version: 2, trackedFrom: date(500))
        XCTAssertFalse(store.mergeHistory([incoming]))
        XCTAssertEqual(store.archive, before)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(WorkoutStore(fileURL: url).loadFailed)
    }

}
