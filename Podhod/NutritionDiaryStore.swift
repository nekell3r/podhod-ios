import Foundation
import Observation

struct NutritionDiaryArchive: Codable, Equatable {
    var version = 1
    var accountID: String?
    var days: [RevisionedDocumentState<NutritionDayDocument>] = []
    var goals = RevisionedDocumentState(document: NutritionGoalsDocument())
    var recipes = RevisionedDocumentState(document: NutritionRecipesDocument())
    var preferences = RevisionedDocumentState(document: NutritionPreferencesDocument())

    var isValid: Bool {
        version == 1 && (accountID.map { !$0.isEmpty } ?? true) && Set(days.map { $0.document.date }).count == days.count && days.allSatisfy { state in
            state.isValid(documentIsValid: { $0.isValid && $0.date == state.document.date }) &&
                (state.pending.map { $0.document.preservesSnapshot(of: state.document) } ?? true) &&
                (state.acknowledged.map { $0.revision == 0 || $0.document.preservesSnapshot(of: state.document) } ?? true)
        } && goals.isValid(documentIsValid: { $0.isValid }) && recipes.isValid(documentIsValid: { $0.isValid }) &&
            preferences.isValid(documentIsValid: { $0.isValid })
    }
}

@MainActor @Observable
final class NutritionDiaryStore {
    private(set) var archive = NutritionDiaryArchive()
    private(set) var loadFailed = false
    var errorMessage: String?
    @ObservationIgnored let fileURL: URL
    @ObservationIgnored var accountStorageError: String?

    init(fileURL: URL, accountStorageError: String? = nil) {
        self.fileURL = fileURL
        self.accountStorageError = accountStorageError
        do {
            guard accountStorageError == nil else { throw NutritionDiaryError.invalidArchive }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let saved = try JSONDecoder().decode(NutritionDiaryArchive.self, from: Data(contentsOf: fileURL))
                guard saved.version == 1 else { throw NutritionDiaryError.unsupportedArchive }
                guard saved.isValid else { throw NutritionDiaryError.invalidArchive }
                archive = saved
            } else {
                let legacy = fileURL.deletingLastPathComponent().appending(path: "nutrition-preferences.json")
                if FileManager.default.fileExists(atPath: legacy.path) {
                    let data = try Data(contentsOf: legacy)
                    let document = try JSONDecoder().decode(NutritionPreferencesDocument.self, from: data)
                    guard document.isValid else { throw NutritionDiaryError.invalidArchive }
                    let backup = fileURL.deletingLastPathComponent().appending(path: "NutritionBackups/\(UUID())", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
                    try data.write(to: backup.appending(path: "nutrition-preferences.v1.json"), options: .atomic)
                    var migrated = archive
                    migrated.preferences.edit(document)
                    try persist(migrated)
                }
            }
        } catch {
            loadFailed = true
            errorMessage = (error as? NutritionDiaryError)?.localizedDescription ?? NutritionDiaryError.invalidArchive.localizedDescription
        }
    }

    @discardableResult
    func bindAccount(_ id: String) -> Bool {
        guard !id.isEmpty, archive.accountID == nil || archive.accountID == id else {
            return fail(NutritionDiaryError.accountMismatch)
        }
        guard archive.accountID != id else { return !loadFailed && accountStorageError == nil }
        var changed = archive
        changed.accountID = id
        return save(changed)
    }

    func exportGuestDays(_ range: NutritionExportRange) throws -> NutritionDiaryExport {
        guard !loadFailed, accountStorageError == nil else { throw NutritionDiaryError.invalidArchive }
        guard archive.accountID == nil else { throw NutritionDiaryError.accountMismatch }
        let days = range.dayKeys.map { key in
            let state = archive.days.first { $0.document.date == key }
            return RevisionedDocumentRecord(revision: state?.acknowledged?.revision ?? 0,
                document: state?.document ?? NutritionDayDocument(date: key, timezone: range.timezone))
        }
        return NutritionDiaryExport(source: "local-guest", days: days)
    }

    func day(_ key: String, timezone: String) -> NutritionDayDocument {
        if let state = archive.days.first(where: { $0.document.date == key }),
           state.acknowledged?.revision ?? 0 > 0 || state.pending != nil || state.conflict != nil {
            return state.document
        }
        return NutritionDayDocument(date: key, timezone: timezone, goal: archive.goals.document.goal(on: key))
    }

