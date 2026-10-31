import Foundation

struct ScheduledWorkout: Codable, Identifiable, Equatable {
    var id = UUID()
    var plannedDate: String
    var title: String
    var exercises: [PlannedExercise]

    func day(calendar: TrainingCalendar) -> TrainingDay {
        let weekday = calendar.date(from: plannedDate).map { TrainingDay.weekday(for: $0, calendar: calendar.calendar) } ?? 1
        return TrainingDay(weekday: weekday, title: title, exercises: exercises)
    }
}

struct TrainingWeek: Codable, Equatable, Identifiable {
    var weekStart: String
    var timezone: String
    var revision: Int64 = 0
    var workouts: [ScheduledWorkout]
    var id: String { weekStart }

    init(containing date: Date, template: [TrainingDay], calendar: TrainingCalendar) {
        let start = calendar.weekStart(containing: date)
        weekStart = calendar.dayKey(for: start)
        timezone = calendar.calendar.timeZone.identifier
        workouts = template.filter { !$0.exercises.isEmpty }.map { day in
            let date = calendar.calendar.date(byAdding: .day, value: day.weekday - 1, to: start) ?? start
            return ScheduledWorkout(plannedDate: calendar.dayKey(for: date), title: day.title, exercises: day.exercises)
        }
    }

    func applyingTemplate(_ template: [TrainingDay]) throws -> TrainingWeek {
        let calendar = TrainingCalendar(timezone: timezone)
        guard let date = calendar.date(from: weekStart) else { throw TrainingError.invalidTrainingDate }
        var updated = TrainingWeek(containing: date, template: template, calendar: calendar)
        updated.revision = revision
        for index in updated.workouts.indices {
            if let previous = workouts.first(where: { $0.plannedDate == updated.workouts[index].plannedDate }) {
                updated.workouts[index].id = previous.id
            }
        }
        return updated
    }

    func day(on date: Date, calendar: TrainingCalendar) -> TrainingDay {
        workouts.first { $0.plannedDate == calendar.dayKey(for: date) }?.day(calendar: calendar)
            ?? TrainingDay(weekday: TrainingDay.weekday(for: date, calendar: calendar.calendar), title: "", exercises: [])
    }
}

struct TrainingCalendar {
    let calendar: Calendar

    init(timezone: String = TimeZone.current.identifier) {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        self.calendar = calendar
    }

    func dayKey(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func dayLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    func historyDayLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    func date(from key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard key.count == 10, parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1900...9999).contains(year),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              dayKey(for: date) == key else { return nil }
        return date
    }

    func weekStart(containing date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    func weekDates(containing date: Date) -> [Date] {
        let start = weekStart(containing: date)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}
