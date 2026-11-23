import SwiftUI
#if os(iOS)
import UIKit
#endif

struct CreatineTodayCard: View {
    var store: WorkoutStore
    @Bindable var reminders: AppNotifications

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            VStack(alignment: .leading, spacing: 16) {
                Label("Креатин сегодня", systemImage: "checkmark.seal")
                    .font(.system(.title3, design: .rounded).bold())
                Toggle(isOn: Binding(
                    get: { store.creatineState(on: store.trainingCalendar.dayKey(for: Date())).document.takenAt != nil },
                    set: { store.setCreatineTaken(on: Date(), taken: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Принял сегодня").font(.subheadline.weight(.semibold))
                        Text("Одна отметка в день").font(.caption).foregroundStyle(Color.gymMuted)
                    }
                }.tint(.gymLime).disabled(store.loadFailed || store.accountStorageError != nil)
                    .accessibilityIdentifier("creatine.taken")
                Text(reminders.creatineEnabled ? "Каждые 2 часа с 09:30 до 23:30" : "Напоминание выключено")
                    .font(.caption).foregroundStyle(Color.gymMuted)
                if reminders.authorizationStatus == .denied {
                    #if os(iOS)
                    if let settings = URL(string: UIApplication.openNotificationSettingsURLString) {
                        Link("Открыть настройки уведомлений", destination: settings).font(.caption.weight(.semibold))
                    }
                    #endif
                } else {
                    Button(reminders.creatineEnabled ? "Выключить напоминание" : "Включить напоминание") {
                        Task { await reminders.setEnabled(!reminders.creatineEnabled, for: .creatine) }
                    }.font(.subheadline.weight(.semibold)).disabled(reminders.isBusy)
                }
                if let error = reminders.creatineErrorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }.modifier(GymCard())
        }
    }
}
