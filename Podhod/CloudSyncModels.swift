import Foundation

struct TrainingTemplateRecord: Codable, Equatable {
    var revision: Int64
    var days: [TrainingDay]
    var structureVersion: Int?

    var hasValidStructure: Bool {
        (0...1).contains(structureVersion ?? 0) && days.map(\.weekday).sorted() == Array(1...7) &&
            (structureVersion == 1 || days.allSatisfy { !$0.hasStructureMetadata }) &&
            days.allSatisfy { $0.hasValidPlannedStructure && $0.context?.cycle == nil }
    }
}

struct ActiveWorkoutState: Codable, Equatable {
    var session: WorkoutSession
    var restUntil: Date?
    var restKind: WorkoutRestKind?
    var restExerciseID: UUID?
}

struct ActiveWorkoutRecord: Codable, Equatable {
    var revision: Int64
    var state: ActiveWorkoutState?
}

struct TrainingCloudProfile: Decodable {
    var id: String
    var timezone: String?
}


struct RevisionedDocumentRecord<Document: Codable & Equatable>: Codable, Equatable {
    var revision: Int64
    var document: Document
}

struct PendingDocumentWrite<Document: Codable & Equatable>: Codable, Equatable {
    var expectedRevision: Int64
    var requestID = UUID()
    var document: Document
}

struct RevisionedDocumentState<Document: Codable & Equatable>: Codable, Equatable {
    private(set) var document: Document
    private(set) var acknowledged: RevisionedDocumentRecord<Document>?
    private(set) var pending: PendingDocumentWrite<Document>?
    private(set) var conflict: RevisionedDocumentRecord<Document>?

    init(document: Document) { self.document = document }

    init(localDocument: Document) {
        document = localDocument
        pending = PendingDocumentWrite(expectedRevision: 0, document: localDocument)
    }

    mutating func edit(_ value: Document) {
        guard document != value else { return }
        document = value
        if pending == nil && conflict == nil {
            pending = PendingDocumentWrite(expectedRevision: acknowledged?.revision ?? 0, document: value)
        }
    }

    mutating func commitFirstWrite() {
        if acknowledged?.revision ?? 0 == 0 && pending == nil && conflict == nil {
            pending = PendingDocumentWrite(expectedRevision: 0, document: document)
        }
    }

    mutating func receive(_ remote: RevisionedDocumentRecord<Document>) throws {
        guard remote.revision >= 0 else { throw CloudDocumentError.invalidResponse }
        if let known = acknowledged {
            if remote.revision < known.revision { return }
            guard remote.revision != known.revision || remote.document == known.document else {
                throw CloudDocumentError.invalidResponse
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

    mutating func acknowledge(requestID: UUID, record: RevisionedDocumentRecord<Document>) throws {
        guard let sent = pending, sent.requestID == requestID else { return }
        guard sent.expectedRevision < Int64.max, record.revision == sent.expectedRevision + 1,
              record.document == sent.document else { throw CloudDocumentError.invalidResponse }
        if let latest = conflict, latest.revision == record.revision, latest.document != record.document {
            throw CloudDocumentError.invalidResponse
        }
        if let known = acknowledged, known.revision == record.revision, known.document != record.document {
            throw CloudDocumentError.invalidResponse
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
            pending = PendingDocumentWrite(expectedRevision: record.revision, document: document)
        }
    }

    mutating func reject(requestID: UUID, remote: RevisionedDocumentRecord<Document>) throws {
        guard pending?.requestID == requestID else { return }
        guard remote.revision >= (acknowledged?.revision ?? 0),
              remote.revision >= (conflict?.revision ?? 0) else { throw CloudDocumentError.invalidResponse }
        try receive(remote)
        conflict = remote
    }

    mutating func resolve(usingServer: Bool, expected: RevisionedDocumentRecord<Document>) throws {
        guard conflict == expected else { throw CloudDocumentError.staleConflict }
        acknowledged = expected
        conflict = nil
        pending = nil
        if usingServer { document = expected.document }
        if document != expected.document {
            pending = PendingDocumentWrite(expectedRevision: expected.revision, document: document)
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

enum CloudDocumentError: LocalizedError {
    case invalidResponse, staleConflict

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Не удалось проверить ответ сервера. Записи на iPhone сохранены."
        case .staleConflict: "Версия изменилась. Проверь конфликт ещё раз."
        }
    }
}
