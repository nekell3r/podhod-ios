import XCTest
@testable import PodhodCore

final class WorkoutProgressTests: XCTestCase {
    private func date(_ day: String, calendar: TrainingCalendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: day))
    }

    private func session(at date: Date, exercise: Exercise = Exercise.catalog[0], sets: [LoggedSet]? = nil) -> WorkoutSession {
        let performed = sets ?? [LoggedSet(reps: "10", weight: "50", isCompleted: true)]
        var session = WorkoutSession(day: TrainingDay(weekday: 1, title: "Progress fixture",
            exercises: [PlannedExercise(exercise: exercise, setCount: performed.count)]), date: date)
        session.exercises[0].sets = performed
        session.finishedAt = date.addingTimeInterval(600)
        return session
    }

    func testWeekUsesCalendarDatesAndDisjointPreviousPeriod() throws {
        let calendar = TrainingCalendar(timezone: "Europe/Moscow")
        let history = try ["2026-10-18", "2026-10-24", "2026-10-25", "2026-10-31", "2026-11-01"].map {
            session(at: try date($0, calendar: calendar))
        }
        var active = session(at: try date("2026-10-30", calendar: calendar))
        active.finishedAt = nil
        let report = WorkoutProgressReport(history: history + [active], period: .week, calendar: calendar,
            now: try date("2026-10-31", calendar: calendar).addingTimeInterval(43_200))
        XCTAssertEqual(report.interval?.start, try date("2026-10-25", calendar: calendar))
        XCTAssertEqual(report.interval?.end, try date("2026-11-01", calendar: calendar))
        XCTAssertEqual(report.previousInterval?.start, try date("2026-10-18", calendar: calendar))
        XCTAssertEqual(report.current.sessions.map(\.id), [history[3].id, history[2].id])
        XCTAssertEqual(report.previous?.sessions.map(\.id), [history[1].id, history[0].id])
        XCTAssertEqual(report.current.completedSets, 2)
        XCTAssertEqual(report.current.repetitions, 20)
        XCTAssertEqual(report.current.volume, 1_000)
    }

    func testPeriodsFollowDSTAndCrossYearBoundaries() throws {
        let calendar = TrainingCalendar(timezone: "America/New_York")
        let report = WorkoutProgressReport(history: [], period: .week, calendar: calendar,
            now: try date("2026-11-02", calendar: calendar).addingTimeInterval(43_200))
        XCTAssertEqual(report.interval?.start, try date("2026-10-27", calendar: calendar))
        XCTAssertEqual(report.interval?.end, try date("2026-11-03", calendar: calendar))
        XCTAssertEqual(report.interval?.duration, 169 * 3_600)
        XCTAssertEqual(report.previousInterval?.duration, 168 * 3_600)
        let month = WorkoutProgressReport(history: [], period: .month, calendar: calendar,
            now: try date("2027-01-05", calendar: calendar))
        XCTAssertEqual(month.interval?.start, try date("2026-12-07", calendar: calendar))
        XCTAssertEqual(month.interval?.end, try date("2027-01-06", calendar: calendar))
        XCTAssertEqual(month.previousInterval?.start, try date("2026-11-07", calendar: calendar))
    }

    func testAllTimeRetainsFinishedHistoryWithClockAheadAndRejectsInvalidBounds() {
        let now = Date(timeIntervalSince1970: 10_000)
        let past = session(at: now.addingTimeInterval(-1_000))
        let ahead = session(at: now.addingTimeInterval(3_600))
        var invalid = session(at: now)
        invalid.finishedAt = now.addingTimeInterval(-1)
        let report = WorkoutProgressReport(history: [past, ahead, invalid], period: .allTime,
            calendar: TrainingCalendar(timezone: "UTC"), now: now)
        XCTAssertEqual(report.current.sessions.map(\.id), [ahead.id, past.id])
        XCTAssertNil(report.interval)
        XCTAssertNil(report.previous)
        XCTAssertNil(report.previousInterval)
    }

    func testSummaryExcludesDraftAndInvalidSetNumbersWithoutInventingBodyweightVolume() {
        let workout = session(at: Date(timeIntervalSince1970: 1_000), sets: [
            LoggedSet(reps: "12", weight: "0", isCompleted: true, repsInReserve: .fiveOrMore),
            LoggedSet(reps: "8", weight: "60,5", isCompleted: true),
            LoggedSet(reps: "99", weight: "999", isCompleted: false),
            LoggedSet(reps: "10", weight: "nan", isCompleted: true),
            LoggedSet(reps: "0", weight: "100", isCompleted: true)
        ])
        let totals = WorkoutProgressSummary(sessions: [workout])
        XCTAssertEqual(totals.completedSets, 2)
        XCTAssertEqual(totals.repetitions, 20)
        XCTAssertEqual(totals.volume, 484)
        XCTAssertEqual(totals.bodyweightSets, 1)
        XCTAssertEqual(totals.elapsedSeconds, 600)
        XCTAssertEqual(totals.untrackedSeconds, 600)
        XCTAssertEqual(totals.exerciseSeconds, 0)
        let progress = WorkoutExerciseProgress(sessions: [workout], exercise: workout.exercises[0].exercise)
        XCTAssertEqual(progress.records.count, 2)
        XCTAssertEqual(progress.points.first?.weight, 60.5)
        XCTAssertEqual(progress.points.first?.repetitions, 12)
        XCTAssertEqual(progress.points.first?.volume, 484)
        XCTAssertEqual(progress.points.first?.minimumReserve, 5)
        XCTAssertEqual(progress.points.first?.assessedSets, 1)
    }

    func testAliasesCombinePointsWhileRecordsKeepTheirOriginalNotesAndSetIDs() throws {
        let catalog = ExerciseCatalog.bundled
        let alias = try XCTUnwrap(catalog.exerciseIDAliases.first)
        var canonical = try XCTUnwrap(catalog.entry(for: alias.exerciseID)?.exercise)
        canonical.cue = "Canonical snapshot note"
        var old = canonical
        old.id = alias.id
        old.cue = "Legacy snapshot note"
        var workout = session(at: Date(timeIntervalSince1970: 1_000), exercise: canonical)
        let oldItem = SessionExercise(exercise: old, targetReps: "8", restSeconds: 90,
            sets: [LoggedSet(reps: "8", weight: "70", isCompleted: true)])
        var similarName = canonical
        similarName.id = UUID()
        workout.exercises.append(oldItem)
        workout.exercises.append(SessionExercise(exercise: similarName, targetReps: "10", restSeconds: 90,
            sets: [LoggedSet(reps: "10", weight: "999", isCompleted: true)]))
        let result = WorkoutExerciseProgress(sessions: [workout], exercise: canonical)
        XCTAssertEqual(result.points.count, 1)
        XCTAssertEqual(result.points[0].volume, 1_060)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.map { $0.exercise.exercise.cue }, ["Canonical snapshot note", "Legacy snapshot note"])
        XCTAssertEqual(result.bestWeight?.id, oldItem.sets[0].id)
        XCTAssertEqual(result.bestWeight?.exercise.exercise.id, alias.id)
        XCTAssertEqual(result.bestWeight?.session, workout)
    }

    func testRecordsUseExplicitMetricsAndRetainWeightRepetitionsAndEffortContext() {
        let start = Date(timeIntervalSince1970: 1_000)
        let first = session(at: start, sets: [LoggedSet(reps: "3", weight: "100", isCompleted: true, repsInReserve: .one)])
        let volume = session(at: start.addingTimeInterval(1_000), sets: [LoggedSet(reps: "12", weight: "80", isCompleted: true, repsInReserve: .two)])
        let repetitions = session(at: start.addingTimeInterval(2_000), sets: [LoggedSet(reps: "20", weight: "0", isCompleted: true)])
        let heavierReps = session(at: start.addingTimeInterval(3_000), sets: [LoggedSet(reps: "5", weight: "100", isCompleted: true)])
        let result = WorkoutExerciseProgress(sessions: [heavierReps, first, repetitions, volume], exercise: first.exercises[0].exercise)
        XCTAssertEqual(result.bestWeight?.session.id, heavierReps.id)
        XCTAssertEqual(result.bestRepetitions?.session.id, repetitions.id)
        XCTAssertEqual(result.bestSetVolume?.session.id, volume.id)
        XCTAssertEqual(result.bestSetVolume?.set.repsInReserve, .two)
        XCTAssertEqual(result.points.map(\.session.id), [first.id, volume.id, repetitions.id, heavierReps.id])
        let bodyweight = WorkoutExerciseProgress(sessions: [repetitions], exercise: repetitions.exercises[0].exercise)
        XCTAssertNil(bodyweight.bestWeight)
        XCTAssertNil(bodyweight.bestSetVolume)
        XCTAssertEqual(bodyweight.bestRepetitions?.set.repValue, 20)
    }

    func testReserveDistinguishesUnknownFailureAndCensoredUpperCategory() {
        let start = Date(timeIntervalSince1970: 1_000)
        let unknown = session(at: start, sets: [LoggedSet(reps: "10", weight: "60", isCompleted: true, repsInReserve: .notRecorded)])
        let fivePlus = session(at: start.addingTimeInterval(1_000), sets: [LoggedSet(reps: "10", weight: "60", isCompleted: true, repsInReserve: .fiveOrMore)])
        let failure = session(at: start.addingTimeInterval(2_000), sets: [
            LoggedSet(reps: "10", weight: "60", isCompleted: true, repsInReserve: .four),
            LoggedSet(reps: "8", weight: "60", isCompleted: true, repsInReserve: .failure),
            LoggedSet(reps: "12", weight: "60", isCompleted: true)
        ])
        let result = WorkoutExerciseProgress(sessions: [unknown, fivePlus, failure], exercise: unknown.exercises[0].exercise)
        XCTAssertNil(ExerciseProgressMetric.reserve.value(in: result.points[0]))
        XCTAssertEqual(ExerciseProgressMetric.reserve.value(in: result.points[1]), 5)
        XCTAssertEqual(ExerciseProgressMetric.reserve.value(in: result.points[2]), 0)
        XCTAssertEqual(result.points.map(\.assessedSets), [0, 1, 2])
    }

    func testTimingSummaryKeepsMeasuredGapsAndLegacyDurationUnknown() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var measured = session(at: start)
        let exerciseID = measured.exercises[0].id
        measured.timing = WorkoutTiming(trackedFrom: start.addingTimeInterval(100), intervals: [
            WorkoutTimingInterval(kind: .exercise, exerciseID: exerciseID,
                startedAt: start.addingTimeInterval(100), endedAt: start.addingTimeInterval(400)),
            WorkoutTimingInterval(kind: .rest, exerciseID: exerciseID, restKind: .betweenSets,
                startedAt: start.addingTimeInterval(400), endedAt: start.addingTimeInterval(500), restDeadline: start.addingTimeInterval(500)),
            WorkoutTimingInterval(kind: .other,
                startedAt: start.addingTimeInterval(500), endedAt: start.addingTimeInterval(550))
        ])
        XCTAssertTrue(try XCTUnwrap(measured.timing).isValid(for: measured))
        let legacy = session(at: start.addingTimeInterval(1_000))
        let totals = WorkoutProgressSummary(sessions: [legacy, measured])
        XCTAssertEqual(totals.elapsedSeconds, 1_200)
        XCTAssertEqual(totals.exerciseSeconds, 300)
        XCTAssertEqual(totals.restSeconds, 100)
        XCTAssertEqual(totals.otherSeconds, 50)
        XCTAssertEqual(totals.untrackedSeconds, 750)
        XCTAssertEqual(totals.exerciseSeconds + totals.restSeconds + totals.otherSeconds + totals.untrackedSeconds, totals.elapsedSeconds)
    }
}
