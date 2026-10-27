import Foundation
import Observation
import UserNotifications

@MainActor @Observable
final class ProteinReminders: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let notificationIDs = ["dev.podhod.protein.morning", "dev.podhod.protein.evening"]
    private(set) var enabled = false
    private(set) var isBusy = false
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var status = "Напоминания выключены"
    var errorMessage: String?
    @ObservationIgnored private let center: UNUserNotificationCenter
    @ObservationIgnored private let preferenceKey = "podhod.protein-reminders.enabled"

    override init() {
        center = .current()
        super.init()
        enabled = UserDefaults.standard.bool(forKey: preferenceKey)
        center.delegate = self
    }

    func refreshStatus() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
        if authorizationStatus == .denied {
            status = "Уведомления запрещены в настройках устройства"
            return
        }
        if enabled && canNotify {
            do {
                try await scheduleReminders()
                errorMessage = nil
                status = notificationStatus
            } catch {
                status = "Не удалось запланировать напоминания"
                errorMessage = "Повтори включение напоминаний, когда устройство будет доступно."
            }
        } else if enabled {
            status = "Для напоминаний нужно разрешение на уведомления"
        } else {
            center.removePendingNotificationRequests(withIdentifiers: Self.notificationIDs)
            status = "Напоминания выключены"
        }
    }

    func enable() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let settings = await center.notificationSettings()
            authorizationStatus = settings.authorizationStatus
            if authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                authorizationStatus = await center.notificationSettings().authorizationStatus
            }
            guard canNotify else {
                status = "Разреши уведомления для «Подход» в настройках устройства"
                return
            }
            try await scheduleReminders()
            enabled = true
            UserDefaults.standard.set(true, forKey: preferenceKey)
            status = notificationStatus
        } catch {
            center.removePendingNotificationRequests(withIdentifiers: Self.notificationIDs)
            enabled = false
            UserDefaults.standard.set(false, forKey: preferenceKey)
            status = "Напоминания не включены"
            errorMessage = "Не удалось включить напоминания. Попробуй ещё раз."
        }
    }

    func disable() async {
        guard !isBusy else { return }
        center.removePendingNotificationRequests(withIdentifiers: Self.notificationIDs)
        center.removeDeliveredNotifications(withIdentifiers: Self.notificationIDs)
        enabled = false
        UserDefaults.standard.set(false, forKey: preferenceKey)
        errorMessage = nil
        status = "Напоминания выключены"
    }

    private var canNotify: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    private var notificationStatus: String {
        authorizationStatus == .provisional
            ? "Ежедневно в 09:30 и 21:30 · тихая доставка"
            : "Ежедневно в 09:30 и 21:30"
    }

    private func scheduleReminders() async throws {
        for request in Self.dailyNotificationRequests() { try await center.add(request) }
    }

    private static func dailyNotificationRequests() -> [UNNotificationRequest] {
        [9, 21].enumerated().map { index, hour in
            let content = UNMutableNotificationContent()
            content.title = index == 0 ? "Протеин — утро" : "Протеин — вечер"
            content.body = "Отметь приём протеина в разделе «Сегодня»."
            content.sound = .default
            var components = DateComponents()
            components.hour = hour
            components.minute = 30
            components.second = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            return UNNotificationRequest(identifier: notificationIDs[index], content: content, trigger: trigger)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.notificationIDs.contains(notification.request.identifier) ? [.banner, .list, .sound] : [])
    }
}
