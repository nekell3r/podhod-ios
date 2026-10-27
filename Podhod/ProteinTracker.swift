import Foundation
import Observation

enum ProteinPeriod: String, Codable, CaseIterable {
    case morning
    case evening
}

struct ProteinDayRecord: Codable, Equatable, Identifiable {
    var date: String
    var revision: Int64 = 0
    var morningTakenAt: Date?
    var eveningTakenAt: Date?
    var id: String { date }

    init(date: String, revision: Int64 = 0, morningTakenAt: Date? = nil, eveningTakenAt: Date? = nil) {
        self.date = date
        self.revision = revision
        self.morningTakenAt = morningTakenAt
        self.eveningTakenAt = eveningTakenAt
    }

    func isTaken(_ period: ProteinPeriod) -> Bool {
        switch period {
        case .morning: morningTakenAt != nil
        case .evening: eveningTakenAt != nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case date, revision, morningTakenAt, eveningTakenAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        date = try values.decode(String.self, forKey: .date)
        revision = try values.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        morningTakenAt = try values.decodeIfPresent(Date.self, forKey: .morningTakenAt)
        eveningTakenAt = try values.decodeIfPresent(Date.self, forKey: .eveningTakenAt)
    }
}

private struct ProteinArchive: Codable {
    var version = 1
    var days: [ProteinDayRecord]
}

private enum ProteinStorageError: LocalizedError {
    case unsupportedVersion, invalidRecord, staleRevision

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "Отметки протеина сохранены более новой версией приложения. Обнови приложение, чтобы открыть их."
        case .invalidRecord: "Не удалось прочитать отметки протеина. Исходные данные сохранены без изменений."
        case .staleRevision: "Пришла более старая версия отметок. Текущие данные сохранены."
        }
    }
}

@MainActor @Observable
final class ProteinTracker {
    private(set) var days: [ProteinDayRecord] = []
    private(set) var loadFailed = false
    var errorMessage: String?
    @ObservationIgnored let fileURL: URL
    @ObservationIgnored private let fixedCalendar: TrainingCalendar?

    init(fileURL: URL? = nil, calendar: TrainingCalendar? = nil) {
        self.fileURL = fileURL ?? URL.applicationSupportDirectory
            .appending(path: "Podhod", directoryHint: .isDirectory)
            .appending(path: "protein.json")
        fixedCalendar = calendar
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                let saved = try JSONDecoder().decode(ProteinArchive.self, from: Data(contentsOf: self.fileURL))
                guard saved.version == 1 else { throw ProteinStorageError.unsupportedVersion }
                guard Set(saved.days.map(\.date)).count == saved.days.count,
                      saved.days.allSatisfy({ isValid($0) }) else { throw ProteinStorageError.invalidRecord }
                days = saved.days.sorted { $0.date < $1.date }
            }
        } catch {
            loadFailed = true
            errorMessage = (error as? ProteinStorageError)?.localizedDescription
                ?? ProteinStorageError.invalidRecord.localizedDescription
        }
    }

    private var calendar: TrainingCalendar {
        fixedCalendar ?? TrainingCalendar(timezone: TimeZone.autoupdatingCurrent.identifier)
    }

    func day(on date: Date) -> ProteinDayRecord {
        let key = calendar.dayKey(for: date)
        return days.first { $0.date == key } ?? ProteinDayRecord(date: key)
    }

    @discardableResult
    func setTaken(period: ProteinPeriod, on date: Date, taken: Bool) -> Bool {
        guard !loadFailed else {
            errorMessage = ProteinStorageError.invalidRecord.localizedDescription
            return false
        }
        var record = day(on: date)
        if record.isTaken(period) == taken { return true }
        switch period {
        case .morning: record.morningTakenAt = taken ? date : nil
        case .evening: record.eveningTakenAt = taken ? date : nil
        }
        return replaceDay(record)
    }

    @discardableResult
    func replaceDay(_ record: ProteinDayRecord) -> Bool {
        guard !loadFailed, isValid(record) else {
            errorMessage = ProteinStorageError.invalidRecord.localizedDescription
            return false
        }
        if let current = days.first(where: { $0.date == record.date }) {
            guard record.revision >= current.revision else {
                errorMessage = ProteinStorageError.staleRevision.localizedDescription
                return false
            }
            if current == record { return true }
        }
        var changed = days.filter { $0.date != record.date }
        changed.append(record)
        changed.sort { $0.date < $1.date }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(ProteinArchive(days: changed)).write(to: fileURL, options: .atomic)
            days = changed
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Не удалось сохранить отметку протеина. Повтори действие; прежние данные сохранены."
            return false
        }
    }

    private func isValid(_ record: ProteinDayRecord) -> Bool {
        calendar.date(from: record.date) != nil && record.revision >= 0 &&
            (record.morningTakenAt?.timeIntervalSinceReferenceDate.isFinite ?? true) &&
            (record.eveningTakenAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
    }
}
