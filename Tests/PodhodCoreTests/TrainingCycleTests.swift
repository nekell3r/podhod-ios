import XCTest
@testable import PodhodCore

final class TrainingCycleTests: XCTestCase {
    private let calendar = TrainingCalendar(timezone: "Europe/Moscow")

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CycleQA-\(UUID())/training.json")
    }

    private func template(sets: Int = 3) -> [TrainingDay] {
        var days = TrainingDay.initialWeek()
        days[0] = TrainingDay(weekday: 1, title: "Цикл", exercises: [
            PlannedExercise(exercise: Exercise.catalog[0], setCount: sets),
            PlannedExercise(exercise: Exercise.catalog[2], setCount: sets)
        ])
        days[0].context = WorkoutPlanContext(variant: "A", loadType: .heavy, difficulty: .moderate)
        days[0].supersets = [PlannedSuperset(exerciseIDs: days[0].exercises.map(\.id), restSeconds: 90)]
        return days
    }

    private func plan(count: Int = 4, repeats: Bool = false, generation: CycleGeneration = .repeatingTemplate) throws -> TrainingCyclePlan {
        try TrainingCyclePlan.generated(template: template(), startWeek: "2026-11-02", timezone: calendar.calendar.timeZone.identifier,
                                        count: count, repeats: repeats, generation: generation)
    }

    func testCycleDateBoundariesRepeatingAndMissedWeeksUseCalendar() throws {
        let cycle = try plan()
        XCTAssertNil(cycle.phase(containing: calendar.date(from: "2026-11-01")!, calendar: calendar))
        XCTAssertEqual(cycle.phase(containing: calendar.date(from: "2026-11-08")!, calendar: calendar)?.index, 0)
        XCTAssertEqual(cycle.phase(containing: calendar.date(from: "2026-11-23")!, calendar: calendar)?.index, 3)
        XCTAssertNil(cycle.phase(containing: calendar.date(from: "2026-11-30")!, calendar: calendar))
        var repeated = cycle
        repeated.repeats = true
        XCTAssertEqual(repeated.phase(containing: calendar.date(from: "2026-12-07")!, calendar: calendar)?.index, 1)
        XCTAssertEqual(repeated.template(containing: calendar.date(from: "2026-12-07")!, calendar: calendar)?[0].context?.cycle?.weekNumber, 2)
    }

    func testDSTDoesNotShiftCyclePhases() throws {
        let calendar = TrainingCalendar(timezone: "America/New_York")
        let cycle = try TrainingCyclePlan.generated(template: template(), startWeek: "2026-10-26", timezone: "America/New_York",
            count: 4, repeats: false, generation: .repeatingTemplate)
        XCTAssertEqual(cycle.phase(containing: calendar.date(from: "2026-11-02")!, calendar: calendar)?.index, 1)
        XCTAssertEqual(cycle.phase(containing: calendar.date(from: "2026-11-16")!, calendar: calendar)?.index, 3)
    }

    func testVolumeWaveIsBoundedPreservesSupersetCountsAndDoesNotInventResults() throws {
        let cycle = try plan(count: 6, generation: .volumeWave)
        XCTAssertEqual(cycle.weeks.map { $0.days[0].exercises[0].setCount }, [3, 4, 3, 2, 3, 2])
        XCTAssertEqual(cycle.weeks.map { $0.days[0].context?.loadType }, [.regular, .heavy, .regular, .deload, .regular, .deload])
        XCTAssertTrue(cycle.isValid)
        for sets in [1, 12] {
            let bounded = try TrainingCyclePlan.generated(template: template(sets: sets), startWeek: "2026-11-02", timezone: "UTC",
                count: 4, repeats: false, generation: .volumeWave)
            XCTAssertTrue(bounded.weeks.flatMap(\.days).flatMap(\.exercises).allSatisfy { (1...12).contains($0.setCount) })
            XCTAssertTrue(bounded.isValid)
        }
        let session = WorkoutSession(day: cycle.weeks[1].days[0])
        XCTAssertTrue(session.exercises.flatMap(\.sets).allSatisfy { $0.reps.isEmpty && $0.weight.isEmpty && !$0.isCompleted && $0.repsInReserve == nil })
    }

    func testCycleValidationRejectsInvalidBoundsAndMaterializedSource() throws {
        for count in [0, 1, 13] { XCTAssertThrowsError(try plan(count: count)) }
        XCTAssertThrowsError(try plan(count: 3, generation: .volumeWave))
        var cycle = try plan()
        cycle.startWeek = "2026-11-03"
        XCTAssertFalse(cycle.isValid)
        cycle.startWeek = "2026-11-02"
        let reference = CycleWeekReference(cycleID: cycle.id, weekID: cycle.weeks[0].id, weekNumber: 1)
        cycle.weeks[0].days[0].context?.cycle = reference
        XCTAssertFalse(cycle.isValid)
        cycle = try plan()
        cycle.timezone = "Local"
        XCTAssertFalse(cycle.isValid)
        cycle = try plan()
        cycle.startWeek = "9999-12-27"
        XCTAssertFalse(cycle.isValid)
    }

    @MainActor func testCycleOnlyAffectsNewWeeksAndKeepsSessionAndHistorySnapshots() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        let monday = store.trainingCalendar.date(from: "2026-11-02")!
        XCTAssertTrue(store.replaceTemplate(template()))
        XCTAssertTrue(store.ensureWeek(containing: monday))
        let original = store.scheduledWeek(containing: monday)
        XCTAssertTrue(store.startScheduled(on: monday, startedAt: monday))
        let active = try XCTUnwrap(store.archive.active)
        let first = active.exercises[0]
        store.updateSet(exerciseID: first.id, setID: first.sets[0].id, reps: "8", weight: "20", date: monday)
        XCTAssertTrue(store.toggleSet(exerciseID: first.id, setID: first.sets[0].id, date: monday))
        XCTAssertTrue(store.finish(allowPartial: true, date: monday.addingTimeInterval(60)))
        let history = store.archive.history
        XCTAssertTrue(store.saveTrainingCycle(try plan(generation: .volumeWave), expected: store.cycleState.document))
        XCTAssertEqual(store.scheduledWeek(containing: monday), original)
        XCTAssertEqual(store.archive.history, history)
        let secondMonday = store.trainingCalendar.date(from: "2026-11-09")!
        XCTAssertTrue(store.ensureWeek(containing: secondMonday))
        let second = store.scheduledWeek(containing: secondMonday)
        XCTAssertEqual(second.workouts[0].exercises[0].setCount, 4)
        XCTAssertEqual(second.workouts[0].context?.cycle?.weekNumber, 2)
        XCTAssertTrue(store.startScheduled(on: secondMonday, startedAt: secondMonday))
        let snapshot = store.archive.active
        XCTAssertTrue(store.saveTrainingCycle(nil, expected: store.cycleState.document))
        XCTAssertEqual(store.archive.active, snapshot)
        XCTAssertEqual(store.scheduledWeek(containing: secondMonday), second)
        let restored = WorkoutStore(fileURL: url)
        XCTAssertFalse(restored.loadFailed)
        XCTAssertEqual(restored.archive.history, history)
        XCTAssertEqual(restored.archive.active, snapshot)
        XCTAssertNil(restored.cycleState.document.plan)
        XCTAssertNotNil(restored.cycleState.pending)
    }

    @MainActor func testV5MigrationBacksUpExactBytesAndKeepsRemovalIntents() async throws {
        let url = location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var archive = TrainingArchive()
        archive.version = 5
        archive.active = WorkoutSession(day: template()[0])
        let removed = UUID()
        archive.setRemovalIntents = [SetRemovalIntent(sessionID: archive.active!.id, setID: removed)]
        archive.active?.exercises[0].sets[0].repsInReserve = .failure
        let data = try JSONEncoder().encode(archive)
        try data.write(to: url)
        let store = WorkoutStore(fileURL: url)
        XCTAssertFalse(store.loadFailed)
        XCTAssertTrue(store.saveTrainingCycle(try plan(), expected: store.cycleState.document))
        XCTAssertEqual(store.archive.version, 6)
        XCTAssertEqual(store.archive.setRemovalIntents, archive.setRemovalIntents)
        XCTAssertEqual(store.archive.active, archive.active)
        XCTAssertEqual(try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("training-v5-backup.json")), data)
    }

    @MainActor func testCyclePendingSurvivesRestartEditsConflictAndOldReceipt() async throws {
        let url = location()
        let store = WorkoutStore(fileURL: url)
        XCTAssertTrue(store.saveTrainingCycle(try plan(), expected: store.cycleState.document))
        let pending = try XCTUnwrap(store.cycleState.pending)
        var changed = try plan()
        changed.repeats = true
        XCTAssertTrue(store.saveTrainingCycle(changed, expected: store.cycleState.document))
        var state = WorkoutStore(fileURL: url).cycleState
        XCTAssertEqual(state.pending, pending)
        try state.acknowledge(requestID: pending.requestID, record: .init(revision: 1, document: pending.document))
        XCTAssertEqual(state.pending?.expectedRevision, 1)
        let next = try XCTUnwrap(state.pending)
        let remote = RevisionedDocumentRecord(revision: Int64(3), document: TrainingCycleDocument())
        try state.reject(requestID: next.requestID, remote: remote)
        XCTAssertTrue(store.saveCycleState(state))
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().appendingPathComponent("Conflicts").path)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(WorkoutStore(fileURL: url).cycleState.conflict, remote)
        try state.acknowledge(requestID: next.requestID, record: .init(revision: 2, document: next.document))
        XCTAssertEqual(state.conflict, remote)
        try state.resolve(usingServer: true, expected: remote)
        XCTAssertNil(state.document.plan)
        XCTAssertNil(state.pending)
        XCTAssertTrue(store.saveCycleState(state))
    }

    func testLegacySerializationOmitsStructureAndClearCycleUsesExplicitNull() throws {
        let day = TrainingDay.exampleWeek()[0]
        let session = WorkoutSession(day: day)
        let encoded = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        XCTAssertFalse(encoded.contains("structureVersion"))
        XCTAssertFalse(encoded.contains("supersets"))
        XCTAssertFalse(encoded.contains("context"))
        let cleared = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TrainingCycleDocument())) as! [String: Any]
        XCTAssertTrue(cleared["plan"] is NSNull)
    }

    @MainActor func testCycleDayEditPreservesOtherPhasesAndRejectsStaleDraft() async throws {
        let store = WorkoutStore(fileURL: location())
        let cycle = try plan()
        XCTAssertTrue(store.saveTrainingCycle(cycle, expected: store.cycleState.document))
        let original = cycle.weeks[0].days[0]
        var changed = original
        changed.context?.loadType = .light
        XCTAssertTrue(store.saveCycleDay(changed, cycleID: cycle.id, weekID: cycle.weeks[0].id, expected: original))
        XCTAssertEqual(store.cycleState.document.plan?.weeks[1], cycle.weeks[1])
        XCTAssertEqual(store.cycleState.document.plan?.weeks[0].days[0], changed)
        XCTAssertFalse(store.saveCycleDay(original, cycleID: cycle.id, weekID: cycle.weeks[0].id, expected: original))
        XCTAssertEqual(store.cycleState.document.plan?.weeks[0].days[0], changed)
    }

    @MainActor func testTemplateBoundaryRejectsBrokenGroupsAndKeepsSupportMarkerAfterClear() async throws {
        let store = WorkoutStore(fileURL: location())
        let valid = template()
        XCTAssertTrue(store.replaceTemplate(valid))
        let previous = store.archive
        var invalid = valid
        invalid[0].exercises[1].setCount = 4
        XCTAssertFalse(store.replaceTemplate(invalid, structureVersion: 1))
        XCTAssertEqual(store.archive, previous)
        invalid = valid
        invalid[0].context?.cycle = CycleWeekReference(cycleID: UUID(), weekID: UUID(), weekNumber: 1)
        XCTAssertFalse(store.replaceTemplate(invalid, structureVersion: 1))
        XCTAssertEqual(store.archive, previous)
        XCTAssertTrue(store.replaceTemplate(TrainingDay.initialWeek(), structureVersion: 1))
        XCTAssertEqual(store.archive.templateStructureVersion, 1)
        XCTAssertTrue(WorkoutStore(fileURL: store.fileURL).archive.hasValidStructure)
    }
}
