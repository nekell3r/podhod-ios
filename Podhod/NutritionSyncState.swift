import Foundation

struct NutritionDocumentRecord<Document: Codable & Equatable>: Codable, Equatable {
    var revision: Int64
    var document: Document
}

struct NutritionPendingWrite<Document: Codable & Equatable>: Codable, Equatable {
    var expectedRevision: Int64
    var requestID = UUID()
    var document: Document
}

struct NutritionDocumentState<Document: Codable & Equatable>: Codable, Equatable {
    private(set) var document: Document
    private(set) var acknowledged: NutritionDocumentRecord<Document>?
    private(set) var pending: NutritionPendingWrite<Document>?
    private(set) var conflict: NutritionDocumentRecord<Document>?

    init(document: Document) { self.document = document }

    init(localDocument: Document) {
        document = localDocument
        pending = NutritionPendingWrite(expectedRevision: 0, document: localDocument)
    }

    mutating func edit(_ value: Document) {
        guard document != value else { return }
        document = value
        if pending == nil && conflict == nil {
            pending = NutritionPendingWrite(expectedRevision: acknowledged?.revision ?? 0, document: value)
        }
    }

    mutating func commitFirstWrite() {
        if acknowledged?.revision ?? 0 == 0 && pending == nil && conflict == nil {
            pending = NutritionPendingWrite(expectedRevision: 0, document: document)
        }
    }

    mutating func receive(_ remote: NutritionDocumentRecord<Document>) throws {
        guard remote.revision >= 0 else { throw NutritionDiaryError.invalidResponse }
        if let known = acknowledged {
            if remote.revision < known.revision { return }
            guard remote.revision != known.revision || remote.document == known.document else {
                throw NutritionDiaryError.invalidResponse
            }
        }
        if conflict != nil {
            guard remote.revision >= (conflict?.revision ?? 0) else { return }
            conflict = remote
        } else if let pending {
            if remote.revision == pending.expectedRevision &&
                (acknowledged == nil || remote.document == acknowledged?.document) {
                acknowledged = remote
            } else {
                conflict = remote
            }
        } else {
            document = remote.document
            acknowledged = remote
        }
    }

    mutating func acknowledge(requestID: UUID, record: NutritionDocumentRecord<Document>) throws {
        guard let sent = pending, sent.requestID == requestID else { return }
        guard sent.expectedRevision < Int64.max, record.revision == sent.expectedRevision + 1,
              record.document == sent.document else { throw NutritionDiaryError.invalidResponse }
        if let latest = conflict, latest.revision == record.revision, latest.document != record.document {
            throw NutritionDiaryError.invalidResponse
        }
        if let known = acknowledged, known.revision == record.revision, known.document != record.document {
            throw NutritionDiaryError.invalidResponse
        }
        if let latest = conflict, latest.revision > record.revision {
            pending = nil
            return
        }
        if let known = acknowledged, known.revision > record.revision {
            pending = nil
            if document != known.document { conflict = known }
            return
        }
        acknowledged = record
        pending = nil
        conflict = nil
        if document != record.document {
            pending = NutritionPendingWrite(expectedRevision: record.revision, document: document)
        }
    }

    mutating func reject(requestID: UUID, remote: NutritionDocumentRecord<Document>) throws {
        guard pending?.requestID == requestID else { return }
        guard remote.revision >= (acknowledged?.revision ?? 0),
              remote.revision >= (conflict?.revision ?? 0) else { throw NutritionDiaryError.invalidResponse }
        try receive(remote)
        conflict = remote
    }

    mutating func resolve(usingServer: Bool, expected: NutritionDocumentRecord<Document>) throws {
        guard conflict == expected else { throw NutritionDiaryError.staleConflict }
        acknowledged = expected
        conflict = nil
        pending = nil
        if usingServer { document = expected.document }
        if document != expected.document {
            pending = NutritionPendingWrite(expectedRevision: expected.revision, document: document)
        }
    }

    func isValid(documentIsValid: (Document) -> Bool) -> Bool {
        guard documentIsValid(document) else { return false }
        if let acknowledged {
            guard acknowledged.revision >= 0, documentIsValid(acknowledged.document) else { return false }
            if pending == nil && conflict == nil && document != acknowledged.document { return false }
        }
        if let pending {
            guard pending.expectedRevision >= 0, pending.expectedRevision < Int64.max,
                  pending.expectedRevision <= (acknowledged?.revision ?? 0), documentIsValid(pending.document) else { return false }
        }
        if let conflict {
            guard conflict.revision >= (acknowledged?.revision ?? 0), documentIsValid(conflict.document) else { return false }
        }
        return true
    }
}

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
