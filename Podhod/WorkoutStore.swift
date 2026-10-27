import Foundation
import Observation

@MainActor @Observable
final class WorkoutStore {
    private(set) var archive: TrainingArchive
    var errorMessage: String?
    private(set) var loadFailed = false
    @ObservationIgnored let fileURL: URL
    @ObservationIgnored private var migrationSourceVersion: Int?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? URL.applicationSupportDirectory
            .appending(path: "Podhod", directoryHint: .isDirectory)
            .appending(path: "training.json")
        archive = TrainingArchive()
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                let data = try Data(contentsOf: self.fileURL)
                var loaded = try JSONDecoder().decode(TrainingArchive.self, from: data)
                guard (1...3).contains(loaded.version) else { throw TrainingError.unsupportedArchive }
                guard loaded.week.map(\.weekday).sorted() == Array(1...7),
                      loaded.week.allSatisfy({ $0.exercises.allSatisfy { (1...12).contains($0.setCount) } }),
                      loaded.active.map({ !$0.exercises.isEmpty && $0.exercises.indices.contains($0.currentExercise) }) ?? true
                else { throw TrainingError.invalidArchive }
                guard loaded.active.map({ session in session.timing?.isValid(for: session) ?? true }) ?? true,
                      loaded.history.allSatisfy({ $0.timing?.isValid(for: $0) ?? true }) else { throw TrainingError.invalidArchive }
                migrationSourceVersion = loaded.version < 3 ? loaded.version : nil
                loaded.version = 3
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
        let saved = archive.week.flatMap(\.exercises).map(\.exercise) +
            (archive.scheduledWeeks ?? []).flatMap(\.workouts).flatMap(\.exercises).map(\.exercise) +
            (archive.active?.exercises ?? []).map(\.exercise) + archive.history.flatMap(\.exercises).map(\.exercise)
        return catalog.exercises.map(\.exercise) + saved.filter {
            catalog.entry(for: $0.id) == nil && seen.insert($0.id).inserted
        }
    }

    var trainingCalendar: TrainingCalendar { TrainingCalendar(timezone: archive.timezone ?? TimeZone.current.identifier) }

    var today: TrainingDay { scheduledWeek(containing: Date()).day(on: Date(), calendar: trainingCalendar) }

    func scheduledWeek(containing date: Date) -> TrainingWeek {
        let key = trainingCalendar.dayKey(for: trainingCalendar.weekStart(containing: date))
        return archive.scheduledWeeks?.first { $0.weekStart == key }
            ?? TrainingWeek(containing: date, template: archive.week, calendar: trainingCalendar)
    }

    @discardableResult
    func ensureWeek(containing date: Date) -> Bool {
        let week = scheduledWeek(containing: date)
        if archive.scheduledWeeks?.contains(where: { $0.weekStart == week.weekStart }) == true { return true }
        var changed = archive
        changed.scheduledWeeks = (changed.scheduledWeeks ?? []) + [week]
        changed.timezone = trainingCalendar.calendar.timeZone.identifier
        return save(changed)
    }

    @discardableResult
    func saveScheduledDay(_ day: TrainingDay, on date: Date, expected: TrainingDay? = nil) -> Bool {
        if let expected, scheduledWeek(containing: date).day(on: date, calendar: trainingCalendar) != expected {
            errorMessage = TrainingError.staleProgramEdit.localizedDescription
            return false
        }
        guard day.exercises.allSatisfy({ !$0.exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
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
            week.workouts.append(ScheduledWorkout(id: existing?.id ?? UUID(), plannedDate: key, title: day.title, exercises: day.exercises))
        }
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
        guard !loadFailed else {
            errorMessage = "Сохранение недоступно: исходный файл не удалось прочитать. Данные защищены от перезаписи."
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
        guard let index = archive.week.firstIndex(where: { $0.weekday == day.weekday }),
              day.exercises.allSatisfy({ !$0.exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  (1...12).contains($0.setCount) && !$0.targetReps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (0...600).contains($0.restSeconds) &&
                  (0...600).contains($0.restAfterExerciseSeconds) }) else {
            errorMessage = TrainingError.invalidProgram.localizedDescription
            return false
        }
        var changed = archive
        changed.week[index] = day
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
        guard !day.exercises.isEmpty else {
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
    func toggleSet(exerciseID: UUID, setID: UUID, date: Date = Date()) -> Bool {
        guard var session = archive.active,
              let e = session.exercises.firstIndex(where: { $0.id == exerciseID }),
              let s = session.exercises[e].sets.firstIndex(where: { $0.id == setID }),
              !session.exercises[e].isSkipped else { return false }
        let completing = !session.exercises[e].sets[s].isCompleted
        if completing && !session.exercises[e].sets[s].isValid {
            errorMessage = TrainingError.invalidSet.localizedDescription
            return false
        }
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        session.timing = changed.active?.timing
        session.exercises[e].sets[s].isCompleted = completing
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

    func stopRest(date: Date = Date()) {
        var changed = archive
        let now = changed.reconcileActiveTiming(at: date)
        changed.restUntil = nil
        changed.restKind = nil
        changed.restExerciseID = nil
        changed.reconcileActiveTiming(at: now)
        save(changed)
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

    @discardableResult
    func replaceTemplate(_ days: [TrainingDay]) -> Bool {
        guard days.map(\.weekday).sorted() == Array(1...7),
              days.allSatisfy({ $0.exercises.allSatisfy { (1...12).contains($0.setCount) &&
                  (0...600).contains($0.restSeconds) && (0...600).contains($0.restAfterExerciseSeconds) } }) else {
            errorMessage = TrainingError.invalidProgram.localizedDescription
            return false
        }
        var changed = archive
        changed.week = days.sorted { $0.weekday < $1.weekday }
        return save(changed)
    }

    @discardableResult
    func replaceScheduledWeek(_ week: TrainingWeek) -> Bool {
        let calendar = TrainingCalendar(timezone: week.timezone)
        guard let start = calendar.date(from: week.weekStart),
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
            ($0.timing?.isValid(for: $0) ?? true) }) else {
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
            guard session.finishedAt == nil, !session.exercises.isEmpty,
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
        changed.restUntil = state?.restUntil
        changed.restKind = state?.restKind
        changed.restExerciseID = state?.restExerciseID
        changed.reconcileActiveTiming(at: now)
        return save(changed)
    }

    func previousExercise(_ exercise: Exercise) -> SessionExercise? {
        archive.history.lazy.flatMap(\.exercises)
            .first { $0.exercise.id == exercise.id && $0.sets.contains(where: \.isCompleted) }
    }

    func progress(for exercise: Exercise) -> [(session: WorkoutSession, weight: Double)] {
        archive.history.reversed().compactMap { session in
            let sets = session.exercises.filter { $0.exercise.id == exercise.id }.flatMap(\.sets).filter(\.isCompleted)
            guard let maxWeight = sets.compactMap(\.weightValue).max() else { return nil }
            return (session, maxWeight)
        }
    }
}
