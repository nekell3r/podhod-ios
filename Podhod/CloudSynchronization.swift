import Foundation
import Observation

private struct TrainingSyncCheckpoint: Codable {
    var accountID: String?
    var template: TrainingTemplateRecord?
    var weeks: [TrainingWeek] = []
    var active: ActiveWorkoutRecord?
    var historyIDs: [UUID] = []
    var pendingHistoryRecovery: HistoryRecoveryWrite?
    var proteinDays: [ProteinDayRecord]?
}

struct TrainingSyncConflict {
    enum Resource { case template, week(String), active, history, protein(String), cycle, savedTemplates, creatine(String) }
    var resource: Resource
    var message: String
    var canChooseServer: Bool
    var canChooseLocal: Bool
    var history: HistoryConflict?
}

struct HistoryConflict {
    let local: WorkoutSession
    let server: WorkoutSession
    let serverVersion: String?
}

@MainActor @Observable
final class CloudSynchronization {
    let store: WorkoutStore
    let auth: CloudAuthentication
    let protein: ProteinTracker
    private(set) var isSyncing = false
    private(set) var message = "Сохранено на iPhone"
    private(set) var conflict: TrainingSyncConflict?
    private(set) var lastSyncedAt: Date?
    var focusedWeekStart: String?
    @ObservationIgnored var accountDiscovered: ((String) -> Bool)?
    var accountID: String? { checkpoint.accountID }
    var storageReady: Bool { checkpointError == nil }
    @ObservationIgnored private var checkpoint = TrainingSyncCheckpoint()
    @ObservationIgnored private var checkpointError: String?
    @ObservationIgnored private var lastCheckpointData: Data?
    @ObservationIgnored private var lastHistoryRead: Date?
    @ObservationIgnored private var lastCycleRead: Date?
    @ObservationIgnored private var lastTemplatesRead: Date?
    @ObservationIgnored private var lastCreatineRead: Date?
    @ObservationIgnored private let fileURL: URL