    @discardableResult
    func saveEntry(_ entry: NutritionDiaryEntry, on key: String, timezone: String, expected: NutritionDiaryEntry? = nil) -> Bool {
        var document = day(key, timezone: timezone)
        guard document.entries.first(where: { $0.id == entry.id }) == expected else { return fail(NutritionDiaryError.staleConflict) }
        document.entries.removeAll { $0.id == entry.id }
        document.entries.append(entry)
        return saveDay(document)
    }

    @discardableResult
    func removeEntry(_ id: UUID, on key: String, expected: NutritionDiaryEntry? = nil) -> Bool {
        guard var document = archive.days.first(where: { $0.document.date == key })?.document else { return false }
        guard expected == nil || document.entries.first(where: { $0.id == id }) == expected else { return fail(NutritionDiaryError.staleConflict) }
        document.entries.removeAll { $0.id == id }
        return saveDay(document)
    }

    @discardableResult
    func saveDay(_ document: NutritionDayDocument) -> Bool {
        var changed = archive
        if let index = changed.days.firstIndex(where: { $0.document.date == document.date }) {
            let existing = changed.days[index]
            let committed = existing.acknowledged?.revision ?? 0 > 0 || existing.pending != nil || existing.conflict != nil
            guard !committed || document.preservesSnapshot(of: existing.document) else {
                errorMessage = NutritionDiaryError.immutableSnapshot.localizedDescription
                return false
            }
            changed.days[index].edit(document)
            changed.days[index].commitFirstWrite()
        } else {
            changed.days.append(RevisionedDocumentState(localDocument: document))
        }
        return save(changed)
    }

    @discardableResult
    func saveGoal(_ goal: NutritionGoal) -> Bool {
        var changed = archive
        var document = changed.goals.document
        document.goals.removeAll { $0.id == goal.id }
        document.goals.append(goal)
        document.goals.sort { $0.effectiveFrom < $1.effectiveFrom }
        changed.goals.edit(document)
        return save(changed)
    }

    @discardableResult
    func removeGoal(_ id: UUID, expected: NutritionGoal? = nil) -> Bool {
        var changed = archive
        var document = changed.goals.document
        guard expected == nil || document.goals.first(where: { $0.id == id }) == expected else { return fail(NutritionDiaryError.staleConflict) }
        document.goals.removeAll { $0.id == id }
        changed.goals.edit(document)
        return save(changed)
    }

    @discardableResult
    func saveRecipe(_ recipe: NutritionOwnRecipe, expected: NutritionOwnRecipe? = nil) -> Bool {
        var changed = archive
        var document = changed.recipes.document
        guard document.recipes.first(where: { $0.id == recipe.id }) == expected else { return fail(NutritionDiaryError.staleConflict) }
        document.recipes.removeAll { $0.id == recipe.id }
        document.recipes.append(recipe)
        changed.recipes.edit(document)
        return save(changed)
    }

    @discardableResult
    func removeRecipe(_ id: UUID, expected: NutritionOwnRecipe? = nil) -> Bool {
        var changed = archive
        var document = changed.recipes.document
        guard expected == nil || document.recipes.first(where: { $0.id == id }) == expected else { return fail(NutritionDiaryError.staleConflict) }
        document.recipes.removeAll { $0.id == id }
        changed.recipes.edit(document)
        return save(changed)
    }

    @discardableResult
    func savePreferences(_ document: NutritionPreferencesDocument) -> Bool {
        var changed = archive
        changed.preferences.edit(document)
        return save(changed)
    }

    @discardableResult
    func receiveDay(_ remote: RevisionedDocumentRecord<NutritionDayDocument>) -> Bool {
        var changed = archive
        do {
            if let index = changed.days.firstIndex(where: { $0.document.date == remote.document.date }) {
                try changed.days[index].receive(remote)
            } else {
                var state = RevisionedDocumentState(document: remote.document)
                try state.receive(remote)
                changed.days.append(state)
            }
            return save(changed)
        } catch { return fail(error) }
    }

    @discardableResult
    func acknowledgeDay(requestID: UUID, record: RevisionedDocumentRecord<NutritionDayDocument>) -> Bool {
        guard let index = archive.days.firstIndex(where: { $0.document.date == record.document.date }) else { return false }
        var changed = archive
        do {
            try changed.days[index].acknowledge(requestID: requestID, record: record)
            return save(changed)
        } catch { return fail(error) }
    }

