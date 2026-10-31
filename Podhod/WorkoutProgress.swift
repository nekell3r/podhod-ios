import Foundation

enum WorkoutProgressPeriod: String, CaseIterable, Identifiable {
    case week, month, allTime

    var id: Self { self }
    var title: String {
        switch self {
        case .week: "7 дней"
        case .month: "30 дней"
        case .allTime: "Всё время"
        }
    }
    var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .allTime: nil
        }
    }
}

struct WorkoutProgressSummary {
    let sessions: [WorkoutSession]
    let completedSets: Int
    let repetitions: Int
    let volume: Double
    let bodyweightSets: Int
    let elapsedSeconds: TimeInterval
    let exerciseSeconds: TimeInterval
    let restSeconds: TimeInterval
    let otherSeconds: TimeInterval
    let untrackedSeconds: TimeInterval

    init(sessions: [WorkoutSession]) {
        self.sessions = sessions.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt
        }
        let sets = sessions.flatMap(\.exercises).flatMap(\.sets).filter { $0.isCompleted && $0.isValid }
        completedSets = sets.count
        repetitions = sets.reduce(0) { $0 + ($1.repValue ?? 0) }
        volume = sets.reduce(0) { $0 + $1.volume }
        bodyweightSets = sets.filter { $0.weightValue == 0 }.count
        elapsedSeconds = sessions.reduce(0) { $0 + max(0, $1.duration) }
        var exercise: TimeInterval = 0
        var rest: TimeInterval = 0
        var other: TimeInterval = 0
        var unknown: TimeInterval = 0
        for session in sessions {
            if let timing = session.timing, timing.isValid(for: session), let totals = session.timingTotals() {
                exercise += totals.exerciseSeconds
                rest += totals.restSeconds
                other += totals.otherSeconds
                unknown += totals.untrackedSeconds
            } else {
                unknown += max(0, session.duration)
            }
        }
        exerciseSeconds = exercise
        restSeconds = rest
        otherSeconds = other
        untrackedSeconds = unknown
    }
}

struct WorkoutProgressReport {
    let period: WorkoutProgressPeriod
    let interval: DateInterval?
    let previousInterval: DateInterval?
    let current: WorkoutProgressSummary
    let previous: WorkoutProgressSummary?

    init(history: [WorkoutSession], period: WorkoutProgressPeriod, calendar: TrainingCalendar, now: Date = Date()) {
        self.period = period
        let finished = history.filter {
            guard let end = $0.finishedAt else { return false }
            return $0.startedAt.timeIntervalSinceReferenceDate.isFinite && end.timeIntervalSinceReferenceDate.isFinite &&
                end >= $0.startedAt
        }
        guard let days = period.days else {
            interval = nil
            previousInterval = nil
            current = WorkoutProgressSummary(sessions: finished)
            previous = nil
            return
        }
        let today = calendar.calendar.startOfDay(for: now)
        guard let start = calendar.calendar.date(byAdding: .day, value: 1 - days, to: today),
              let end = calendar.calendar.date(byAdding: .day, value: 1, to: today),
              let previousStart = calendar.calendar.date(byAdding: .day, value: -days, to: start) else {
            interval = nil
            previousInterval = nil
            current = WorkoutProgressSummary(sessions: [])
            previous = nil
            return
        }
        interval = DateInterval(start: start, end: end)
        previousInterval = DateInterval(start: previousStart, end: start)
        current = WorkoutProgressSummary(sessions: finished.filter { $0.startedAt >= start && $0.startedAt < end })
        previous = WorkoutProgressSummary(sessions: finished.filter { $0.startedAt >= previousStart && $0.startedAt < start })
    }
}

enum ExerciseProgressMetric: String, CaseIterable, Identifiable {
    case weight, repetitions, volume, reserve

