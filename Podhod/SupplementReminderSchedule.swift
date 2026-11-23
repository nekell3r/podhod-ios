import Foundation

struct SupplementReminderSchedule {
    enum Series: CaseIterable {
        case creatine, proteinMorning, proteinEvening

        var hours: [Int] {
            switch self {
            case .creatine: Array(stride(from: 9, through: 23, by: 2))
            case .proteinMorning: Array(stride(from: 9, through: 19, by: 2))
            case .proteinEvening: [21, 23]
            }
        }
    }

    struct Slot: Equatable {
        let hour: Int
        // An absent date keeps the daily system trigger. A date schedules one delivery.
        let date: Date?
    }

    static func slots(for series: Series, mutedUntil: Date?, now: Date, calendar: Calendar) -> [Slot] {
        series.hours.flatMap { hour -> [Slot] in
            let time = DateComponents(hour: hour, minute: 30, second: 0)
            guard let mutedUntil,
                  let next = calendar.nextDate(after: now, matching: time, matchingPolicy: .strict),
                  next < mutedUntil else {
                return [Slot(hour: hour, date: nil)]
            }

            // At most 48 supplement requests even when all 16 slots need deferring.
            var after = mutedUntil.addingTimeInterval(-1)
            var deferred: [Slot] = []
            for _ in 0..<3 {
                guard let date = calendar.nextDate(after: after, matching: time, matchingPolicy: .strict) else { break }
                deferred.append(Slot(hour: hour, date: date))
                after = date
            }
            return deferred
        }
    }
}
