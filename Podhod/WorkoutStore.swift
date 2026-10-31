import Foundation
import Observation

@MainActor @Observable
final class WorkoutStore {
    private(set) var archive: TrainingArchive
    var errorMessage: String?
    private(set) var loadFailed = false
    @ObservationIgnored let fileURL: URL
    @ObservationIgnored private var migrationSourceVersion: Int?
    @ObservationIgnored var accountStorageError: String?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? URL.applicationSupportDirectory
            .appending(path: "Podhod", directoryHint: .isDirectory)
            .appending(path: "training.json")
        archive = TrainingArchive()
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                let data = try Data(contentsOf: self.fileURL)
                var loaded = try JSONDecoder().decode(TrainingArchive.self, from: data)
                guard (1...6).contains(loaded.version) else { throw TrainingError.unsupportedArchive }
                guard loaded.week.map(\.weekday).sorted() == Array(1...7),
                      loaded.week.allSatisfy({ $0.exercises.allSatisfy { (1...12).contains($0.setCount) } }),
                      loaded.active.map({ !$0.exercises.isEmpty && $0.exercises.indices.contains($0.currentExercise) }) ?? true
                else { throw TrainingError.invalidArchive }
                guard loaded.active.map({ session in session.timing?.isValid(for: session) ?? true }) ?? true,
                      loaded.history.allSatisfy({ $0.timing?.isValid(for: $0) ?? true }),
                      loaded.hasValidSetRemovalIntents, loaded.hasValidStructure else { throw TrainingError.invalidArchive }
                migrationSourceVersion = loaded.version < 6 ? loaded.version : nil
                loaded.version = 6
                archive = loaded
            }
        } catch {
            loadFailed = true
            errorMessage = "Не удалось прочитать сохранение: \(error.localizedDescription) Данные не перезаписаны. Файл: \(self.fileURL.path)"
        }
    }

    var exerciseLibrary: [Exercise] {
        let catalog = ExerciseCatalog.bundled
        var seen: Set<UUID> = []
        var saved = archive.week.flatMap(\.exercises).map(\.exercise)
        saved += (archive.trainingCycle?.document.plan?.weeks ?? []).flatMap(\.days).flatMap(\.exercises).map(\.exercise)
        saved += (archive.scheduledWeeks ?? []).flatMap(\.workouts).flatMap(\.exercises).map(\.exercise)
        saved += (archive.active?.exercises ?? []).map(\.exercise)
        saved += archive.history.flatMap(\.exercises).map(\.exercise)
        return catalog.exercises.map(\.exercise) + saved.filter {
            catalog.entry(for: $0.id) == nil && seen.insert($0.id).inserted
        }
    }

    var trainingCalendar: TrainingCalendar { TrainingCalendar(timezone: archive.timezone ?? TimeZone.current.identifier) }

    var today: TrainingDay { scheduledWeek(containing: Date()).day(on: Date(), calendar: trainingCalendar) }

    var cycleState: RevisionedDocumentState<TrainingCycleDocument> {
        archive.trainingCycle ?? RevisionedDocumentState(document: TrainingCycleDocument())
    }

    @discardableResult
    func saveTrainingCycle(_ plan: TrainingCyclePlan?, expected: TrainingCycleDocument) -> Bool {
        guard cycleState.document == expected else {
            errorMessage = TrainingError.staleProgramEdit.localizedDescription
            return false
        }
        let document = TrainingCycleDocument(plan: plan)
        guard document.isValid else {
            errorMessage = TrainingError.invalidCycle.localizedDescription
            return false
        }
        var state = cycleState
        state.edit(document)
        state.commitFirstWrite()
        return saveCycleState(state)
    }

    @discardableResult
    func saveCycleDay(_ day: TrainingDay, cycleID: UUID, weekID: UUID, expected: TrainingDay) -> Bool {
        guard var plan = cycleState.document.plan, plan.id == cycleID,
              let week = plan.weeks.firstIndex(where: { $0.id == weekID }),
              let index = plan.weeks[week].days.firstIndex(where: { $0.weekday == day.weekday }),
              plan.weeks[week].days[index] == expected else {
            errorMessage = TrainingError.staleProgramEdit.localizedDescription
            return false
        }
        plan.weeks[week].days[index] = day
        return saveTrainingCycle(plan, expected: cycleState.document)
    }

    @discardableResult
    func saveCycleState(_ state: RevisionedDocumentState<TrainingCycleDocument>) -> Bool {
        guard state.isValid(documentIsValid: { $0.isValid }) else {
            errorMessage = TrainingError.invalidCycle.localizedDescription
            return false
        }
        if state == archive.trainingCycle { return true }
        if let conflict = state.conflict, conflict != archive.trainingCycle?.conflict {
            do { try backupCycleConflict(remote: conflict) }
            catch {
                errorMessage = "Не удалось сохранить обе версии цикла. Локальные записи не заменены."
                return false
            }
        }
        var changed = archive
        changed.trainingCycle = state
        return save(changed)
    }

    func backupCycleConflict(remote: RevisionedDocumentRecord<TrainingCycleDocument>) throws {
        let directory = fileURL.deletingLastPathComponent().appendingPathComponent("Conflicts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = UUID().uuidString
        try JSONEncoder().encode(archive).write(to: directory.appendingPathComponent("\(prefix)-local.json"), options: .atomic)
        try JSONEncoder().encode(remote).write(to: directory.appendingPathComponent("\(prefix)-cycle-server.json"), options: .atomic)
    }

    @discardableResult
    func pauseTimingForAccountSwitch(date: Date = Date()) -> Bool {
        guard archive.active != nil else { return true }
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        changed.active?.timing?.transition(to: nil, at: now)
        return save(changed)
    }

    func resumeAccountTiming(date: Date = Date()) {
        guard archive.active != nil else { return }
        var changed = archive
        changed.reconcileActiveTiming(at: date)
        if changed != archive { save(changed) }
    }

    func scheduledWeek(containing date: Date) -> TrainingWeek {
        let key = trainingCalendar.dayKey(for: trainingCalendar.weekStart(containing: date))
        return archive.scheduledWeeks?.first { $0.weekStart == key }
            ?? TrainingWeek(containing: date,
                            template: archive.trainingCycle?.document.plan?.template(containing: date, calendar: trainingCalendar) ?? archive.week,
                            calendar: trainingCalendar)
    }

    @discardableResult
    func ensureWeek(containing date: Date) -> Bool {
        let week = scheduledWeek(containing: date)
        if archive.scheduledWeeks?.contains(where: { $0.weekStart == week.weekStart }) == true { return true }
        var changed = archive
        changed.scheduledWeeks = (changed.scheduledWeeks ?? []) + [week]
        if archive.trainingCycle?.document.plan?.phase(containing: date, calendar: trainingCalendar) != nil {
            changed.editedWeekStarts = Array(Set((changed.editedWeekStarts ?? []) + [week.weekStart])).sorted()
        }
        changed.timezone = trainingCalendar.calendar.timeZone.identifier
        return save(changed)
    }

    @discardableResult
    func saveScheduledDay(_ day: TrainingDay, on date: Date, expected: TrainingDay? = nil) -> Bool {
        if let expected, scheduledWeek(containing: date).day(on: date, calendar: trainingCalendar) != expected {
            errorMessage = TrainingError.staleProgramEdit.localizedDescription
            return false
        }
        guard day.hasValidPlannedStructure, day.exercises.allSatisfy({ !$0.exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (1...12).contains($0.setCount) && !$0.targetReps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (0...600).contains($0.restSeconds) && (0...600).contains($0.restAfterExerciseSeconds) }) else {
            errorMessage = TrainingError.invalidProgram.localizedDescription
            return false
        }
        guard ensureWeek(containing: date) else { return false }
        var changed = archive
        let key = trainingCalendar.dayKey(for: date)
        let weekKey = trainingCalendar.dayKey(for: trainingCalendar.weekStart(containing: date))
        guard var weeks = changed.scheduledWeeks,
              let index = weeks.firstIndex(where: { $0.weekStart == weekKey }) else { return false }
        var week = weeks[index]
        let existing = week.workouts.first { $0.plannedDate == key }
        week.workouts.removeAll { $0.plannedDate == key }
        if !day.exercises.isEmpty {
            week.workouts.append(ScheduledWorkout(id: existing?.id ?? UUID(), plannedDate: key, title: day.title,
                exercises: day.exercises, context: day.context, supersets: day.supersets))
        }
        if day.hasStructureMetadata { week.structureVersion = 1 }
        week.workouts.sort { $0.plannedDate < $1.plannedDate }
        weeks[index] = week
        changed.scheduledWeeks = weeks
        changed.editedWeekStarts = Array(Set((changed.editedWeekStarts ?? []) + [weekKey])).sorted()
        return save(changed)
    }

    @discardableResult
    func moveScheduledWorkout(id: UUID, in weekStart: String, to date: Date) -> Bool {
        guard var weeks = archive.scheduledWeeks,
              let index = weeks.firstIndex(where: { $0.weekStart == weekStart }),
              let workoutIndex = weeks[index].workouts.firstIndex(where: { $0.id == id }) else { return false }
        let key = trainingCalendar.dayKey(for: date)
        guard trainingCalendar.dayKey(for: trainingCalendar.weekStart(containing: date)) == weekStart else {
            errorMessage = TrainingError.invalidTrainingDate.localizedDescription
            return false
        }
        guard weeks[index].workouts.allSatisfy({ $0.id == id || $0.plannedDate != key }) else {
            errorMessage = TrainingError.scheduleConflict.localizedDescription
            return false
        }
        var changed = archive
        weeks[index].workouts[workoutIndex].plannedDate = key
        weeks[index].workouts.sort { $0.plannedDate < $1.plannedDate }
        changed.scheduledWeeks = weeks
        changed.editedWeekStarts = Array(Set((changed.editedWeekStarts ?? []) + [weekStart])).sorted()
        return save(changed)
    }

    @discardableResult
    func startScheduled(on date: Date, startedAt: Date = Date()) -> Bool {
        if archive.active != nil { return true }
        guard ensureWeek(containing: date) else { return false }
        let key = trainingCalendar.dayKey(for: date)
        guard let workout = scheduledWeek(containing: date).workouts.first(where: { $0.plannedDate == key }) else {
            errorMessage = TrainingError.emptyDay.localizedDescription
            return false
        }
        var changed = archive
        var session = WorkoutSession(day: workout.day(calendar: trainingCalendar), date: WorkoutTiming.startDate(startedAt))
        session.scheduledWorkoutID = workout.id
        session.plannedDate = key
        changed.active = session
        changed.restUntil = nil
        changed.restKind = nil
        changed.restExerciseID = nil
        changed.reconcileActiveTiming(at: session.startedAt)
        return save(changed)
    }

    @discardableResult
    private func save(_ changed: TrainingArchive) -> Bool {
        guard !loadFailed, accountStorageError == nil else {
            errorMessage = "Сохранение недоступно: исходный файл не удалось прочитать. Данные защищены от перезаписи."
            return false
        }
        guard changed.active?.hasValidStructure ?? true else {
            errorMessage = TrainingError.invalidSuperset.localizedDescription
            return false
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let version = migrationSourceVersion, FileManager.default.fileExists(atPath: fileURL.path) {
                let original = try Data(contentsOf: fileURL)
                var backup = fileURL.deletingLastPathComponent().appendingPathComponent("training-v\(version)-backup.json")
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: backup.path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue { throw CocoaError(.fileWriteFileExists) }
                    if try Data(contentsOf: backup) != original {
                        backup = fileURL.deletingLastPathComponent().appendingPathComponent("training-v\(version)-backup-\(UUID()).json")
                        try original.write(to: backup, options: .atomic)
                    }
                } else {
                    try original.write(to: backup, options: .atomic)
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(changed).write(to: fileURL, options: .atomic)
            archive = changed
            migrationSourceVersion = nil
            return true
        } catch {
            errorMessage = "Не удалось сохранить изменения: \(error.localizedDescription). Повтори действие."
            return false
        }
    }

    @discardableResult
    func saveDay(_ day: TrainingDay, expected: TrainingDay? = nil) -> Bool {
        if let expected, archive.week.first(where: { $0.weekday == day.weekday }) != expected {
            errorMessage = TrainingError.staleProgramEdit.localizedDescription
            return false
        }
        guard day.hasValidPlannedStructure, day.context?.cycle == nil,
              let index = archive.week.firstIndex(where: { $0.weekday == day.weekday }),
              day.exercises.allSatisfy({ !$0.exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  (1...12).contains($0.setCount) && !$0.targetReps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (0...600).contains($0.restSeconds) &&
                  (0...600).contains($0.restAfterExerciseSeconds) }) else {
            errorMessage = TrainingError.invalidProgram.localizedDescription
            return false
        }
        var changed = archive
        changed.week[index] = day
        if day.hasStructureMetadata { changed.templateStructureVersion = 1 }
        return save(changed)
    }

    func loadExample() {
        guard archive.week.allSatisfy({ $0.exercises.isEmpty }),
              (archive.scheduledWeeks ?? []).allSatisfy({ $0.workouts.isEmpty }) else { return }
        var changed = archive
        changed.week = TrainingDay.exampleWeek()
        let currentKey = trainingCalendar.dayKey(for: trainingCalendar.weekStart(containing: Date()))
        if let index = changed.scheduledWeeks?.firstIndex(where: { $0.weekStart == currentKey }) {
            changed.scheduledWeeks?[index] = TrainingWeek(containing: Date(), template: changed.week, calendar: trainingCalendar)
        }
        save(changed)
    }

    @discardableResult
    func start(day: TrainingDay, date: Date = Date()) -> Bool {
        if archive.active != nil { return true }
        guard !day.exercises.isEmpty, day.hasValidPlannedStructure else {
            errorMessage = TrainingError.emptyDay.localizedDescription
            return false
        }
        var changed = archive
        changed.active = WorkoutSession(day: day, date: WorkoutTiming.startDate(date))
        changed.restUntil = nil
        changed.restKind = nil
        changed.restExerciseID = nil
        changed.reconcileActiveTiming(at: WorkoutTiming.startDate(date))
        return save(changed)
    }

    func selectExercise(_ index: Int, date: Date = Date()) {
        guard archive.active?.exercises.indices.contains(index) == true else { return }
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        changed.active?.currentExercise = index
        changed.reconcileActiveTiming(at: now)
        save(changed)
    }

    func updateSet(exerciseID: UUID, setID: UUID, reps: String? = nil, weight: String? = nil, date: Date = Date()) {
        guard let session = archive.active,
              let e = session.exercises.firstIndex(where: { $0.id == exerciseID }),
              let s = session.exercises[e].sets.firstIndex(where: { $0.id == setID }),
              !session.exercises[e].sets[s].isCompleted,
              !session.exercises[e].isSkipped else { return }
        var changed = archive
        changed.reconcileActiveTiming(at: date)
        if let reps { changed.active?.exercises[e].sets[s].reps = reps }
        if let weight { changed.active?.exercises[e].sets[s].weight = weight }
        save(changed)
    }

    @discardableResult
    func addActiveExercise(sessionID: UUID, plan: PlannedExercise, date: Date = Date()) -> Bool {
        guard let session = archive.active, session.id == sessionID else {
            errorMessage = TrainingError.staleWorkoutEdit.localizedDescription
            return false
        }
        guard session.exercises.count < 50 else {
            errorMessage = "В тренировке может быть не больше 50 упражнений, включая пропущенные."
            return false
        }
        guard !plan.exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...12).contains(plan.setCount), !plan.targetReps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (0...600).contains(plan.restSeconds), (0...600).contains(plan.restAfterExerciseSeconds) else {
            errorMessage = TrainingError.invalidProgram.localizedDescription
            return false
        }
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        changed.active?.exercises.append(SessionExercise(exercise: plan.exercise, targetReps: plan.targetReps,
            restSeconds: plan.restSeconds, restAfterExerciseSeconds: plan.restAfterExerciseSeconds,
            sets: (0..<plan.setCount).map { _ in LoggedSet() }))
        changed.reconcileActiveTiming(at: now)
        return save(changed)
    }

    @discardableResult
    func replaceActiveExercise(sessionID: UUID, original: SessionExercise, with exercise: Exercise, date: Date = Date()) -> Bool {
        guard let session = archive.active, session.id == sessionID,
              let index = session.exercises.firstIndex(where: { $0.id == original.id }),
              session.exercises[index] == original, !original.isResolved else {
            errorMessage = TrainingError.staleWorkoutEdit.localizedDescription
            return false
        }
        guard session.exercises.count < 50 else {
            errorMessage = "Для замены нужна новая карточка. В тренировке уже 50 упражнений."
            return false
        }
        let catalog = ExerciseCatalog.bundled
        guard (catalog.entry(for: original.exercise.id)?.id ?? original.exercise.id) !=
                (catalog.entry(for: exercise.id)?.id ?? exercise.id),
              !exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let remaining = original.sets.filter { !$0.isCompleted }.count
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        if let deadline = changed.restUntil, deadline > now, changed.restExerciseID == nil {
            changed.restExerciseID = session.exercises[session.currentExercise].id
        }
        changed.active?.exercises[index].isSkipped = true
        let replacement = SessionExercise(exercise: exercise, targetReps: original.targetReps,
            restSeconds: original.restSeconds, restAfterExerciseSeconds: original.restAfterExerciseSeconds,
            sets: (0..<remaining).map { _ in LoggedSet() })
        changed.active?.exercises.insert(replacement, at: index + 1)
        changed.active?.remapSupersets(replacing: original, with: replacement)
        changed.active?.currentExercise = index + 1
        changed.reconcileActiveTiming(at: now)
        return save(changed)
    }

    @discardableResult
    func reorderActiveExercises(sessionID: UUID, expectedIDs: [UUID], orderedIDs: [UUID], date: Date = Date()) -> Bool {
        guard let session = archive.active, session.id == sessionID,
              session.exercises.map(\.id) == expectedIDs else {
            errorMessage = TrainingError.staleWorkoutEdit.localizedDescription
            return false
        }
        guard orderedIDs.count == expectedIDs.count, Set(orderedIDs) == Set(expectedIDs),
              Set(orderedIDs).count == orderedIDs.count else { return false }
        if orderedIDs == expectedIDs { return true }
        let selectedID = session.exercises[session.currentExercise].id
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        changed.active?.exercises = orderedIDs.compactMap { id in session.exercises.first { $0.id == id } }
        changed.active?.currentExercise = orderedIDs.firstIndex(of: selectedID) ?? 0
        changed.reconcileActiveTiming(at: now)
        return save(changed)
    }

    @discardableResult
    func addActiveSet(sessionID: UUID, exerciseID: UUID, date: Date = Date()) -> Bool {
        guard let session = archive.active, session.id == sessionID,
              let e = session.exercises.firstIndex(where: { $0.id == exerciseID }),
              !session.exercises[e].isSkipped else { return false }
        guard session.exercises[e].sets.count < 12 else {
            errorMessage = "В одном упражнении может быть не больше 12 подходов."
            return false
        }
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        changed.active?.exercises[e].sets.append(LoggedSet())
        changed.reconcileActiveTiming(at: now)
        return save(changed)
    }

    @discardableResult
    func createActiveSuperset(sessionID: UUID, expectedExercises: [SessionExercise], restSeconds: Int,
                              date: Date = Date()) -> Bool {
        guard let session = archive.active, session.id == sessionID,
              expectedExercises.allSatisfy({ original in session.exercises.first { $0.id == original.id } == original }) else {
            errorMessage = TrainingError.staleWorkoutEdit.localizedDescription
            return false
        }
        let members = expectedExercises.map(\.id)
        let pending = expectedExercises.map { $0.sets.filter { !$0.isCompleted } }
        guard (2...4).contains(members.count), Set(members).count == members.count,
              (0...600).contains(restSeconds), (session.supersets ?? []).count < 50,
              expectedExercises.allSatisfy({ !$0.isSkipped }),
              let count = pending.first?.count, count > 0, pending.allSatisfy({ $0.count == count }),
              (session.supersets ?? []).filter({ !$0.isClosed }).allSatisfy({ Set($0.exerciseIDs).isDisjoint(with: members) })
        else {
            errorMessage = TrainingError.invalidSuperset.localizedDescription
            return false
        }
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        let rounds = (0..<count).map { number in
            SupersetRound(ordinal: number + 1, setIDs: pending.map { $0[number].id })
        }
        changed.active?.structureVersion = 1
        let groups = (changed.active?.supersets ?? []) +
            [SessionSuperset(exerciseIDs: members, restSeconds: restSeconds, rounds: rounds)]
        changed.active?.supersets = groups
        if let current = changed.active?.currentExercise,
           let card = changed.active?.exercises[current], members.contains(card.id),
           let first = members.first, let index = changed.active?.exercises.firstIndex(where: { $0.id == first }) {
            changed.active?.currentExercise = index
        }
        changed.reconcileActiveTiming(at: now)
        return save(changed)
    }

    @discardableResult
    func addSupersetRound(sessionID: UUID, expected: SessionSuperset, date: Date = Date()) -> Bool {
        guard var session = archive.active, session.id == sessionID,
              let index = session.supersets?.firstIndex(where: { $0.id == expected.id }),
              session.supersets?[index] == expected, !expected.isClosed else {
            errorMessage = TrainingError.staleWorkoutEdit.localizedDescription
            return false
        }
        let members = expected.exerciseIDs.compactMap { id in session.exercises.firstIndex { $0.id == id } }
        let available = members.filter { !session.exercises[$0].isSkipped }
        let ordinal = (expected.rounds.last?.ordinal ?? 0) + 1
        guard available.count >= 2, available.allSatisfy({ session.exercises[$0].sets.count < 12 }),
              ordinal <= 600, expected.rounds.count < 600 else {
            errorMessage = "Нельзя добавить круг: нужны два непропущенных участника и место до 12 подходов у каждого."
            return false
        }
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        session.timing = changed.active?.timing
        let slots: [UUID?] = members.map { member in
            guard !session.exercises[member].isSkipped else { return nil }
            let set = LoggedSet()
            session.exercises[member].sets.append(set)
            return set.id
        }
        session.supersets?[index].rounds.append(SupersetRound(ordinal: ordinal, setIDs: slots))
        changed.active = session
        changed.reconcileActiveTiming(at: now)
        return save(changed)
    }

    @discardableResult
    func closeActiveSuperset(sessionID: UUID, expected: SessionSuperset, date: Date = Date()) -> Bool {
        guard archive.active?.id == sessionID,
              archive.active?.supersets?.first(where: { $0.id == expected.id }) == expected, !expected.isClosed else {
            errorMessage = TrainingError.staleWorkoutEdit.localizedDescription
            return false
        }
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        changed.active?.closeSuperset(id: expected.id)
        changed.reconcileActiveTiming(at: now)
        return save(changed)
    }

    @discardableResult
    func removeActiveSet(sessionID: UUID, exerciseID: UUID, setID: UUID, date: Date = Date()) -> Bool {
        guard let session = archive.active, session.id == sessionID,
              let e = session.exercises.firstIndex(where: { $0.id == exerciseID }),
              let s = session.exercises[e].sets.firstIndex(where: { $0.id == setID }),
              !session.exercises[e].isSkipped,
              !session.exercises[e].sets[s].isCompleted,
              session.exercises[e].sets.count > 1 else { return false }
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        var intents = changed.setRemovalIntents ?? []
        let intent = SetRemovalIntent(sessionID: sessionID, setID: setID)
        if !intents.contains(intent) {
            guard intents.filter({ $0.sessionID == sessionID }).count < 600 else {
                errorMessage = "Достигнут предел изменений подходов в этой тренировке. Сохрани выполненное перед новой тренировкой."
                return false
            }
            intents.append(intent)
        }
        changed.active?.exercises[e].sets.remove(at: s)
        changed.active?.removeSupersetLink(setID: setID)
        changed.setRemovalIntents = intents
        changed.reconcileActiveTiming(at: now)
        return save(changed)
    }

    @discardableResult
    func reusePreviousSet(sessionID: UUID, exerciseID: UUID, setID: UUID, date: Date = Date()) -> Bool {
        guard let session = archive.active, session.id == sessionID,
              let e = session.exercises.firstIndex(where: { $0.id == exerciseID }),
              let s = session.exercises[e].sets.firstIndex(where: { $0.id == setID }),
              !session.exercises[e].isSkipped,
              !session.exercises[e].sets[s].isCompleted,
              let previous = previousSet(for: session.exercises[e].exercise, index: s) else { return false }
        let current = session.exercises[e].sets[s]
        let emptyWeight = current.weight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let emptyReps = current.reps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard emptyWeight || emptyReps else { return false }
        var changed = archive
        changed.reconcileActiveTiming(at: date)
        if emptyWeight { changed.active?.exercises[e].sets[s].weight = previous.weight }
        if emptyReps { changed.active?.exercises[e].sets[s].reps = previous.reps }
        return save(changed)
    }

    @discardableResult
    func setRepetitionsInReserve(exerciseID: UUID, setID: UUID, reserve: RepetitionsInReserve) -> Bool {
        guard let session = archive.active,
              let e = session.exercises.firstIndex(where: { $0.id == exerciseID }),
              let s = session.exercises[e].sets.firstIndex(where: { $0.id == setID }),
              !session.exercises[e].isSkipped else { return false }
        var changed = archive
        changed.active?.exercises[e].sets[s].repsInReserve = reserve
        return save(changed)
    }

    @discardableResult
    func toggleSet(exerciseID: UUID, setID: UUID, date: Date = Date()) -> Bool {
        guard var session = archive.active,
              let e = session.exercises.firstIndex(where: { $0.id == exerciseID }),
              let s = session.exercises[e].sets.firstIndex(where: { $0.id == setID }),
              !session.exercises[e].isSkipped else { return false }
        let completing = !session.exercises[e].sets[s].isCompleted
        if !completing && (session.supersets ?? []).contains(where: {
            $0.isClosed && $0.rounds.contains { $0.setIDs.contains(setID) }
        }) {
            errorMessage = "Этот подход сохранён в закрытом круге. Снять выполнение нельзя; оценку запаса можно изменить."
            return false
        }
        if completing && !session.exercises[e].sets[s].isValid {
            errorMessage = TrainingError.invalidSet.localizedDescription
            return false
        }
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        session.timing = changed.active?.timing
        session.exercises[e].sets[s].isCompleted = completing
        if completing, let continuation = session.supersetContinuation(after: setID) {
            if let next = continuation.nextExerciseID, let index = session.exercises.firstIndex(where: { $0.id == next }) {
                session.currentExercise = index
            }
            changed.active = session
            changed.restUntil = continuation.restSeconds > 0 ? now.addingTimeInterval(Double(continuation.restSeconds)) : nil
            changed.restKind = continuation.restSeconds > 0 ? .betweenSets : nil
            changed.restExerciseID = continuation.restSeconds > 0 ? exerciseID : nil
            changed.reconcileActiveTiming(at: now)
            return save(changed)
        }
        changed.active = session
        if completing {
            let completedExercise = session.exercises[e].isCompleted
            let hasNextExercise = session.exercises.indices.contains {
                $0 != e && !session.exercises[$0].isResolved
            }
            let seconds = completedExercise
                ? (hasNextExercise ? session.exercises[e].restAfterExerciseSeconds : 0)
                : session.exercises[e].restSeconds
            changed.restUntil = seconds > 0 ? now.addingTimeInterval(Double(seconds)) : nil
            changed.restKind = seconds > 0 ? (completedExercise ? .betweenExercises : .betweenSets) : nil
            changed.restExerciseID = seconds > 0 ? exerciseID : nil
        } else if changed.restExerciseID == exerciseID || changed.restExerciseID == nil {
            changed.restUntil = nil
            changed.restKind = nil
            changed.restExerciseID = nil
        }
        changed.reconcileActiveTiming(at: now)
        return save(changed)
    }

    @discardableResult
    func setExerciseSkipped(sessionID: UUID, exerciseID: UUID, isSkipped: Bool, date: Date = Date()) -> Bool {
        guard var session = archive.active, session.id == sessionID,
              let e = session.exercises.firstIndex(where: { $0.id == exerciseID }) else { return false }
        if session.exercises[e].isSkipped == isSkipped { return true }
        guard !isSkipped || !session.exercises[e].isCompleted else { return false }
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        session.timing = changed.active?.timing
        session.exercises[e].isSkipped = isSkipped
        if isSkipped { session.closeSupersetsAfterSkip() }
        if isSkipped && session.currentExercise == e {
            let next = session.exercises.indices.dropFirst(e + 1).first { !session.exercises[$0].isResolved }
                ?? session.exercises.indices.prefix(e).first { !session.exercises[$0].isResolved }
            if let next { session.currentExercise = next }
        } else if !isSkipped {
            session.currentExercise = e
        }
        changed.active = session
        if isSkipped && (changed.restExerciseID == exerciseID || changed.restExerciseID == nil) {
            changed.restUntil = nil
            changed.restKind = nil
            changed.restExerciseID = nil
        }
        changed.reconcileActiveTiming(at: now)
        return save(changed)
    }

    @discardableResult
    func updateActiveRest(sessionID: UUID, exerciseID: UUID, restSeconds: Int,
                          restAfterExerciseSeconds: Int, date: Date = Date()) -> Bool {
        guard (0...600).contains(restSeconds), (0...600).contains(restAfterExerciseSeconds) else {
            errorMessage = TrainingError.invalidRest.localizedDescription
            return false
        }
        guard var session = archive.active, session.id == sessionID,
              let e = session.exercises.firstIndex(where: { $0.id == exerciseID }) else { return false }
        var changed = archive
        changed.reconcileActiveTiming(at: date)
        session.timing = changed.active?.timing
        session.exercises[e].restSeconds = restSeconds
        session.exercises[e].restAfterExerciseSeconds = restAfterExerciseSeconds
        changed.active = session
        return save(changed)
    }

    @discardableResult
    func adjustRest(sessionID: UUID, expectedDeadline: Date, seconds: Int, date: Date = Date()) -> Bool {
        guard archive.active?.id == sessionID, archive.restUntil == expectedDeadline,
              seconds != 0, (-600...600).contains(seconds) else { return false }
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        let deadline = max(now, expectedDeadline).addingTimeInterval(Double(seconds))
        guard deadline.timeIntervalSince(now) <= 600 else {
            errorMessage = TrainingError.invalidRest.localizedDescription
            return false
        }
        if deadline > now {
            changed.restUntil = deadline
        } else {
            changed.restUntil = nil
            changed.restKind = nil
            changed.restExerciseID = nil
        }
        changed.reconcileActiveTiming(at: now)
        return save(changed)
    }

    @discardableResult
    func stopRest(sessionID: UUID, expectedDeadline: Date, date: Date = Date()) -> Bool {
        guard archive.active?.id == sessionID, archive.restUntil == expectedDeadline else { return false }
        return stopRest(date: date)
    }

    @discardableResult
    func stopRest(date: Date = Date()) -> Bool {
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        changed.restUntil = nil
        changed.restKind = nil
        changed.restExerciseID = nil
        changed.reconcileActiveTiming(at: now)
        return save(changed)
    }

    @discardableResult
    func finish(allowPartial: Bool = false, date: Date = Date()) -> Bool {
        guard var session = archive.active else { return false }
        guard session.completedSets > 0 else {
            errorMessage = TrainingError.noCompletedSets.localizedDescription
            return false
        }
        guard session.isResolved || allowPartial else {
            errorMessage = TrainingError.unfinishedSets.localizedDescription
            return false
        }
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        session.timing = changed.active?.timing
        session.timing?.transition(to: nil, at: now)
        session.finishedAt = now
        changed.history.insert(session, at: 0)
        changed.active = nil
        changed.restUntil = nil
        changed.restKind = nil
        changed.restExerciseID = nil
        return save(changed)
    }

    @discardableResult
    func discardActive(date: Date = Date()) -> Bool {
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        changed.active?.timing?.transition(to: nil, at: now)
        if let sessionID = changed.active?.id {
            changed.setRemovalIntents?.removeAll { $0.sessionID == sessionID }
            if changed.setRemovalIntents?.isEmpty == true { changed.setRemovalIntents = nil }
        }
        changed.active = nil
        changed.restUntil = nil
        changed.restKind = nil
        changed.restExerciseID = nil
        return save(changed)
    }

    var activeWorkoutState: ActiveWorkoutState? {
        archive.active.map { ActiveWorkoutState(session: $0, restUntil: archive.restUntil,
                                               restKind: archive.restKind, restExerciseID: archive.restExerciseID) }
    }

    func removedSetIDs(for session: WorkoutSession) -> [UUID] {
        let retained = Set(session.exercises.flatMap(\.sets).map(\.id))
        return (archive.setRemovalIntents ?? []).filter {
            $0.sessionID == session.id && !retained.contains($0.setID)
        }.map(\.setID)
    }

    @discardableResult
    func acknowledgeFinishedSetRemovals(sessionIDs: Set<UUID>) -> Bool {
        var finished = Set(archive.history.map(\.id)).intersection(sessionIDs)
        if let activeID = archive.active?.id { finished.remove(activeID) }
        guard archive.setRemovalIntents?.contains(where: { finished.contains($0.sessionID) }) == true else { return true }
        var changed = archive
        changed.setRemovalIntents?.removeAll { finished.contains($0.sessionID) }
        if changed.setRemovalIntents?.isEmpty == true { changed.setRemovalIntents = nil }
        return save(changed)
    }

    @discardableResult
    func replaceTemplate(_ days: [TrainingDay], structureVersion: Int? = nil) -> Bool {
        guard (0...1).contains(structureVersion ?? 0), days.map(\.weekday).sorted() == Array(1...7),
              days.allSatisfy({ $0.hasValidPlannedStructure && $0.context?.cycle == nil }) else {
            errorMessage = TrainingError.invalidProgram.localizedDescription
            return false
        }
        var changed = archive
        changed.week = days.sorted { $0.weekday < $1.weekday }
        if structureVersion == 1 || days.contains(where: \.hasStructureMetadata) || changed.templateStructureVersion == 1 {
            changed.templateStructureVersion = 1
        }
        return save(changed)
    }

    @discardableResult
    func replaceScheduledWeek(_ week: TrainingWeek) -> Bool {
        let calendar = TrainingCalendar(timezone: week.timezone)
        guard week.hasValidStructure, let start = calendar.date(from: week.weekStart),
              calendar.dayKey(for: calendar.weekStart(containing: start)) == week.weekStart,
              Set(week.workouts.map(\.id)).count == week.workouts.count,
              Set(week.workouts.map(\.plannedDate)).count == week.workouts.count,
              week.workouts.allSatisfy({ workout in
                  guard let date = calendar.date(from: workout.plannedDate) else { return false }
                  return calendar.dayKey(for: calendar.weekStart(containing: date)) == week.weekStart &&
                      !workout.exercises.isEmpty && workout.exercises.allSatisfy {
                          (1...12).contains($0.setCount) && (0...600).contains($0.restSeconds) &&
                          (0...600).contains($0.restAfterExerciseSeconds)
                      }
              }) else {
            errorMessage = TrainingError.invalidProgram.localizedDescription
            return false
        }
        var changed = archive
        var weeks = changed.scheduledWeeks ?? []
        weeks.removeAll { $0.weekStart == week.weekStart }
        weeks.append(week)
        changed.scheduledWeeks = weeks.sorted { $0.weekStart < $1.weekStart }
        return save(changed)
    }

    @discardableResult
    func mergeHistory(_ sessions: [WorkoutSession]) -> Bool {
        guard sessions.allSatisfy({ $0.finishedAt != nil && $0.completedSets > 0 && !$0.exercises.isEmpty &&
            $0.hasValidStructure && ($0.timing?.isValid(for: $0) ?? true) }) else {
            errorMessage = TrainingError.invalidArchive.localizedDescription
            return false
        }
        var changed = archive
        var known = Set(changed.history.map(\.id))
        let incoming = sessions.filter { known.insert($0.id).inserted }
        if incoming.isEmpty { return true }
        changed.history.append(contentsOf: incoming)
        changed.history.sort { $0.startedAt > $1.startedAt }
        return save(changed)
    }

    @discardableResult
    func restoreActiveWorkout(_ state: ActiveWorkoutState?, date: Date = Date()) -> Bool {
        if let session = state?.session {
            guard session.finishedAt == nil, !session.exercises.isEmpty, session.hasValidStructure,
                  session.exercises.indices.contains(session.currentExercise),
                  session.timing?.isValid(for: session) ?? true,
                  !archive.history.contains(where: { $0.id == session.id }) else {
                errorMessage = TrainingError.invalidArchive.localizedDescription
                return false
            }
        }
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        var incoming = state?.session
        if incoming?.id == changed.active?.id {
            incoming?.timing = changed.active?.timing
        } else if var timing = incoming?.timing {
            let applyDate = timing.boundaryDate(now)
            if let last = timing.intervals.last, last.endedAt == nil, last.kind == .rest,
               let deadline = last.restDeadline {
                timing.transition(to: nil, at: min(applyDate, deadline))
            } else { timing.transition(to: nil, at: applyDate) }
            incoming?.timing = timing
        }
        changed.active = incoming
        let retainedSessions = (incoming.map { [$0] } ?? []) + changed.history
        changed.setRemovalIntents?.removeAll { intent in
            guard let session = retainedSessions.first(where: { $0.id == intent.sessionID }) else { return true }
            return session.exercises.flatMap(\.sets).contains { $0.id == intent.setID }
        }
        if changed.setRemovalIntents?.isEmpty == true { changed.setRemovalIntents = nil }
        changed.restUntil = state?.restUntil
        changed.restKind = state?.restKind
        changed.restExerciseID = state?.restExerciseID
        changed.reconcileActiveTiming(at: now)
        return save(changed)
    }

    func previousExercise(_ exercise: Exercise) -> SessionExercise? {
        exerciseHistory(for: exercise).first?.exercises.first
    }

    func previousSet(for exercise: Exercise, index: Int) -> LoggedSet? {
        guard let previous = previousExercise(exercise) else { return nil }
        let sets = previous.sets.filter { $0.isCompleted && $0.isValid }
        return sets.indices.contains(index) ? sets[index] : nil
    }

    func exerciseHistory(for exercise: Exercise) -> [(session: WorkoutSession, exercises: [SessionExercise])] {
        let catalog = ExerciseCatalog.bundled
        let exerciseID = catalog.entry(for: exercise.id)?.id ?? exercise.id
        return archive.history.sorted { $0.startedAt > $1.startedAt }.compactMap { session in
            let matches = session.exercises.filter {
                (catalog.entry(for: $0.exercise.id)?.id ?? $0.exercise.id) == exerciseID &&
                    $0.sets.contains(where: \.isCompleted)
            }
            return matches.isEmpty ? nil : (session, matches)
        }
    }

    func progress(for exercise: Exercise) -> [(session: WorkoutSession, weight: Double)] {
        exerciseHistory(for: exercise).reversed().compactMap { entry in
            let sets = entry.exercises.flatMap(\.sets).filter(\.isCompleted)
            guard let maxWeight = sets.compactMap(\.weightValue).max() else { return nil }
            return (entry.session, maxWeight)
        }
    }
}
