import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct PodhodApp: App {
    @State private var store: WorkoutStore
    @State private var auth: CloudAuthentication
    @State private var sync: CloudSynchronization
    @State private var protein: ProteinTracker
    @State private var nutrition: NutritionPreferences
    @State private var diary: NutritionDiaryStore
    @State private var nutritionSync: NutritionSynchronization
    @State private var bodyProgress: BodyProgressStore
    @State private var reminders: AppNotifications
    @State private var restPresentation = WorkoutRestPresentation()
    @State private var workspaces: AccountWorkspaces
    @State private var workspaceRevision = UUID()
    @Environment(\.scenePhase) private var scenePhase

    private var restWorkspaceID: String? {
        guard workspaces.errorMessage == nil else { return nil }
        if auth.signedIn {
            guard let verifiedID = auth.verifiedAccountID, verifiedID == workspaces.accountID else { return nil }
        } else if workspaces.accountID != nil { return nil }
        return workspaces.storageID
    }

    private var restSnapshot: WorkoutRestPresentationState? {
        WorkoutRestPresentationState(archive: store.archive, workspaceID: restWorkspaceID)
    }

    init() {
        let workspaces = AccountWorkspaces()
        _ = workspaces.enablePrivateProgressStorage()
        let store = WorkoutStore(fileURL: workspaces.currentDirectory.appending(path: "training.json"))
        let auth = CloudAuthentication()
        let protein = ProteinTracker(fileURL: workspaces.currentDirectory.appending(path: "protein.json"))
        let diary = NutritionDiaryStore(fileURL: workspaces.currentDirectory.appending(path: "nutrition.json"), accountStorageError: workspaces.errorMessage)
        let nutrition = NutritionPreferences(diary: diary)
        let bodyProgress = BodyProgressStore(fileURL: workspaces.currentDirectory.appending(path: "body-progress.json"),
            accountID: workspaces.accountID, accountStorageError: workspaces.errorMessage)
        if (auth.signedIn && auth.verifiedAccountID != workspaces.accountID)
            || (!auth.signedIn && workspaces.accountID != nil) { bodyProgress.retire() }
        store.accountStorageError = workspaces.errorMessage
        protein.accountStorageError = workspaces.errorMessage
        nutrition.accountStorageError = workspaces.errorMessage
        if let error = workspaces.errorMessage { store.errorMessage = error }
        _store = State(initialValue: store)
        _auth = State(initialValue: auth)
        _sync = State(initialValue: CloudSynchronization(store: store, auth: auth, protein: protein))
        _protein = State(initialValue: protein)
        _nutrition = State(initialValue: nutrition)
        _diary = State(initialValue: diary)
        _nutritionSync = State(initialValue: NutritionSynchronization(store: diary, auth: auth, accountID: workspaces.accountID))
        _bodyProgress = State(initialValue: bodyProgress)
        _reminders = State(initialValue: AppNotifications())
        _workspaces = State(initialValue: workspaces)
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, auth: auth, sync: sync, protein: protein, reminders: reminders, nutrition: nutrition,
                diary: diary, nutritionSync: nutritionSync, bodyProgress: bodyProgress,
                restPresentation: restPresentation, restWorkspaceID: restWorkspaceID)
                .id(workspaceRevision)
                .onAppear {
                    sync.accountDiscovered = { switchAccount(to: $0) }
                    if !auth.signedIn && workspaces.accountID != nil { _ = switchAccount(to: nil) }
                    restPresentation.synchronize(restSnapshot, foreground: scenePhase == .active)
                }
                .onChange(of: restSnapshot) { _, state in restPresentation.synchronize(state, foreground: scenePhase == .active) }
                .onChange(of: scenePhase) { _, phase in restPresentation.synchronize(restSnapshot, foreground: phase == .active) }
                .onChange(of: auth.sessionID) { _, _ in
                    if auth.signedIn {
                        bodyProgress.retire()
                        restPresentation.synchronize(nil, foreground: scenePhase == .active)
                    }
                }
                .onChange(of: auth.signedIn) { _, signedIn in
                    if !signedIn { _ = switchAccount(to: nil) }
                }
                #if os(iOS)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                    if bodyProgress.loadFailed {
                        let wasRetired = bodyProgress.isRetired
                        let restored = BodyProgressStore(fileURL: workspaces.currentDirectory.appending(path: "body-progress.json"),
                            accountID: workspaces.accountID, accountStorageError: workspaces.errorMessage)
                        if wasRetired || (auth.signedIn && auth.verifiedAccountID != workspaces.accountID) {
                            restored.retire()
                        }
                        bodyProgress.retire()
                        bodyProgress = restored
                    }
                    if !auth.signedIn && workspaces.accountID != nil {
                        bodyProgress.retire()
                        _ = switchAccount(to: nil)
                    }
                }
                #endif
                .preferredColorScheme(.dark)
                .tint(.gymLime)
                #if os(macOS)
                .frame(minWidth: 390, idealWidth: 430, maxWidth: 700, minHeight: 700, idealHeight: 860)
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 430, height: 860)
        #endif
    }

    private func switchAccount(to accountID: String?) -> Bool {
        if !workspaces.isLegacy && workspaces.accountID == accountID && !bodyProgress.isRetired { return false }
        bodyProgress.retire()
        restPresentation.synchronize(nil, foreground: scenePhase == .active)
        do {
            guard !store.loadFailed, !protein.loadFailed, !nutrition.loadFailed, !diary.loadFailed,
                  !bodyProgress.loadFailed, sync.storageReady else { throw TrainingError.invalidArchive }
            guard store.pauseTimingForAccountSwitch() else { throw TrainingError.invalidArchive }
            let directory = try workspaces.prepare(accountID: accountID, legacyAccountID: sync.accountID)
            let nextStore = WorkoutStore(fileURL: directory.appending(path: "training.json"))
            let nextProtein = ProteinTracker(fileURL: directory.appending(path: "protein.json"))
            let nextDiary = NutritionDiaryStore(fileURL: directory.appending(path: "nutrition.json"))
            let nextNutrition = NutritionPreferences(diary: nextDiary)
            let nextBody = BodyProgressStore(fileURL: directory.appending(path: "body-progress.json"), accountID: accountID)
            let nextSync = CloudSynchronization(store: nextStore, auth: auth, protein: nextProtein)
            guard !nextStore.loadFailed, !nextProtein.loadFailed, !nextNutrition.loadFailed, !nextBody.loadFailed, nextSync.storageReady,
                  nextSync.accountID == nil || nextSync.accountID == accountID,
                  nextDiary.archive.accountID == nil || nextDiary.archive.accountID == accountID else { throw TrainingError.invalidArchive }
            try workspaces.commit(accountID: accountID)
            store = nextStore
            protein = nextProtein
            nutrition = nextNutrition
            diary = nextDiary
            bodyProgress = nextBody
            nutritionSync = NutritionSynchronization(store: nextDiary, auth: auth, accountID: accountID)
            sync = nextSync
            nextStore.resumeAccountTiming()
            workspaceRevision = UUID()
            return true
        } catch {
            store.errorMessage = "Не удалось открыть архив аккаунта. Все исходные файлы сохранены."
            return true
        }
    }
}

