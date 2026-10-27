import SwiftUI

@main
struct PodhodApp: App {
    @State private var store: WorkoutStore
    @State private var auth: CloudAuthentication
    @State private var sync: CloudSynchronization
    @State private var protein: ProteinTracker
    @State private var reminders: ProteinReminders

    init() {
        let store = WorkoutStore()
        let auth = CloudAuthentication()
        let protein = ProteinTracker()
        _store = State(initialValue: store)
        _auth = State(initialValue: auth)
        _sync = State(initialValue: CloudSynchronization(store: store, auth: auth, protein: protein))
        _protein = State(initialValue: protein)
        _reminders = State(initialValue: ProteinReminders())
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, auth: auth, sync: sync, protein: protein, reminders: reminders)
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
}

enum AppTab: String, CaseIterable {
    case today = "Сегодня", program = "Программа", progress = "Прогресс"
    var icon: String {
        switch self { case .today: "sun.max"; case .program: "calendar"; case .progress: "chart.xyaxis.line" }
    }
}

struct RootView: View {
    @Bindable var store: WorkoutStore
    @Bindable var auth: CloudAuthentication
    @Bindable var sync: CloudSynchronization
    @Bindable var protein: ProteinTracker
    @Bindable var reminders: ProteinReminders
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
                    ProgressViewScreen(store: store)
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
        .fullScreenCover(isPresented: $showWorkout) { WorkoutView(store: store) }
        #else
        .sheet(isPresented: $showWorkout) { WorkoutView(store: store).frame(width: 430, height: 810) }
        #endif
        .sheet(isPresented: $showAccount) {
            CloudSettingsView(auth: auth, sync: sync)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                store.ensureWeek(containing: Date())
                await sync.synchronize()
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
                            Button { Task { await sync.synchronize() } } label: {
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
