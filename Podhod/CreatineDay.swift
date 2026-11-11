import Foundation

struct CreatineDayDocument: Codable, Equatable {
    var version = 1
    var date: String
    var takenAt: Date?
    var isValid: Bool {
        version == 1 && TrainingCalendar(timezone: "UTC").date(from: date) != nil &&
            (takenAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
    }

    private enum CodingKeys: String, CodingKey { case version, date, takenAt }

    init(date: String, takenAt: Date? = nil) { self.date = date; self.takenAt = takenAt }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.version == rhs.version, lhs.date == rhs.date else { return false }
        guard let left = lhs.takenAt else { return rhs.takenAt == nil }
        guard let right = rhs.takenAt else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: left) == formatter.string(from: right)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        date = try values.decode(String.self, forKey: .date)
        takenAt = try values.decodeIfPresent(Date.self, forKey: .takenAt)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(date, forKey: .date)
        try values.encode(takenAt, forKey: .takenAt)
    }
}