enum AppTab: String, CaseIterable {
    case today = "Сегодня", program = "Программа", progress = "Прогресс", nutrition = "Питание"
    var icon: String {
        switch self { case .today: "sun.max"; case .program: "calendar"; case .progress: "chart.xyaxis.line"; case .nutrition: "fork.knife" }
    }
}

struct RootView: View {
    @Bindable var store: WorkoutStore
    @Bindable var auth: CloudAuthentication
    @Bindable var sync: CloudSynchronization
    @Bindable var protein: ProteinTracker
    @Bindable var reminders: AppNotifications
    @Bindable var nutrition: NutritionPreferences
    @Bindable var diary: NutritionDiaryStore
    @Bindable var nutritionSync: NutritionSynchronization
    @Bindable var bodyProgress: BodyProgressStore
    @Bindable var restPresentation: WorkoutRestPresentation
    let restWorkspaceID: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAccount = false
    @State private var tab: AppTab = .today
    @State private var showWorkout = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch tab {
                case .today:
                    TodayView(store: store, start: { showWorkout = true }, openProgram: { tab = .program },
                              openAccount: { showAccount = true }, syncStatus: sync.status, protein: protein, reminders: reminders)
                case .program:
                    ProgramView(store: store, sync: sync, start: { showWorkout = true })
                case .progress:
                    ProgressViewScreen(store: store, bodyProgress: bodyProgress)
                case .nutrition:
                    NutritionHomeView(preferences: nutrition, diary: diary, sync: nutritionSync)
                }
            }
            .background(Color.gymBackground)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(AppTab.allCases, id: \.self) { item in
                        Button { tab = item } label: {
                            VStack(spacing: 6) {
                                Image(systemName: item.icon).font(.system(size: 20, weight: .semibold))
                                Text(item.rawValue).font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(tab == item ? Color.gymLime : .gymMuted)
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(tab == item ? .isSelected : [])
                    }
                }.background(Color.gymBackground.opacity(0.97))
                    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showWorkout) { WorkoutView(store: store, restPresentation: restPresentation) }
        #else
        .sheet(isPresented: $showWorkout) { WorkoutView(store: store, restPresentation: restPresentation).frame(width: 430, height: 810) }
        #endif
        .sheet(isPresented: $showAccount) {
            CloudSettingsView(auth: auth, sync: sync)
        }
        .onOpenURL { url in
            guard let request = WorkoutRestLink(url: url) else { return }
            guard let restWorkspaceID, request.matches(workspaceID: restWorkspaceID,
                sessionID: store.archive.active?.id, deadline: store.archive.restUntil) else {
                store.errorMessage = "Этот таймер уже изменился или относится к другому аккаунту. Открой текущую тренировку."
                return
            }
            switch request.action {
            case .open: showWorkout = true
            case .stop:
                if store.stopRest(sessionID: request.sessionID, expectedDeadline: request.expectedDeadline) { showWorkout = true }
            case .extend:
                if store.adjustRest(sessionID: request.sessionID, expectedDeadline: request.expectedDeadline, seconds: 30) { showWorkout = true }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                store.ensureWeek(containing: Date())
                await sync.synchronize()
                guard !Task.isCancelled else { return }
                await nutritionSync.synchronize()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { store.errorMessage != nil && !showWorkout }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("Понятно") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

struct CloudSettingsView: View {
    @Bindable var auth: CloudAuthentication
    @Bindable var sync: CloudSynchronization
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    CloudAccountView(auth: auth)
                    VStack(alignment: .leading, spacing: 15) {
                        Label("Синхронизация", systemImage: "icloud").font(.title3.bold())
                        Text(sync.status).font(.subheadline).foregroundStyle(Color.gymMuted)
                        if let date = sync.lastSyncedAt {
                            Text("Последняя синхронизация: \(date.formatted(.dateTime.hour().minute()))")
                                .font(.caption).foregroundStyle(Color.gymMuted)
                        }
                        if let conflict = sync.conflict {
                            Text(conflict.message).font(.subheadline).lineSpacing(3)
                            Text("Перед выбором сохраняется резервная копия обеих версий. Выполненные подходы защищены от потери.")
                                .font(.caption).foregroundStyle(Color.gymMuted)
                            if conflict.canChooseLocal {
                                Button("Сохранить мою версию на сервере") { Task { await sync.resolveKeepingLocal() } }
                                    .buttonStyle(.bordered).disabled(sync.isSyncing)
                            }
                            if conflict.canChooseServer {
                                Button("Использовать серверную версию") { Task { await sync.resolveUsingServer() } }
                                    .buttonStyle(.bordered).disabled(sync.isSyncing)
                            }
                        } else {
                            Button { Task { await sync.synchronize(); await auth.refreshProfile() } } label: {
                                Label("Синхронизировать сейчас", systemImage: "arrow.triangle.2.circlepath")
                            }.buttonStyle(PrimaryButton()).disabled(!auth.signedIn || sync.isSyncing)
                        }
                        Text("Подходы сохраняются сразу на телефоне. Пока приложение открыто и есть сеть, изменения проверяются каждые 5 секунд. ChatGPT увидит только синхронизированные данные.")
                            .font(.caption).foregroundStyle(Color.gymMuted).lineSpacing(3)
                    }.frame(maxWidth: .infinity, alignment: .leading).modifier(GymCard())
                }.padding(22)
            }.background(Color.gymBackground)
                .navigationTitle("Аккаунт и данные")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }.preferredColorScheme(.dark).tint(.gymLime)
        #if os(macOS)
        .frame(minWidth: 430, minHeight: 700)
        #endif
    }
}
