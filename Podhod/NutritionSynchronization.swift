import Foundation
import Observation

enum NutritionSyncResource: Equatable, Identifiable {
    case day(String), goals, recipes, preferences
    var id: String {
        switch self {
        case .day(let key): "day/\(key)"
        case .goals: "goals"
        case .recipes: "recipes"
        case .preferences: "preferences"
        }
    }
    var title: String {
        switch self {
        case .day(let key): "Дневник за \(key)"
        case .goals: "Цели питания"
        case .recipes: "Свои рецепты"
        case .preferences: "Избранное"
        }
    }
}

@MainActor @Observable
final class NutritionSynchronization {
    private(set) var isSyncing = false
    private(set) var message = "Сохранено на iPhone"
    private(set) var resolutionError: String?
    var focusedDay: String?
    @ObservationIgnored private let store: NutritionDiaryStore
    @ObservationIgnored private let auth: CloudAuthentication
    @ObservationIgnored private let accountID: String?
    @ObservationIgnored private var lastRead: Date?
    @ObservationIgnored private var lastFocusedDay: String?
    private var requiresUpgrade = false

    init(store: NutritionDiaryStore, auth: CloudAuthentication, accountID: String?) {
        self.store = store
        self.auth = auth
        self.accountID = accountID
    }

    var conflicts: [NutritionSyncResource] {
        var result: [NutritionSyncResource] = []
        if store.archive.goals.conflict != nil { result.append(.goals) }
        if store.archive.recipes.conflict != nil { result.append(.recipes) }
        if store.archive.preferences.conflict != nil { result.append(.preferences) }
        result += store.archive.days.filter { $0.conflict != nil }.map { .day($0.document.date) }
        return result
    }

    var canResolve: Bool { auth.signedIn && accountID != nil && !isSyncing && !store.loadFailed }

    var hasPendingWrites: Bool {
        store.archive.goals.pending != nil || store.archive.recipes.pending != nil || store.archive.preferences.pending != nil ||
            store.archive.days.contains { $0.pending != nil }
    }

    var status: String {
        if store.loadFailed { return store.errorMessage ?? NutritionDiaryError.invalidArchive.localizedDescription }
        if !auth.signedIn { return "Сохранено на iPhone · гостевой режим" }
        if !conflicts.isEmpty { return "Есть конфликт питания · обе версии сохранены" }
        if requiresUpgrade { return "Обнови приложение для синхронизации питания. Локальные записи сохранены." }
        if isSyncing { return "Синхронизация питания…" }
        if hasPendingWrites { return "Сохранено на iPhone · ожидает синхронизации" }
        return message
    }

    func canKeepLocal(_ resource: NutritionSyncResource) -> Bool {
        guard case .day(let key) = resource,
              let state = store.archive.days.first(where: { $0.document.date == key }), let remote = state.conflict else { return true }
        return remote.revision == 0 || state.document.preservesSnapshot(of: remote.document)
    }

    func synchronize() async {
        guard auth.signedIn, accountID != nil, !isSyncing, !store.loadFailed, store.accountStorageError == nil else { return }
        let uploadable = (store.archive.goals.pending != nil && store.archive.goals.conflict == nil) ||
            (store.archive.recipes.pending != nil && store.archive.recipes.conflict == nil) ||
            (store.archive.preferences.pending != nil && store.archive.preferences.conflict == nil) ||
            store.archive.days.contains { $0.pending != nil && $0.conflict == nil }
        guard uploadable || lastFocusedDay != focusedDay || Date().timeIntervalSince(lastRead ?? .distantPast) >= 30 else { return }
        isSyncing = true
        defer { isSyncing = false }
        let api = TrainingCloudAPI(auth: auth)
        do {
            try await verifyAccount(api)
            try await synchronizeDocument(at: \.goals, read: { try await api.nutritionGoals() }, write: { try await api.saveNutritionGoals($0) })
            try await synchronizeDocument(at: \.recipes, read: { try await api.nutritionRecipes() }, write: { try await api.saveNutritionRecipes($0) })
            try await synchronizeDocument(at: \.preferences, read: { try await api.nutritionPreferences() }, write: { try await api.saveNutritionPreferences($0) })
            let timezone = TimeZone.autoupdatingCurrent.identifier
            let today = TrainingCalendar(timezone: timezone).dayKey(for: Date())
            var keys = Set(store.archive.days.filter { $0.pending != nil }.map { $0.document.date })
            keys.insert(today)
            if let focusedDay, TrainingCalendar(timezone: timezone).date(from: focusedDay) != nil { keys.insert(focusedDay) }
            for key in keys.sorted() { try await synchronizeDay(key, api: api, timezone: timezone) }
            lastRead = Date()
            lastFocusedDay = focusedDay
            message = "Питание синхронизировано"
            requiresUpgrade = false
        } catch is CancellationError {
            return
        } catch let failure as TrainingCloudFailure where failure.code == "upgrade_required" {
            requiresUpgrade = true
        } catch {
            message = "Сохранено на iPhone · синхронизация питания недоступна"
        }
    }

