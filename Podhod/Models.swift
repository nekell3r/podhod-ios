import Foundation

struct Exercise: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var muscle: String
    var illustration: String
    var cue: String

    static var catalog: [Exercise] { ExerciseCatalog.bundled.exercises.map(\.exercise) }
}

struct PlannedExercise: Codable, Identifiable, Equatable {
    var id: UUID
    var exercise: Exercise
    var setCount: Int
    var targetReps: String
    var restSeconds: Int
    var restAfterExerciseSeconds: Int

    init(id: UUID = UUID(), exercise: Exercise, setCount: Int = 3,
         targetReps: String = "8–12", restSeconds: Int = 90,
         restAfterExerciseSeconds: Int? = nil) {
        self.id = id
        self.exercise = exercise
        self.setCount = setCount
        self.targetReps = targetReps
        self.restSeconds = restSeconds
        self.restAfterExerciseSeconds = restAfterExerciseSeconds ?? restSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, exercise, setCount, targetReps, restSeconds, restAfterExerciseSeconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        exercise = try values.decode(Exercise.self, forKey: .exercise)
        setCount = try values.decode(Int.self, forKey: .setCount)
        targetReps = try values.decode(String.self, forKey: .targetReps)
        restSeconds = try values.decode(Int.self, forKey: .restSeconds)
        restAfterExerciseSeconds = try values.decodeIfPresent(Int.self, forKey: .restAfterExerciseSeconds) ?? restSeconds
    }
}

struct TrainingDay: Codable, Identifiable, Equatable {
    var weekday: Int
    var title: String
    var exercises: [PlannedExercise]
    var id: Int { weekday }
    var setCount: Int { exercises.reduce(0) { $0 + $1.setCount } }
    var name: String { Self.names[weekday - 1] }
    var shortName: String { Self.shortNames[weekday - 1] }
    static let names = ["Понедельник", "Вторник", "Среда", "Четверг", "Пятница", "Суббота", "Воскресенье"]
    static let shortNames = ["ПН", "ВТ", "СР", "ЧТ", "ПТ", "СБ", "ВС"]

    static func weekday(for date: Date, calendar: Calendar = .current) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    static func initialWeek() -> [TrainingDay] {
        (1...7).map { TrainingDay(weekday: $0, title: "", exercises: []) }
    }

    static func exampleWeek() -> [TrainingDay] {
        var week = initialWeek()
        week[0].title = "Верх тела"
        week[0].exercises = [0, 2, 4, 6].map { PlannedExercise(exercise: Exercise.catalog[$0]) }
        week[2].title = "Ноги и ягодицы"
        week[2].exercises = [1, 3, 8, 9].map { PlannedExercise(exercise: Exercise.catalog[$0]) }
        week[4].title = "Верх тела"
        week[4].exercises = [0, 5, 10, 7].map { PlannedExercise(exercise: Exercise.catalog[$0]) }
        return week
    }
}

enum RepetitionsInReserve: Int, Codable, CaseIterable, Identifiable {
    case notRecorded = -1
    case failure = 0
    case one, two, three, four, fiveOrMore

    var id: Int { rawValue }
    var compactTitle: String {
        switch self {
        case .notRecorded: "—"
        case .fiveOrMore: "5+"
        default: String(rawValue)
        }
    }
    var title: String {
        switch self {
        case .notRecorded: "Не указан"
        case .failure: "0 — в отказ"
        case .fiveOrMore: "5+ повторов"
        default: "\(rawValue)"
        }
    }
    var summary: String {
        switch self {
        case .notRecorded: "Запас не указан"
        case .failure: "В отказ · запас 0"
        case .fiveOrMore: "Запас 5+ повторов"
        default: "Запас \(rawValue)"
        }
    }
}

struct LoggedSet: Codable, Identifiable, Equatable {
    var id = UUID()
    var reps = ""
    var weight = ""
    var isCompleted = false
    var repsInReserve: RepetitionsInReserve?

