import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ProteinTodayCard: View {
    @Bindable var tracker: ProteinTracker
    @Bindable var reminders: ProteinReminders
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            VStack(alignment: .leading, spacing: 18) {
                Label("Протеин сегодня", systemImage: "mug.fill")
                    .font(.system(.title3, design: .rounded).bold())
                VStack(spacing: 15) {
                    Toggle(isOn: Binding(
                        get: { tracker.day(on: Date()).isTaken(.morning) },
                        set: { tracker.setTaken(period: .morning, on: Date(), taken: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Утро").font(.subheadline.weight(.semibold))
                            Text("09:30").font(.caption).foregroundStyle(Color.gymMuted)
                        }
                    }
                    Divider()
                    Toggle(isOn: Binding(
                        get: { tracker.day(on: Date()).isTaken(.evening) },
                        set: { tracker.setTaken(period: .evening, on: Date(), taken: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Вечер").font(.subheadline.weight(.semibold))
                            Text("21:30").font(.caption).foregroundStyle(Color.gymMuted)
                        }
                    }
                }.tint(.gymLime).disabled(tracker.loadFailed)
                if let error = tracker.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(reminders.status).font(.caption).foregroundStyle(Color.gymMuted)
                    if reminders.authorizationStatus == .denied {
                        #if os(iOS)
                        if let settings = URL(string: UIApplication.openNotificationSettingsURLString) {
                            Link("Открыть настройки уведомлений", destination: settings).font(.caption.weight(.semibold))
                        }
                        #endif
                    } else if !reminders.enabled || reminders.authorizationStatus == .notDetermined {
                        Button {
                            Task { await reminders.enable() }
                        } label: { Label("Включить напоминания", systemImage: "bell.badge") }
                            .font(.subheadline.weight(.semibold)).disabled(reminders.isBusy)
                    }
                    if reminders.enabled {
                        Button("Выключить напоминания") { Task { await reminders.disable() } }
                            .font(.caption).foregroundStyle(Color.gymMuted).disabled(reminders.isBusy)
                    }
                    if reminders.isBusy { SwiftUI.ProgressView().controlSize(.small) }
                    if let error = reminders.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }.modifier(GymCard())
        }
        .task { await reminders.refreshStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reminders.refreshStatus() } }
        }
    }
}
