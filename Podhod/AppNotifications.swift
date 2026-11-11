import Foundation
import Observation
import UserNotifications
#if os(iOS)
import UIKit
#endif

@MainActor @Observable
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let notificationIDs = ["dev.podhod.protein.morning", "dev.podhod.protein.evening"]
    nonisolated static let creatineNotificationID = "dev.podhod.creatine.daily"
    private(set) var creatineEnabled = false
    var creatineErrorMessage: String?
    @ObservationIgnored private let creatinePreferenceKey = "podhod.creatine-reminders.enabled"
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
        creatineEnabled = UserDefaults.standard.bool(forKey: creatinePreferenceKey)
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
        if creatineEnabled && canNotify {
            do { try await scheduleCreatineReminder(); creatineErrorMessage = nil }
            catch { creatineErrorMessage = "Не удалось запланировать напоминание креатина. Повтори включение." }
        } else if !creatineEnabled {
            center.removePendingNotificationRequests(withIdentifiers: [Self.creatineNotificationID])
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

    func enableCreatine() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        creatineErrorMessage = nil
        do {
            authorizationStatus = await center.notificationSettings().authorizationStatus
            if authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                authorizationStatus = await center.notificationSettings().authorizationStatus
            }
            guard canNotify else {
                creatineErrorMessage = "Разреши уведомления в настройках устройства."
                return
            }
            try await scheduleCreatineReminder()
            creatineEnabled = true
            UserDefaults.standard.set(true, forKey: creatinePreferenceKey)
        } catch {
            center.removePendingNotificationRequests(withIdentifiers: [Self.creatineNotificationID])
            creatineEnabled = false
            UserDefaults.standard.set(false, forKey: creatinePreferenceKey)
            creatineErrorMessage = "Не удалось включить напоминание. Попробуй ещё раз."
        }
    }

    func disableCreatine() async {
        guard !isBusy else { return }
        center.removePendingNotificationRequests(withIdentifiers: [Self.creatineNotificationID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.creatineNotificationID])
        creatineEnabled = false
        UserDefaults.standard.set(false, forKey: creatinePreferenceKey)
        creatineErrorMessage = nil
    }

    private func scheduleCreatineReminder() async throws {
        let content = UNMutableNotificationContent()
        content.title = "Креатин"
        content.body = "Отметь приём креатина в разделе «Сегодня»."
        content.sound = .default
        var components = DateComponents()
        components.hour = 9
        components.minute = 30
        components.second = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        try await center.add(UNNotificationRequest(identifier: Self.creatineNotificationID, content: content, trigger: trigger))
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
        completionHandler((Self.notificationIDs.contains(notification.request.identifier) || notification.request.identifier == Self.creatineNotificationID) ? [.banner, .list, .sound] : [])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
        #if os(iOS)
        guard response.notification.request.identifier == WorkoutRestPresentation.notificationID,
              response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let address = response.notification.request.content.userInfo["restControlURL"] as? String else { return }
        Task { @MainActor in
            guard let url = URL(string: address), let request = WorkoutRestLink(url: url), request.action == .open else { return }
            await UIApplication.shared.open(url)
        }
        #endif
    }
}