    init(store: WorkoutStore, auth: CloudAuthentication, protein: ProteinTracker) {
        self.store = store
        self.auth = auth
        self.protein = protein
        fileURL = store.fileURL.deletingLastPathComponent().appendingPathComponent("sync-state.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                checkpoint = try JSONDecoder().decode(TrainingSyncCheckpoint.self, from: data)
                if checkpoint.pendingHistoryRecovery != nil && checkpoint.accountID?.isEmpty != false {
                    throw TrainingError.invalidArchive
                }
                lastCheckpointData = data
            }
            catch { checkpointError = "Не удалось прочитать состояние синхронизации. Локальные тренировки сохранены." }
        }
    }

    var status: String {
        if store.loadFailed || store.accountStorageError != nil { return "Не удалось открыть локальные тренировки" }
        if let checkpointError { return checkpointError }
        if !auth.signedIn {
            return auth.verifiedAccountID == nil ? "Сохранено на iPhone" : "Сохранено на iPhone · нужно войти для синхронизации"
        }
        if conflict?.history != nil { return message }
        if conflict != nil { return "Есть конфликт изменений" }
        if isSyncing { return "Синхронизация…" }
        if hasLocalChanges && message == "Синхронизировано" { return "Сохранено на iPhone · ожидает синхронизации" }
        return message
    }

    private var hasLocalChanges: Bool {
        if !same(store.archive.week, checkpoint.template?.days) ||
            (store.archive.templateStructureVersion ?? 0) != (checkpoint.template?.structureVersion ?? 0) { return true }
        if store.cycleState.pending != nil || store.cycleState.conflict != nil { return true }
        if store.savedTemplatesState.pending != nil || store.savedTemplatesState.conflict != nil { return true }
        if (store.archive.creatineDays ?? [:]).values.contains(where: { $0.pending != nil || $0.conflict != nil }) { return true }
        if !same(store.activeWorkoutState, checkpoint.active?.state) { return true }
        if store.archive.history.contains(where: { !checkpoint.historyIDs.contains($0.id) }) { return true }
        if protein.days.contains(where: { local in
            guard let known = checkpoint.proteinDays?.first(where: { $0.date == local.date }) else { return true }
            return !same(local.morningTakenAt, known.morningTakenAt) || !same(local.eveningTakenAt, known.eveningTakenAt)
        }) { return true }
        return (store.archive.scheduledWeeks ?? []).contains { local in
            guard let known = checkpoint.weeks.first(where: { $0.weekStart == local.weekStart }) else { return true }
            return !same(local.workouts, known.workouts) || local.timezone != known.timezone ||
                (local.structureVersion ?? 0) != (known.structureVersion ?? 0)
        }
    }

    func synchronize() async {
        guard auth.signedIn, !isSyncing else { return }
        if conflict != nil, let verifiedID = auth.verifiedAccountID, verifiedID == checkpoint.accountID {
            _ = accountDiscovered?(verifiedID)
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        let api = TrainingCloudAPI(auth: auth)
        var currentResource: TrainingSyncConflict.Resource?
        do {
            let profile = try await api.profile()
            if accountDiscovered?(profile.id) == true { return }
            guard conflict == nil, checkpointError == nil, !store.loadFailed, store.accountStorageError == nil else { return }
            guard checkpoint.accountID == nil || checkpoint.accountID == profile.id else {
                message = "Этот iPhone связан с другим аккаунтом. Локальные данные не отправлены."
                return
            }
            if checkpoint.accountID == nil {
                checkpoint.accountID = profile.id
                try persistCheckpoint()
            }
            if let change = checkpoint.pendingHistoryRecovery {
                try await sendHistoryRecovery(change, api: api)
            }
            if Date().timeIntervalSince(lastHistoryRead ?? .distantPast) >= 60 ||
                store.archive.history.contains(where: { !checkpoint.historyIDs.contains($0.id) }) {
                try await synchronizeHistory(api)
            }
            guard conflict == nil else { return }
            currentResource = .cycle
            try await synchronizeCycle(api)
            guard conflict == nil else { return }
            let localTemplateAtStart = store.archive.week
            currentResource = .template
            try await synchronizeTemplate(api)
            guard conflict == nil else { return }
            let currentWeek = store.trainingCalendar.dayKey(for: store.trainingCalendar.weekStart(containing: Date()))
            let weeks = (store.archive.scheduledWeeks ?? []).filter { week in
                if week.weekStart == currentWeek || week.weekStart == focusedWeekStart { return true }
                guard let known = checkpoint.weeks.first(where: { $0.weekStart == week.weekStart }) else { return true }
                return !same(week.workouts, known.workouts) || week.timezone != known.timezone ||
                    (week.structureVersion ?? 0) != (known.structureVersion ?? 0)
            }
            for week in weeks {
                currentResource = .week(week.weekStart)
                try await synchronizeWeek(week.weekStart, template: localTemplateAtStart, api: api)
                if conflict != nil { return }
            }
            currentResource = .active
            try await synchronizeActive(api)
            guard conflict == nil else { return }
            if !protein.loadFailed {
                var dates = Set(protein.days.filter { local in
                    guard let known = checkpoint.proteinDays?.first(where: { $0.date == local.date }) else { return true }
                    return !same(local.morningTakenAt, known.morningTakenAt) || !same(local.eveningTakenAt, known.eveningTakenAt)
                }.map(\.date))
                dates.insert(protein.day(on: Date()).date)
                for key in dates.sorted() {
                    currentResource = .protein(key)
                    try await synchronizeProteinDay(key, api: api)
                    if conflict != nil { return }
                }
            }
            currentResource = .savedTemplates
            try await synchronizeSavedTemplates(api)
            guard conflict == nil else { return }
            var creatineDates = Set((store.archive.creatineDays ?? [:]).filter {
                $0.value.pending != nil || $0.value.conflict != nil
            }.keys)
            let today = store.trainingCalendar.dayKey(for: Date())
            if Date().timeIntervalSince(lastCreatineRead ?? .distantPast) >= 30 { creatineDates.insert(today) }
            for key in creatineDates.sorted() {
                currentResource = .creatine(key)
                try await synchronizeCreatine(key, api: api)
                guard conflict == nil else { return }
            }
            if creatineDates.contains(today) { lastCreatineRead = Date() }
            if conflict == nil {
                lastSyncedAt = Date()
                message = "Синхронизировано"
            }
        } catch let failure as TrainingCloudFailure where failure.status == 409 {
            if case .active? = currentResource,
               failure.code == "upgrade_required" || failure.code == "set_removal_conflict" || failure.code == "superset_conflict" {
                do {
                    let remote = try await api.active()
                    try saveConflictBackup(remote: remote)
                    activeConflict(local: store.activeWorkoutState, remote: remote.state)
                    if failure.code == "upgrade_required" { conflict?.canChooseLocal = false }
                    message = "Записи подходов отличаются. Выбери версию после проверки конфликта."
                } catch {
                    message = "Локальные записи сохранены. Не удалось проверить конфликт подходов."
                }
            } else if failure.code == "upgrade_required" {
                message = "Обнови приложение, чтобы сохранить новую структуру цикла или тренировки. Локальные записи сохранены."
            } else {
                message = "Состояние изменилось на сервере. Проверяем изменения…"
            }
        } catch {
            message = "Сохранено на iPhone · синхронизация недоступна"
        }
    }

    private func synchronizeHistory(_ api: TrainingCloudAPI) async throws {
        let remote = try await api.history()
        let localByID = Dictionary(store.archive.history.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let different = remote.first { session in
            localByID[session.id].map { !same($0, session) } ?? false
        }
        if !remote.isEmpty { try requireSaved(store.mergeHistory(remote)) }
        let remoteIDs = Set(remote.map(\.id))
        var known = Set(remote.filter { session in
            localByID[session.id].map { same($0, session) } ?? true
        }.map(\.id))
        var protectedConflict = false
        for session in store.archive.history where !remoteIDs.contains(session.id) {
            do {
                let saved = try await api.saveHistory(session, removedSetIDs: store.removedSetIDs(for: session))
                guard same(session, saved) else { throw CloudDocumentError.invalidResponse }
            } catch let failure as TrainingCloudFailure where failure.code == "set_removal_conflict" ||
                failure.code == "upgrade_required" || failure.code == "superset_conflict" {
                let active = try await api.active()
                try saveConflictBackup(remote: active)
                protectedConflict = true
                continue
            }
            known.insert(session.id)
        }
        try requireSaved(store.acknowledgeFinishedSetRemovals(sessionIDs: known))
        checkpoint.historyIDs = known.sorted { $0.uuidString < $1.uuidString }
        lastHistoryRead = Date()
        try persistCheckpoint()
        if let different, let local = localByID[different.id] {
            do {
                let record = try await api.historyRecovery(local.id)
                if same(record.session, local) {
                    lastHistoryRead = nil
                    return
                }
                try showHistoryConflict(local: local, server: record.session, version: record.version)
            } catch let failure as TrainingCloudFailure where failure.status == 404 {
                try showHistoryConflict(local: local, server: different, version: nil)
            }
        } else if protectedConflict {
            conflict = TrainingSyncConflict(resource: .history,
                message: "В активной тренировке на сервере есть защищённые подходы. Завершённая копия на iPhone и серверная версия сохранены для восстановления.",
                canChooseServer: false, canChooseLocal: false)
        }
    }

    private func showHistoryConflict(local: WorkoutSession, server: WorkoutSession, version: String?) throws {
        try saveConflictBackup(remote: server)
        message = "Есть конфликт изменений"
        conflict = TrainingSyncConflict(resource: .history,
            message: version == nil ? "Версии завершённой тренировки отличаются. Обнови сервер, чтобы выбрать версию."
                : "Версии завершённой тренировки отличаются. Открой обе записи перед выбором.",
            canChooseServer: version != nil, canChooseLocal: version != nil && (local.structureVersion ?? 0) >= (server.structureVersion ?? 0),
            history: HistoryConflict(local: local, server: server, serverVersion: version))
    }

    private func persistHistoryRecovery(_ change: HistoryRecoveryWrite?) throws {
        let previous = checkpoint.pendingHistoryRecovery
        checkpoint.pendingHistoryRecovery = change
        do { try persistCheckpoint() }
        catch {
            checkpoint.pendingHistoryRecovery = previous
            throw error
        }
    }

    private func sendHistoryRecovery(_ change: HistoryRecoveryWrite, api: TrainingCloudAPI) async throws {
        if let local = store.archive.history.first(where: { $0.id == change.session.id }), same(local, change.session) {
            do {
                let saved = try await api.recoverHistory(change)
                guard same(change.session, saved.session) else { throw CloudDocumentError.invalidResponse }
            } catch let failure as TrainingCloudFailure where failure.status == 409 {
                // The server rejected the write. A fresh read must precede any new approval.
            }
        }
        try persistHistoryRecovery(nil)
        lastHistoryRead = nil
    }

    private func synchronizeCycle(_ api: TrainingCloudAPI) async throws {
        if store.cycleState.conflict == nil, let pending = store.cycleState.pending {
            do {
                let remote = try await api.saveTrainingCycle(pending)
                var state = store.cycleState
                try state.acknowledge(requestID: pending.requestID, record: remote)
                try requireSaved(store.saveCycleState(state))
            } catch let failure as TrainingCloudFailure where failure.status == 409 && failure.code != "upgrade_required" {
                let remote = try await api.trainingCycle()
                var state = store.cycleState
                try state.reject(requestID: pending.requestID, remote: remote)
                try requireSaved(store.saveCycleState(state))
            }
        }
        if store.cycleState.conflict == nil, Date().timeIntervalSince(lastCycleRead ?? .distantPast) >= 30 {
            let remote = try await api.trainingCycle()
            var state = store.cycleState
            try state.receive(remote)
            try requireSaved(store.saveCycleState(state))
            lastCycleRead = Date()
        }
        if store.cycleState.conflict != nil {
            conflict = TrainingSyncConflict(resource: .cycle,
                message: "Цикл изменён на iPhone и сервере. Обе версии сохранены. Выбор не переписывает уже созданные недели и историю.",
                canChooseServer: true, canChooseLocal: true)
        }
    }

    private func synchronizeSavedTemplates(_ api: TrainingCloudAPI) async throws {
        if store.savedTemplatesState.conflict == nil, let pending = store.savedTemplatesState.pending {
            do {
                let remote = try await api.saveSavedTemplates(pending)
                var state = store.savedTemplatesState
                try state.acknowledge(requestID: pending.requestID, record: remote)
                try requireSaved(store.saveTemplatesState(state))
            } catch let failure as TrainingCloudFailure where failure.status == 409 && failure.code != "upgrade_required" {
                let remote = try await api.savedTemplates()
                var state = store.savedTemplatesState
                try state.reject(requestID: pending.requestID, remote: remote)
                try requireSaved(store.saveTemplatesState(state))
            }
        }
        if store.savedTemplatesState.conflict == nil, Date().timeIntervalSince(lastTemplatesRead ?? .distantPast) >= 30 {
            let remote = try await api.savedTemplates()
            var state = store.savedTemplatesState
            try state.receive(remote)
            try requireSaved(store.saveTemplatesState(state))
            lastTemplatesRead = Date()
        }
        if store.savedTemplatesState.conflict != nil {
            conflict = TrainingSyncConflict(resource: .savedTemplates,
                message: "Сохранённые шаблоны изменены на iPhone и сервере. Обе версии сохранены. Выбери, какую оставить.",
                canChooseServer: true, canChooseLocal: true)
        }
    }

    private func synchronizeCreatine(_ key: String, api: TrainingCloudAPI) async throws {
        if store.creatineState(on: key).conflict == nil, let pending = store.creatineState(on: key).pending {
            do {
                let remote = try await api.saveCreatineDay(pending, on: key)
                var state = store.creatineState(on: key)
                try state.acknowledge(requestID: pending.requestID, record: remote)
                try requireSaved(store.saveCreatineState(state, on: key))
            } catch let failure as TrainingCloudFailure where failure.status == 409 && failure.code != "upgrade_required" {
                let remote = try await api.creatineDay(key)
                var state = store.creatineState(on: key)
                try state.reject(requestID: pending.requestID, remote: remote)
                try requireSaved(store.saveCreatineState(state, on: key))
            }
        }
        if store.creatineState(on: key).conflict == nil {
            let remote = try await api.creatineDay(key)
            var state = store.creatineState(on: key)
            try state.receive(remote)
            try requireSaved(store.saveCreatineState(state, on: key))
        }
        if store.creatineState(on: key).conflict != nil {
            conflict = TrainingSyncConflict(resource: .creatine(key),
                message: "Отметка креатина за \(key) отличается на iPhone и сервере. Обе версии сохранены. Выбери, какую оставить.",
                canChooseServer: true, canChooseLocal: true)
        }
    }

    private func synchronizeTemplate(_ api: TrainingCloudAPI) async throws {
        let local = store.archive.week
        let remote = try await api.template()
        if same(local, remote.days) {
            if store.archive.templateStructureVersion == 1 && remote.structureVersion != 1 {
                checkpoint.template = try await api.saveTemplate(local, revision: remote.revision, structureVersion: 1)
            } else {
                guard same(store.archive.week, local) else { return }
                try requireSaved(store.replaceTemplate(remote.days, structureVersion: remote.structureVersion))
                checkpoint.template = remote
            }
        } else if let known = checkpoint.template {
            if same(local, known.days) && (store.archive.templateStructureVersion ?? 0) == (known.structureVersion ?? 0) {
                guard same(store.archive.week, local) else { return }
                try requireSaved(store.replaceTemplate(remote.days, structureVersion: remote.structureVersion))
                checkpoint.template = remote
            } else if remote.revision == known.revision {
                checkpoint.template = try await api.saveTemplate(local, revision: remote.revision, structureVersion: store.archive.templateStructureVersion)
            } else {
                conflict = TrainingSyncConflict(resource: .template,
                    message: "Шаблон недели изменён и на iPhone, и на сервере. Выбери, какую версию использовать.",
                    canChooseServer: true, canChooseLocal: true)
            }
        } else if remote.revision == 0 {
            checkpoint.template = try await api.saveTemplate(local, revision: 0, structureVersion: store.archive.templateStructureVersion)
        } else if local.allSatisfy({ $0.exercises.isEmpty }) {
            guard same(store.archive.week, local) else { return }
            try requireSaved(store.replaceTemplate(remote.days, structureVersion: remote.structureVersion))
            checkpoint.template = remote
        } else {
            conflict = TrainingSyncConflict(resource: .template,
                message: "В аккаунте уже есть другой шаблон. Локальная программа не заменена.",
                canChooseServer: true, canChooseLocal: true)
        }
        try persistCheckpoint()
    }

    private func synchronizeWeek(_ key: String, template: [TrainingDay], api: TrainingCloudAPI) async throws {
        guard let local = store.archive.scheduledWeeks?.first(where: { $0.weekStart == key }) else { return }
        let remote = try await api.week(key, timezone: local.timezone)
        let known = checkpoint.weeks.first { $0.weekStart == key }
        var acknowledged: TrainingWeek?
        if same(local.workouts, remote.workouts) && local.timezone == remote.timezone {
            if local.structureVersion == 1 && remote.structureVersion != 1 {
                acknowledged = try await api.saveWeek(local, revision: remote.revision)
            } else {
                guard same(store.archive.scheduledWeeks?.first(where: { $0.weekStart == key }), local) else { return }
                if local.structureVersion != remote.structureVersion { try requireSaved(store.replaceScheduledWeek(remote)) }
                acknowledged = remote
            }
        } else if let known {
            if same(local.workouts, known.workouts) && local.timezone == known.timezone &&
                (local.structureVersion ?? 0) == (known.structureVersion ?? 0) {
                guard same(store.archive.scheduledWeeks?.first(where: { $0.weekStart == key }), local) else { return }
                try requireSaved(store.replaceScheduledWeek(remote))
                acknowledged = remote
            } else if remote.revision == known.revision {
                acknowledged = try await api.saveWeek(local, revision: remote.revision)
            }
        } else if remote.revision == 0 {
            var upload = local
            if weekMatchesTemplate(local, template: template), !same(template, store.archive.week) {
                guard same(store.archive.scheduledWeeks?.first(where: { $0.weekStart == key }), local) else { return }
                upload = try local.applyingTemplate(store.archive.week)
                try requireSaved(store.replaceScheduledWeek(upload))
            }
            acknowledged = try await api.saveWeek(upload, revision: 0)
        } else if weekMatchesTemplate(local, template: template) {
            guard same(store.archive.scheduledWeeks?.first(where: { $0.weekStart == key }), local) else { return }
            try requireSaved(store.replaceScheduledWeek(remote))
            acknowledged = remote
        }
        if let acknowledged {
            checkpoint.weeks.removeAll { $0.weekStart == key }
            checkpoint.weeks.append(acknowledged)
            try persistCheckpoint()
        } else {
            conflict = TrainingSyncConflict(resource: .week(key),
                message: "Неделя с \(key) изменена на сервере и на телефоне. Переносы и упражнения не перезаписаны.",
                canChooseServer: true, canChooseLocal: true)
        }
    }

    private func synchronizeActive(_ api: TrainingCloudAPI) async throws {
        let local = store.activeWorkoutState
        let remote = try await api.active()
        guard same(store.activeWorkoutState, local) else { return }
        if same(local, remote.state) {
            checkpoint.active = remote
        } else if let remoteSession = remote.state?.session, local?.session.id != remoteSession.id,
                  let finished = store.archive.history.first(where: { $0.id == remoteSession.id }) {
            guard checkpoint.historyIDs.contains(finished.id) else { return }
            guard finished.containsCompletedSets(from: remoteSession) else {
                try saveConflictBackup(remote: remote)
                activeConflict(local: local, remote: remote.state)
                conflict?.canChooseServer = false
                conflict?.canChooseLocal = false
                return
            }
            checkpoint.active = try await api.saveActive(local, revision: remote.revision,
                removedSetIDs: local.map { store.removedSetIDs(for: $0.session) } ?? [])
        } else if let known = checkpoint.active {
            if same(local, known.state) {
                guard same(store.activeWorkoutState, local) else { return }
                try requireSaved(store.restoreActiveWorkout(remote.state))
                checkpoint.active = remote
            } else if remote.revision == known.revision {
                checkpoint.active = try await api.saveActive(local, revision: remote.revision,
                    removedSetIDs: local.map { store.removedSetIDs(for: $0.session) } ?? [])
            } else {
                activeConflict(local: local, remote: remote.state)
            }
        } else if remote.state == nil {
            checkpoint.active = try await api.saveActive(local, revision: remote.revision,
                removedSetIDs: local.map { store.removedSetIDs(for: $0.session) } ?? [])
        } else if local == nil {
            guard store.activeWorkoutState == nil else { return }
            try requireSaved(store.restoreActiveWorkout(remote.state))
            checkpoint.active = remote
        } else {
            activeConflict(local: local, remote: remote.state)
        }
        try persistCheckpoint()
    }

    private func synchronizeProteinDay(_ key: String, api: TrainingCloudAPI) async throws {
        let persisted = protein.days.first { $0.date == key }
        let local = persisted ?? ProteinDayRecord(date: key)
        let remote = try await api.proteinDay(key)
        let known = checkpoint.proteinDays?.first { $0.date == key }
        let equal = same(local.morningTakenAt, remote.morningTakenAt) && same(local.eveningTakenAt, remote.eveningTakenAt)
        let acknowledged: ProteinDayRecord
        if equal {
            acknowledged = remote
        } else if let known {
            if same(local.morningTakenAt, known.morningTakenAt) && same(local.eveningTakenAt, known.eveningTakenAt) {
                guard same(protein.days.first(where: { $0.date == key }) ?? ProteinDayRecord(date: key), local) else { return }
                try requireSaved(protein.replaceDay(remote))
                acknowledged = remote
            } else if remote.revision == known.revision {
                acknowledged = try await api.saveProteinDay(local, revision: remote.revision)
            } else {
                conflict = TrainingSyncConflict(resource: .protein(key),
                    message: "Отметки протеина за \(key) изменились на сервере и телефоне. Выбери актуальный вариант.",
                    canChooseServer: true, canChooseLocal: true)
                return
            }
        } else if remote.revision == 0 {
            acknowledged = try await api.saveProteinDay(local, revision: 0)
        } else if persisted == nil {
            guard protein.days.first(where: { $0.date == key }) == nil else { return }
            try requireSaved(protein.replaceDay(remote))
            acknowledged = remote
        } else {
            conflict = TrainingSyncConflict(resource: .protein(key),
                message: "В аккаунте уже есть другие отметки протеина за \(key). Твои отметки сохранены на телефоне.",
                canChooseServer: true, canChooseLocal: true)
            return
        }
        let current = protein.days.first { $0.date == key } ?? ProteinDayRecord(date: key)
        if acknowledged.revision > current.revision && same(current, local) &&
            same(current.morningTakenAt, acknowledged.morningTakenAt) && same(current.eveningTakenAt, acknowledged.eveningTakenAt) {
            try requireSaved(protein.replaceDay(acknowledged))
        }
        var days = checkpoint.proteinDays ?? []
        days.removeAll { $0.date == key }
        days.append(acknowledged)
        checkpoint.proteinDays = days.sorted { $0.date < $1.date }
        try persistCheckpoint()
    }

    private func activeConflict(local: ActiveWorkoutState?, remote: ActiveWorkoutState?) {
        let serverPreservesCompleted = local.map { local in
            remote?.session.containsCompletedSets(from: local.session) ?? (local.session.completedSets == 0)
        } ?? true
        let localPreservesCompleted = remote.map { remote in
            local?.session.containsCompletedSets(from: remote.session) ?? (remote.session.completedSets == 0)
        } ?? true
        conflict = TrainingSyncConflict(resource: .active,
            message: "Активная тренировка изменилась в двух местах. На iPhone выполнено \(local?.session.completedSets ?? 0) подходов, на сервере — \(remote?.session.completedSets ?? 0). Версию можно выбрать только если она сохраняет все выполненные подходы.",
            canChooseServer: serverPreservesCompleted, canChooseLocal: localPreservesCompleted)
    }

    private func weekMatchesTemplate(_ week: TrainingWeek, template: [TrainingDay]) -> Bool {
        guard store.archive.editedWeekStarts?.contains(week.weekStart) != true else { return false }
        let calendar = TrainingCalendar(timezone: week.timezone)
        guard let start = calendar.date(from: week.weekStart) else { return false }
        let expected = TrainingWeek(containing: start, template: template, calendar: calendar)
        guard expected.workouts.count == week.workouts.count else { return false }
        return week.workouts.allSatisfy { workout in
            expected.workouts.contains { $0.plannedDate == workout.plannedDate && $0.title == workout.title && $0.exercises == workout.exercises &&
                    $0.context == workout.context && $0.supersets == workout.supersets }
        }
    }

    func resolveKeepingLocal() async {
        await resolve(useServer: false)
    }

    func resolveUsingServer() async {
        await resolve(useServer: true)
    }

    private func resolve(useServer: Bool) async {
        guard let conflict, !isSyncing,
              useServer ? conflict.canChooseServer : conflict.canChooseLocal else { return }
        isSyncing = true
        let api = TrainingCloudAPI(auth: auth)
        let templateBefore = store.archive.week
        let weeksBefore = store.archive.scheduledWeeks ?? []
        let activeBefore = store.activeWorkoutState
        let proteinBefore = protein.days
        let cycleBefore = store.cycleState.document
        let templatesBefore = store.savedTemplatesState.document
        let creatineBefore = store.archive.creatineDays
        do {
            let profile = try await api.profile()
            guard checkpoint.accountID == profile.id else {
                message = "Конфликт относится к другому аккаунту. Локальные данные не отправлены."
                isSyncing = false
                return
            }
            switch conflict.resource {
            case .template:
                let remote = try await api.template()
                if useServer && !same(store.archive.week, templateBefore) {
                    message = "Шаблон изменился во время проверки. Выбери версию ещё раз."
                    isSyncing = false
                    return
                }
                try saveConflictBackup(remote: remote)
                if useServer { try requireSaved(store.replaceTemplate(remote.days, structureVersion: remote.structureVersion)) }
                checkpoint.template = remote
            case .week(let key):
                let remote = try await api.week(key, timezone: store.trainingCalendar.calendar.timeZone.identifier)
                if useServer && !same(store.archive.scheduledWeeks?.first(where: { $0.weekStart == key }), weeksBefore.first(where: { $0.weekStart == key })) {
                    message = "Неделя изменилась во время проверки. Выбери версию ещё раз."
                    isSyncing = false
                    return
                }
                try saveConflictBackup(remote: remote)
                if useServer { try requireSaved(store.replaceScheduledWeek(remote)) }
                checkpoint.weeks.removeAll { $0.weekStart == key }
                checkpoint.weeks.append(remote)
            case .active:
                let remote = try await api.active()
                if useServer && !same(store.activeWorkoutState, activeBefore) {
                    message = "Тренировка изменилась во время проверки. Выбери версию ещё раз."
                    isSyncing = false
                    return
                }
                activeConflict(local: store.activeWorkoutState, remote: remote.state)
                guard useServer ? self.conflict?.canChooseServer == true : self.conflict?.canChooseLocal == true else {
                    isSyncing = false
                    return
                }
                try saveConflictBackup(remote: remote)
                if useServer { try requireSaved(store.restoreActiveWorkout(remote.state)) }
                checkpoint.active = remote
            case .cycle:
                let remote = try await api.trainingCycle()
                if useServer && store.cycleState.document != cycleBefore {
                    message = "Цикл изменился на iPhone. Проверь версии ещё раз."
                    isSyncing = false
                    return
                }
                var state = store.cycleState
                guard state.conflict == remote else {
                    try state.receive(remote)
                    try requireSaved(store.saveCycleState(state))
                    message = "Цикл изменился на сервере. Проверь актуальные версии ещё раз."
                    isSyncing = false
                    return
                }
                try store.backupCycleConflict(remote: remote)
                try state.resolve(usingServer: useServer, expected: remote)
                try requireSaved(store.saveCycleState(state))
            case .savedTemplates:
                let remote = try await api.savedTemplates()
                if useServer && store.savedTemplatesState.document != templatesBefore {
                    message = "Список шаблонов изменился на iPhone. Проверь версии ещё раз."
                    isSyncing = false
                    return
                }
                var state = store.savedTemplatesState
                guard state.conflict == remote else {
                    try state.receive(remote)
                    try requireSaved(store.saveTemplatesState(state))
                    message = "Список шаблонов изменился на сервере. Проверь актуальные версии ещё раз."
                    isSyncing = false
                    return
                }
                try store.backupTemplatesConflict(remote: remote)
                try state.resolve(usingServer: useServer, expected: remote)
                try requireSaved(store.saveTemplatesState(state))
            case .creatine(let key):
                let remote = try await api.creatineDay(key)
                if useServer && store.creatineState(on: key).document != (creatineBefore?[key]?.document ?? CreatineDayDocument(date: key)) {
                    message = "Отметка креатина изменилась на iPhone. Проверь версии ещё раз."
                    isSyncing = false
                    return
                }
                var state = store.creatineState(on: key)
                guard state.conflict == remote else {
                    try state.receive(remote)
                    try requireSaved(store.saveCreatineState(state, on: key))
                    message = "Отметка креатина изменилась на сервере. Проверь актуальные версии ещё раз."
                    isSyncing = false
                    return
                }
                try store.backupCreatineConflict(remote: remote)
                try state.resolve(usingServer: useServer, expected: remote)
                try requireSaved(store.saveCreatineState(state, on: key))
            case .protein(let key):
                let remote = try await api.proteinDay(key)
                if useServer && !same(protein.days.first(where: { $0.date == key }), proteinBefore.first(where: { $0.date == key })) {
                    message = "Отметки изменились во время проверки. Выбери версию ещё раз."
                    isSyncing = false
                    return
                }
                try saveConflictBackup(remote: remote)
                if useServer { try requireSaved(protein.replaceDay(remote)) }
                var days = checkpoint.proteinDays ?? []
                days.removeAll { $0.date == key }
                days.append(remote)
                checkpoint.proteinDays = days.sorted { $0.date < $1.date }
            case .history:
                guard let history = conflict.history, let version = history.serverVersion else {
                    isSyncing = false
                    return
                }
                let remote = try await api.historyRecovery(history.local.id)
                guard let local = store.archive.history.first(where: { $0.id == history.local.id }),
                      same(local, history.local), remote.version == version else {
                    if let local = store.archive.history.first(where: { $0.id == history.local.id }) {
                        try showHistoryConflict(local: local, server: remote.session, version: remote.version)
                    }
                    message = "Тренировка изменилась. Проверь актуальные версии и подтверди выбор заново."
                    isSyncing = false
                    return
                }
                try saveConflictBackup(remote: remote.session)
                if useServer {
                    try requireSaved(store.acceptRecoveredHistory(remote.session, replacing: local))
                    lastHistoryRead = nil
                } else {
                    try persistHistoryRecovery(HistoryRecoveryWrite(expectedVersion: version, session: local))
                }
            }
            try persistCheckpoint()
            self.conflict = nil
            message = "Проверяем выбранную версию…"
        } catch {
            message = "Не удалось разрешить конфликт. Все локальные записи сохранены."
        }
        isSyncing = false
        if self.conflict == nil { await synchronize() }
    }

    private func saveConflictBackup<T: Encodable>(remote: T) throws {
        let directory = fileURL.deletingLastPathComponent().appendingPathComponent("Conflicts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = directory.appendingPathComponent(UUID().uuidString)
        try JSONEncoder().encode(store.archive).write(to: prefix.appendingPathExtension("local.json"), options: .atomic)
        try TrainingCloudAPI.encode(remote).write(to: prefix.appendingPathExtension("server.json"), options: .atomic)
        try JSONEncoder().encode(protein.days).write(to: prefix.appendingPathExtension("protein-local.json"), options: .atomic)
    }

    private func persistCheckpoint() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        checkpoint.weeks.sort { $0.weekStart < $1.weekStart }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(checkpoint)
        guard data != lastCheckpointData else { return }
        try data.write(to: fileURL, options: .atomic)
        lastCheckpointData = data
    }

    private func requireSaved(_ saved: Bool) throws {
        if !saved { throw TrainingError.invalidArchive }
    }

    private func same<T: Encodable>(_ lhs: T?, _ rhs: T?) -> Bool {
        guard let lhs else { return rhs == nil }
        guard let rhs else { return false }
        guard let first = try? TrainingCloudAPI.encode(lhs), let second = try? TrainingCloudAPI.encode(rhs) else { return false }
        return first == second
    }
}