    var id: Self { self }
    var title: String {
        switch self {
        case .weight: "Вес"
        case .repetitions: "Повторы"
        case .volume: "Объём"
        case .reserve: "Запас"
        }
    }
    var unit: String {
        switch self {
        case .weight, .volume: "кг"
        case .repetitions: "повторов"
        case .reserve: "повторов в запасе"
        }
    }
    var explanation: String {
        switch self {
        case .weight: "Максимальный вес выполненного подхода за тренировку. Сравнивай при схожих повторах и запасе."
        case .repetitions: "Максимальное число повторов в одном выполненном подходе. Вес и запас смотри в исходной записи."
        case .volume: "Сумма веса × повторы выполненных подходов этого упражнения. Собственный вес с записью 0 кг не добавляет килограммы."
        case .reserve: "Минимальный указанный запас за тренировку. 5+ — верхняя категория; отсутствие оценки не считается отказом."
        }
    }

    func value(in point: ExerciseProgressPoint) -> Double? {
        switch self {
        case .weight: point.weight
        case .repetitions: Double(point.repetitions)
        case .volume: point.volume
        case .reserve: point.minimumReserve.map(Double.init)
        }
    }
}

struct WorkoutSetRecord: Identifiable {
    let session: WorkoutSession
    let exercise: SessionExercise
    let number: Int
    let set: LoggedSet
    var id: UUID { self.set.id }
}

struct ExerciseProgressPoint: Identifiable {
    let session: WorkoutSession
    let weight: Double
    let repetitions: Int
    let volume: Double
    let minimumReserve: Int?
    let assessedSets: Int
    var id: UUID { session.id }
}

struct WorkoutExerciseProgress {
    let records: [WorkoutSetRecord]
    let points: [ExerciseProgressPoint]

    init(sessions: [WorkoutSession], exercise: Exercise, catalog: ExerciseCatalog = .bundled) {
        let canonicalID = catalog.entry(for: exercise.id)?.id ?? exercise.id
        var records: [WorkoutSetRecord] = []
        var points: [ExerciseProgressPoint] = []
        let ordered = sessions.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
        }
        for session in ordered where session.finishedAt != nil {
            let matching = session.exercises.filter { (catalog.entry(for: $0.exercise.id)?.id ?? $0.exercise.id) == canonicalID }
            let performed = matching.flatMap { item in
                item.sets.enumerated().compactMap { index, set -> WorkoutSetRecord? in
                    guard set.isCompleted, set.isValid else { return nil }
                    return WorkoutSetRecord(session: session, exercise: item, number: index + 1, set: set)
                }
            }
            guard !performed.isEmpty else { continue }
            records.append(contentsOf: performed)
            let reserves = performed.compactMap { record -> Int? in
                guard let reserve = record.set.repsInReserve, reserve != .notRecorded else { return nil }
                return reserve.rawValue
            }
            points.append(ExerciseProgressPoint(session: session,
                weight: performed.compactMap { $0.set.weightValue }.max() ?? 0,
                repetitions: performed.compactMap { $0.set.repValue }.max() ?? 0,
                volume: performed.reduce(0) { $0 + $1.set.volume },
                minimumReserve: reserves.min(), assessedSets: reserves.count))
        }
        self.records = records
        self.points = points
    }

    var bestWeight: WorkoutSetRecord? {
        records.filter { ($0.set.weightValue ?? 0) > 0 }.max {
            if $0.set.weightValue != $1.set.weightValue { return ($0.set.weightValue ?? 0) < ($1.set.weightValue ?? 0) }
            return ($0.set.repValue ?? 0) < ($1.set.repValue ?? 0)
        }
    }
    var bestRepetitions: WorkoutSetRecord? {
        records.max {
            if $0.set.repValue != $1.set.repValue { return ($0.set.repValue ?? 0) < ($1.set.repValue ?? 0) }
            return ($0.set.weightValue ?? 0) < ($1.set.weightValue ?? 0)
        }
    }
    var bestSetVolume: WorkoutSetRecord? {
        records.filter { $0.set.volume > 0 }.max { $0.set.volume < $1.set.volume }
    }
}
