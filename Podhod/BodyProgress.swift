import Foundation

enum BodyMetric: String, Codable, CaseIterable, Identifiable {
    case weight, waist, chest, hips, leftArm, rightArm, leftThigh, rightThigh, leftCalf, rightCalf
    var id: String { rawValue }
    var unit: String { self == .weight ? "кг" : "см" }
    var maximum: Double { self == .weight ? 1000 : 500 }
    var title: String {
        switch self {
        case .weight: "Вес"
        case .waist: "Талия"
        case .chest: "Грудь"
        case .hips: "Бёдра"
        case .leftArm: "Левая рука"
        case .rightArm: "Правая рука"
        case .leftThigh: "Левое бедро"
        case .rightThigh: "Правое бедро"
        case .leftCalf: "Левая голень"
        case .rightCalf: "Правая голень"
        }
    }
}

struct BodyMeasurement: Codable, Equatable {
    var metric: BodyMetric
    var value: Double
    var isValid: Bool { value.isFinite && value > 0 && value <= metric.maximum }
}

struct BodyMeasurementEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var date: String
    var timezone: String
    var measurements: [BodyMeasurement]

    var isValid: Bool {
        timezone != "Local" && TimeZone(identifier: timezone) != nil &&
            TrainingCalendar(timezone: timezone).date(from: date) != nil &&
            !measurements.isEmpty && Set(measurements.map(\.metric)).count == measurements.count &&
            measurements.allSatisfy(\.isValid)
    }

    func value(for metric: BodyMetric) -> Double? { measurements.first { $0.metric == metric }?.value }
}

enum ProgressPhotoAngle: String, Codable, CaseIterable, Identifiable {
    case front, side, back, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .front: "Спереди"
        case .side: "Сбоку"
        case .back: "Сзади"
        case .other: "Другой ракурс"
        }
    }
}

struct BodyProgressPhoto: Codable, Equatable, Identifiable {
    var id = UUID()
    var date: String
    var timezone: String
    var angle: ProgressPhotoAngle

    var isValid: Bool {
        timezone != "Local" && TimeZone(identifier: timezone) != nil &&
            TrainingCalendar(timezone: timezone).date(from: date) != nil
    }
}

struct BodyProgressArchive: Codable, Equatable {
    var version = 1
    var accountID: String?
    var entries: [BodyMeasurementEntry] = []
    var photos: [BodyProgressPhoto] = []
    var pendingPhotoDeletions: [UUID] = []

    var isValid: Bool {
        version == 1 && (accountID.map { !$0.isEmpty } ?? true) && entries.count <= 5000 && photos.count <= 500 &&
            Set(entries.map(\.id)).count == entries.count && Set(entries.map(\.date)).count == entries.count &&
            entries.allSatisfy(\.isValid) && Set(photos.map(\.id)).count == photos.count && photos.allSatisfy(\.isValid) &&
            pendingPhotoDeletions.count <= 500 && Set(pendingPhotoDeletions).count == pendingPhotoDeletions.count &&
            Set(photos.map(\.id)).isDisjoint(with: pendingPhotoDeletions)
    }

    func points(for metric: BodyMetric) -> [(entry: BodyMeasurementEntry, value: Double)] {
        entries.sorted { $0.date < $1.date }.compactMap { entry in entry.value(for: metric).map { (entry, $0) } }
    }
}

enum BodyProgressError: LocalizedError {
    case invalidMeasurement, invalidPhoto, invalidArchive, unsupportedArchive, staleEdit, dateOccupied
    case accountMismatch, saveFailed, photoUnavailable, deletionIncomplete, capacity

    var errorDescription: String? {
        switch self {
        case .invalidMeasurement: "Укажи хотя бы один замер: положительное число в кг или см. Пустое поле останется без значения."
        case .invalidPhoto: "Не удалось подготовить фото. Выбери обычное изображение до 50 МБ и 100 мегапикселей."
        case .invalidArchive: "Не удалось прочитать замеры. Исходные файлы сохранены без изменений."
        case .unsupportedArchive: "Замеры сохранены более новой версией приложения. Обнови приложение."
        case .staleEdit: "Запись изменилась. Черновик остался на экране; открой актуальную запись перед повторным изменением."
        case .dateOccupied: "На эту дату уже есть замеры. Открой существующую запись."
        case .accountMismatch: "Эти замеры относятся к другому аккаунту. Файлы не изменены."
        case .saveFailed: "Не удалось сохранить изменение. Прежние записи сохранены; повтори действие."
        case .photoUnavailable: "Копия фото недоступна. Замеры сохранены; можно удалить запись снимка или добавить фото снова."
        case .deletionIncomplete: "Фото скрыто, но удаление файла ещё не завершено. Повтори удаление, когда устройство разблокировано."
        case .capacity: "Достигнут предел: 5000 дат замеров или 500 фото. Освободи место перед добавлением."
        }
    }
}