    var repValue: Int? {
        Int(reps.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    var weightValue: Double? {
        Double(weight.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }
    var isValid: Bool {
        guard let reps = repValue, let weight = weightValue else { return false }
        return (1...9999).contains(reps) && weight.isFinite && (0...2000).contains(weight)
    }
    var volume: Double { isCompleted ? Double(repValue ?? 0) * (weightValue ?? 0) : 0 }
}

struct SessionExercise: Codable, Identifiable, Equatable {
    var id: UUID
    var exercise: Exercise
    var targetReps: String
    var restSeconds: Int
    var restAfterExerciseSeconds: Int
    var sets: [LoggedSet]
    var isSkipped: Bool
    var isCompleted: Bool { sets.allSatisfy(\.isCompleted) }
    var isResolved: Bool { isCompleted || isSkipped }
    var skippedSets: Int { isSkipped ? sets.filter { !$0.isCompleted }.count : 0 }

    init(id: UUID = UUID(), exercise: Exercise, targetReps: String, restSeconds: Int,
         restAfterExerciseSeconds: Int? = nil, sets: [LoggedSet], isSkipped: Bool = false) {
        self.id = id
        self.exercise = exercise
        self.targetReps = targetReps
        self.restSeconds = restSeconds
        self.restAfterExerciseSeconds = restAfterExerciseSeconds ?? restSeconds
        self.sets = sets
        self.isSkipped = isSkipped
    }

    private enum CodingKeys: String, CodingKey {
        case id, exercise, targetReps, restSeconds, restAfterExerciseSeconds, sets, isSkipped
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        exercise = try values.decode(Exercise.self, forKey: .exercise)
        targetReps = try values.decode(String.self, forKey: .targetReps)
        restSeconds = try values.decode(Int.self, forKey: .restSeconds)
        restAfterExerciseSeconds = try values.decodeIfPresent(Int.self, forKey: .restAfterExerciseSeconds) ?? restSeconds
        sets = try values.decode([LoggedSet].self, forKey: .sets)
        isSkipped = try values.decodeIfPresent(Bool.self, forKey: .isSkipped) ?? false
    }
}

struct WorkoutSession: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var weekday: Int
    var startedAt: Date
    var finishedAt: Date?
    var timing: WorkoutTiming?
    var scheduledWorkoutID: UUID?
    var plannedDate: String?
    var currentExercise = 0
    var exercises: [SessionExercise]
    var completedSets: Int { exercises.flatMap(\.sets).filter(\.isCompleted).count }
    var totalSets: Int { exercises.reduce(0) { $0 + $1.sets.count } }
    var volume: Double { exercises.flatMap(\.sets).reduce(0) { $0 + $1.volume } }
    var isCompleted: Bool { completedSets == totalSets }
    var isResolved: Bool { exercises.allSatisfy(\.isResolved) }
    var skippedSets: Int { exercises.reduce(0) { $0 + $1.skippedSets } }
    var duration: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }

    func containsCompletedSets(from other: WorkoutSession) -> Bool {
        if id != other.id { return other.completedSets == 0 }
        let sets = exercises.flatMap(\.sets)
        guard Set(sets.map(\.id)).count == sets.count else { return false }
        let indexed = Dictionary(uniqueKeysWithValues: sets.map { ($0.id, $0) })
        return other.exercises.flatMap(\.sets).filter(\.isCompleted).allSatisfy { indexed[$0.id] == $0 }
    }

    init(day: TrainingDay, date: Date = Date()) {
        title = day.title.isEmpty ? day.name : day.title
        weekday = day.weekday
        startedAt = date
        exercises = day.exercises.map { plan in
            SessionExercise(exercise: plan.exercise, targetReps: plan.targetReps,
                            restSeconds: plan.restSeconds,
                            restAfterExerciseSeconds: plan.restAfterExerciseSeconds,
                            sets: (0..<plan.setCount).map { _ in LoggedSet() })
        }
    }
}

enum WorkoutRestKind: String, Codable {
    case betweenSets
    case betweenExercises
}

struct SetRemovalIntent: Codable, Equatable, Hashable {
    var sessionID: UUID
    var setID: UUID
}

struct TrainingArchive: Codable, Equatable {
    var version = 5
    var week = TrainingDay.initialWeek()
    var history: [WorkoutSession] = []
    var active: WorkoutSession?
    var restUntil: Date?
    var restKind: WorkoutRestKind?
    var restExerciseID: UUID?
    var scheduledWeeks: [TrainingWeek]?
    var editedWeekStarts: [String]?
    var timezone: String?
    var setRemovalIntents: [SetRemovalIntent]?

    var hasValidSetRemovalIntents: Bool {
        let intents = setRemovalIntents ?? []
        guard Set(intents).count == intents.count,
              Dictionary(grouping: intents, by: \.sessionID).values.allSatisfy({ $0.count <= 600 }) else { return false }
        let sessions = (active.map { [$0] } ?? []) + history
        return intents.allSatisfy { intent in
            guard let session = sessions.first(where: { $0.id == intent.sessionID }) else { return false }
            return !session.exercises.flatMap(\.sets).contains { $0.id == intent.setID }
        }
    }
}

enum TrainingError: LocalizedError {
    case invalidSet, emptyDay, unfinishedSets, noCompletedSets, invalidProgram, unsupportedArchive, invalidArchive
    case invalidRest, scheduleConflict, invalidTrainingDate, staleProgramEdit, staleWorkoutEdit

    var errorDescription: String? {
        switch self {
        case .invalidSet: "Укажи от 1 до 9999 повторов и вес от 0 до 2000 кг. Для собственного веса укажи 0."
        case .emptyDay: "Сначала добавь упражнения в программу этого дня."
        case .unfinishedSets: "Остались незаписанные подходы. Можно вернуться к ним или завершить тренировку досрочно."
        case .noCompletedSets: "Запиши хотя бы один подход перед завершением тренировки."
        case .invalidProgram: "Проверь название, количество подходов и время отдыха."
        case .invalidRest: "Время отдыха должно быть от 0 до 600 секунд."
        case .staleProgramEdit: "Программа изменилась, пока был открыт редактор. Твой черновик остался на этом экране. Закрой редактор и открой актуальный день перед повторным изменением."
        case .staleWorkoutEdit: "Тренировка или подходы изменились, пока был открыт выбор. Закрой его и открой актуальное упражнение перед повторным изменением."
        case .scheduleConflict: "На этой дате уже есть тренировка. Сначала выбери для неё другой день."
        case .invalidTrainingDate: "Выбери дату в пределах этой недели."
        case .unsupportedArchive: "Этот файл создан более новой версией приложения. Обнови приложение, чтобы открыть данные."
        case .invalidArchive: "Данные тренировок повреждены. Исходный файл сохранён без изменений."
        }
    }
}

func weightText(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "ru_RU")))
}
