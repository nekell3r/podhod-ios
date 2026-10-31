import Foundation

enum NutritionDiaryError: LocalizedError {
    case invalidDocument, invalidArchive, unsupportedArchive, invalidResponse, staleConflict, immutableSnapshot, saveFailed, exportRange, unsyncedExport, accountMismatch

    var errorDescription: String? {
        switch self {
        case .invalidDocument: "Проверь дату, массу, названия и все четыре значения КБЖУ."
        case .invalidArchive: "Не удалось прочитать дневник питания. Исходный файл сохранён без изменений."
        case .unsupportedArchive: "Дневник сохранён более новой версией приложения. Обнови приложение."
        case .invalidResponse: "Не удалось проверить ответ сервера. Записи на iPhone сохранены."
        case .staleConflict: "Версия изменилась. Проверь конфликт ещё раз."
        case .immutableSnapshot: "День уже создан с другим часовым поясом или целью. Его снимок нельзя заменить."
        case .saveFailed: "Не удалось сохранить дневник. Повтори действие; прежние данные сохранены."
        case .exportRange: "Выбери период от 1 до 366 дней, с началом не позже окончания."
        case .unsyncedExport: "В выбранных днях есть неотправленные записи или конфликт. Заверши синхронизацию перед экспортом из аккаунта."
        case .accountMismatch: "Архив питания относится к другому аккаунту. Локальные данные не переданы; проверь вход."
        }
    }
}
