import Foundation

enum PlannedLoadType: String, Codable, CaseIterable, Identifiable {
    case regular, heavy, light, deload
    var id: String { rawValue }
    var title: String {
        switch self {
        case .regular: "Обычный"
        case .heavy: "Тяжёлый"
        case .light: "Лёгкий"
        case .deload: "Разгрузка"
        }
    }
}

enum PlannedDifficulty: String, Codable, CaseIterable, Identifiable {
    case unspecified, easy, moderate, hard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unspecified: "Не задана"
        case .easy: "Легко"
        case .moderate: "Умеренно"
        case .hard: "Сложно"
        }
    }
}

struct CycleWeekReference: Codable, Equatable {
    var cycleID: UUID
    var weekID: UUID
    var weekNumber: Int
}

struct WorkoutPlanContext: Codable, Equatable {
    var variant = ""
    var loadType: PlannedLoadType = .regular
    var difficulty: PlannedDifficulty = .unspecified
    var cycle: CycleWeekReference?

    var isValid: Bool {
        ["", "A", "B", "C"].contains(variant) && (cycle.map { (1...12).contains($0.weekNumber) } ?? true)
    }

    var summary: String {
        ([variant.isEmpty ? nil : "Вариант \(variant)", loadType == .regular ? nil : loadType.title,
          difficulty == .unspecified ? nil : difficulty.title]).compactMap { $0 }.joined(separator: " · ")
    }
}

struct TrainingCycleWeek: Codable, Equatable, Identifiable {
    var id = UUID()
    var days: [TrainingDay]
}

enum CycleGeneration: String, CaseIterable, Identifiable {
    case repeatingTemplate, volumeWave
    var id: String { rawValue }
    var title: String { self == .repeatingTemplate ? "Повтор шаблона" : "Волна подходов" }
    var explanation: String {
        switch self {
        case .repeatingTemplate: "Каждая неделя повторяет текущий шаблон. Затем можно изменить отдельные дни цикла."
        case .volumeWave:
            "Четыре недели: исходные подходы → +1 (до 12) → исходные → половина с округлением вверх (от 1). Цикл начинается заново каждые четыре недели; последняя неделя всегда разгрузочная. Вес и повторы не меняются. Это правило планирования, а не персональная рекомендация."
        }
    }
}

struct TrainingCyclePlan: Codable, Equatable, Identifiable {
    var id = UUID()
    var startWeek: String
    var timezone: String
    var repeats = false
    var weeks: [TrainingCycleWeek]

    var isValid: Bool {
        guard (2...12).contains(weeks.count), timezone != "Local", TimeZone(identifier: timezone) != nil,
              Set(weeks.map(\.id)).count == weeks.count else { return false }
        let calendar = TrainingCalendar(timezone: timezone)
        guard let start = calendar.date(from: startWeek),
              calendar.dayKey(for: calendar.weekStart(containing: start)) == startWeek,
              let end = calendar.calendar.date(byAdding: .day, value: weeks.count * 7 - 1, to: start),
              calendar.date(from: calendar.dayKey(for: end)) != nil else { return false }
        return weeks.allSatisfy { week in
            week.days.map(\.weekday).sorted() == Array(1...7) &&
                week.days.allSatisfy { $0.hasValidPlannedStructure && $0.context?.cycle == nil }
        }
    }

    static func generated(template: [TrainingDay], startWeek: String, timezone: String,
                          count: Int, repeats: Bool, generation: CycleGeneration) throws -> TrainingCyclePlan {
        guard (2...12).contains(count), template.map(\.weekday).sorted() == Array(1...7),
              template.allSatisfy({ $0.hasValidPlannedStructure && $0.context?.cycle == nil }),
              template.contains(where: { !$0.exercises.isEmpty }),
              generation != .volumeWave || count >= 4 else { throw TrainingError.invalidCycle }
        let weeks = (0..<count).map { offset in
            var days = template
            if generation == .volumeWave {
                let phase = offset == count - 1 ? 3 : offset % 4
                for day in days.indices where !days[day].exercises.isEmpty {
                    var context = days[day].context ?? WorkoutPlanContext()
                    context.loadType = phase == 3 ? .deload : (phase == 1 ? .heavy : .regular)
                    days[day].context = context
                    for exercise in days[day].exercises.indices {
                        let initial = days[day].exercises[exercise].setCount
                        days[day].exercises[exercise].setCount = phase == 3 ? max(1, (initial + 1) / 2)
                            : (phase == 1 ? min(12, initial + 1) : initial)
                    }
                }
            }
            return TrainingCycleWeek(days: days)
        }
        let plan = TrainingCyclePlan(startWeek: startWeek, timezone: timezone, repeats: repeats, weeks: weeks)
        guard plan.isValid else { throw TrainingError.invalidCycle }
        return plan
    }

    func phase(containing date: Date, calendar: TrainingCalendar) -> (index: Int, week: TrainingCycleWeek)? {
        guard isValid else { return nil }
        // Cycle boundaries are date-only keys in its saved timezone, never elapsed seconds across DST.
        let ownCalendar = TrainingCalendar(timezone: timezone)
        let key = calendar.dayKey(for: calendar.weekStart(containing: date))
        guard let selected = ownCalendar.date(from: key), let start = ownCalendar.date(from: startWeek),
              let days = ownCalendar.calendar.dateComponents([.day], from: start, to: selected).day,
              days >= 0 else { return nil }
        let offset = days / 7
        guard repeats || offset < weeks.count else { return nil }
        let index = offset % weeks.count
        return (index, weeks[index])
    }

    func template(containing date: Date, calendar: TrainingCalendar) -> [TrainingDay]? {
        guard let phase = phase(containing: date, calendar: calendar) else { return nil }
        return phase.week.days.map { day in
            guard !day.exercises.isEmpty else { return day }
            var result = day
            var context = result.context ?? WorkoutPlanContext()
            context.cycle = CycleWeekReference(cycleID: id, weekID: phase.week.id, weekNumber: phase.index + 1)
            result.context = context
            return result
        }
    }
}

struct TrainingCycleDocument: Codable, Equatable {
    var version = 1
    var plan: TrainingCyclePlan?
    var isValid: Bool { version == 1 && (plan?.isValid ?? true) }

    private enum CodingKeys: String, CodingKey { case version, plan }

    init(plan: TrainingCyclePlan? = nil) { self.plan = plan }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        plan = try values.decodeIfPresent(TrainingCyclePlan.self, forKey: .plan)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(plan, forKey: .plan)
    }
}