    func exportDays(_ range: NutritionExportRange) async throws -> NutritionDiaryExport {
        guard !isSyncing, !store.loadFailed, store.accountStorageError == nil else { throw NutritionDiaryError.invalidArchive }
        if !auth.signedIn {
            return try store.exportGuestDays(range)
        }
        await synchronize()
        guard !isSyncing else { throw NutritionDiaryError.unsyncedExport }
        isSyncing = true
        defer { isSyncing = false }
        let api = TrainingCloudAPI(auth: auth)
        try await verifyAccount(api)
        var days: [RevisionedDocumentRecord<NutritionDayDocument>] = []
        for key in range.dayKeys {
            guard !store.archive.days.contains(where: { $0.document.date == key && ($0.pending != nil || $0.conflict != nil) }) else {
                throw NutritionDiaryError.unsyncedExport
            }
            let remote = try await api.nutritionDay(key, timezone: range.timezone)
            try Task.checkCancellation()
            guard store.receiveDay(remote),
                  !store.archive.days.contains(where: { $0.document.date == key && ($0.pending != nil || $0.conflict != nil) }) else {
                throw NutritionDiaryError.unsyncedExport
            }
            days.append(remote)
        }
        return NutritionDiaryExport(source: "server", days: days)
    }

    private func verifyAccount(_ api: TrainingCloudAPI) async throws {
        try Task.checkCancellation()
        let profile = try await api.profile()
        try Task.checkCancellation()
        guard profile.id == accountID, store.bindAccount(profile.id) else { throw NutritionDiaryError.accountMismatch }
    }

    private func synchronizeDocument<Document>(
        at path: WritableKeyPath<NutritionDiaryArchive, RevisionedDocumentState<Document>>,
        read: @MainActor () async throws -> RevisionedDocumentRecord<Document>,
        write: @MainActor (PendingDocumentWrite<Document>) async throws -> RevisionedDocumentRecord<Document>
    ) async throws {
        guard store.archive[keyPath: path].conflict == nil else { return }
        if let pending = store.archive[keyPath: path].pending {
            do {
                let response = try await write(pending)
                try Task.checkCancellation()
                guard store.acknowledge(requestID: pending.requestID, record: response, at: path) else { throw NutritionDiaryError.saveFailed }
            } catch let failure as TrainingCloudFailure where failure.status == 409 && failure.code != "upgrade_required" {
                let remote = try await read()
                try Task.checkCancellation()
                guard store.reject(requestID: pending.requestID, record: remote, at: path) else { throw NutritionDiaryError.invalidResponse }
                return
            }
        }
        let remote = try await read()
        try Task.checkCancellation()
        guard store.receive(remote, at: path) else { throw NutritionDiaryError.invalidResponse }
    }

    private func synchronizeDay(_ key: String, api: TrainingCloudAPI, timezone: String) async throws {
        let state = store.archive.days.first { $0.document.date == key }
        guard state?.conflict == nil else { return }
        if let pending = state?.pending {
            do {
                let response = try await api.saveNutritionDay(pending)
                try Task.checkCancellation()
                guard store.acknowledgeDay(requestID: pending.requestID, record: response) else { throw NutritionDiaryError.saveFailed }
            } catch let failure as TrainingCloudFailure where failure.status == 409 && failure.code != "upgrade_required" {
                let remote = try await api.nutritionDay(key, timezone: timezone)
                try Task.checkCancellation()
                guard store.rejectDay(requestID: pending.requestID, record: remote) else { throw NutritionDiaryError.invalidResponse }
                return
            }
        }
        let remote = try await api.nutritionDay(key, timezone: timezone)
        try Task.checkCancellation()
        guard store.receiveDay(remote) else { throw NutritionDiaryError.invalidResponse }
    }

    func resolve(_ resource: NutritionSyncResource, usingServer: Bool) async {
        guard auth.signedIn, accountID != nil, !isSyncing, !store.loadFailed,
              usingServer || canKeepLocal(resource) else { return }
        isSyncing = true
        let api = TrainingCloudAPI(auth: auth)
        resolutionError = nil
        do {
            try await verifyAccount(api)
            switch resource {
            case .day(let key):
                let expected = store.archive.days.first { $0.document.date == key }?.conflict
                let remote = try await api.nutritionDay(key, timezone: TimeZone.autoupdatingCurrent.identifier)
                try Task.checkCancellation()
                if remote == expected {
                    guard store.resolveDay(key, usingServer: usingServer, expected: remote) else { throw NutritionDiaryError.saveFailed }
                } else {
                    guard store.receiveDay(remote) else { throw NutritionDiaryError.invalidResponse }
                    throw NutritionDiaryError.staleConflict
                }
            case .goals:
                try await resolveDocument(at: \.goals, usingServer: usingServer, read: { try await api.nutritionGoals() })
            case .recipes:
                try await resolveDocument(at: \.recipes, usingServer: usingServer, read: { try await api.nutritionRecipes() })
            case .preferences:
                try await resolveDocument(at: \.preferences, usingServer: usingServer, read: { try await api.nutritionPreferences() })
            }
            lastRead = nil
            message = "Выбранная версия сохранена"
        } catch {
            message = error.localizedDescription
            resolutionError = error.localizedDescription
        }
        isSyncing = false
        if !conflicts.contains(resource) { await synchronize() }
    }

    private func resolveDocument<Document>(at path: WritableKeyPath<NutritionDiaryArchive, RevisionedDocumentState<Document>>,
                                           usingServer: Bool, read: @MainActor () async throws -> RevisionedDocumentRecord<Document>) async throws {
        let expected = store.archive[keyPath: path].conflict
        let remote = try await read()
        try Task.checkCancellation()
        guard remote == expected else {
            guard store.receive(remote, at: path) else { throw NutritionDiaryError.invalidResponse }
            throw NutritionDiaryError.staleConflict
        }
        guard store.resolve(usingServer: usingServer, expected: remote, at: path) else { throw NutritionDiaryError.saveFailed }
    }
}