    @discardableResult
    func rejectDay(requestID: UUID, record: RevisionedDocumentRecord<NutritionDayDocument>) -> Bool {
        guard let index = archive.days.firstIndex(where: { $0.document.date == record.document.date }) else { return false }
        var changed = archive
        do {
            try changed.days[index].reject(requestID: requestID, remote: record)
            return save(changed)
        } catch { return fail(error) }
    }

    @discardableResult
    func receive<Document>(_ remote: RevisionedDocumentRecord<Document>,
                           at path: WritableKeyPath<NutritionDiaryArchive, RevisionedDocumentState<Document>>) -> Bool {
        var changed = archive
        do {
            try changed[keyPath: path].receive(remote)
            return save(changed)
        } catch { return fail(error) }
    }

    @discardableResult
    func acknowledge<Document>(requestID: UUID, record: RevisionedDocumentRecord<Document>,
                               at path: WritableKeyPath<NutritionDiaryArchive, RevisionedDocumentState<Document>>) -> Bool {
        var changed = archive
        do {
            try changed[keyPath: path].acknowledge(requestID: requestID, record: record)
            return save(changed)
        } catch { return fail(error) }
    }

    @discardableResult
    func reject<Document>(requestID: UUID, record: RevisionedDocumentRecord<Document>,
                          at path: WritableKeyPath<NutritionDiaryArchive, RevisionedDocumentState<Document>>) -> Bool {
        var changed = archive
        do {
            try changed[keyPath: path].reject(requestID: requestID, remote: record)
            return save(changed)
        } catch { return fail(error) }
    }

    @discardableResult
    func resolveDay(_ key: String, usingServer: Bool, expected: RevisionedDocumentRecord<NutritionDayDocument>) -> Bool {
        guard let index = archive.days.firstIndex(where: { $0.document.date == key }), expected.document.date == key else { return false }
        var changed = archive
        do {
            if !usingServer && expected.revision > 0 && !changed.days[index].document.preservesSnapshot(of: expected.document) {
                throw NutritionDiaryError.immutableSnapshot
            }
            try backUpConflict(archive)
            try changed.days[index].resolve(usingServer: usingServer, expected: expected)
            return save(changed)
        } catch { return fail(error) }
    }

    @discardableResult
    func resolve<Document>(usingServer: Bool, expected: RevisionedDocumentRecord<Document>,
                           at path: WritableKeyPath<NutritionDiaryArchive, RevisionedDocumentState<Document>>) -> Bool {
        var changed = archive
        do {
            try backUpConflict(archive)
            try changed[keyPath: path].resolve(usingServer: usingServer, expected: expected)
            return save(changed)
        } catch { return fail(error) }
    }

    private func backUpConflict(_ snapshot: NutritionDiaryArchive) throws {
        guard !loadFailed, accountStorageError == nil else { throw NutritionDiaryError.invalidArchive }
        let directory = fileURL.deletingLastPathComponent().appending(path: "NutritionConflicts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: directory.appending(path: "\(UUID()).json"), options: .atomic)
    }

    private func save(_ changed: NutritionDiaryArchive) -> Bool {
        guard !loadFailed, accountStorageError == nil else { return fail(NutritionDiaryError.invalidArchive) }
        guard changed.isValid else { return fail(NutritionDiaryError.invalidDocument) }
        guard changed != archive else {
            errorMessage = nil
            return true
        }
        do {
            let newConflict = changed.goals.conflict != archive.goals.conflict ||
                changed.recipes.conflict != archive.recipes.conflict || changed.preferences.conflict != archive.preferences.conflict ||
                changed.days.contains { state in
                    state.conflict != nil && state.conflict != archive.days.first(where: { $0.document.date == state.document.date })?.conflict
                }
            if newConflict { try backUpConflict(changed) }
            try persist(changed)
            return true
        } catch { return fail(NutritionDiaryError.saveFailed) }
    }

    private func persist(_ changed: NutritionDiaryArchive) throws {
        guard changed.isValid else { throw NutritionDiaryError.invalidArchive }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(changed).write(to: fileURL, options: .atomic)
        archive = changed
        errorMessage = nil
    }

    private func fail(_ error: Error) -> Bool {
        errorMessage = error.localizedDescription
        return false
    }
}
