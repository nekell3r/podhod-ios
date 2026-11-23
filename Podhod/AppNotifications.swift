import Foundation
import Observation
import UserNotifications
#if os(iOS)
import UIKit
#endif

@MainActor @Observable
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let reminderHours = Array(stride(from: 9, through: 23, by: 2))
    nonisolated private static let proteinIDs = reminderHours.map { hour in
        switch hour {
        case 9: "dev.podhod.protein.morning"
        case 21: "dev.podhod.protein.evening"
        default: "dev.podhod.protein.\(hour)"
        }
    }
    nonisolated private static let creatineIDs = reminderHours.map { hour in
        hour == 9 ? "dev.podhod.creatine.daily" : "dev.podhod.creatine.\(hour)"
    }
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
            do { try await scheduleCreatineReminders(); creatineErrorMessage = nil }
            catch { creatineErrorMessage = "Не удалось запланировать напоминание креатина. Повтори включение." }
        } else if !creatineEnabled {
            center.removePendingNotificationRequests(withIdentifiers: Self.creatineIDs)
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
            center.removePendingNotificationRequests(withIdentifiers: Self.proteinIDs)
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
            center.removePendingNotificationRequests(withIdentifiers: Self.proteinIDs)
            enabled = false
            UserDefaults.standard.set(false, forKey: preferenceKey)
            status = "Напоминания не включены"
            errorMessage = "Не удалось включить напоминания. Попробуй ещё раз."
        }
    }

    func disable() async {
        guard !isBusy else { return }
        center.removePendingNotificationRequests(withIdentifiers: Self.proteinIDs)
        center.removeDeliveredNotifications(withIdentifiers: Self.proteinIDs)
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
            try await scheduleCreatineReminders()
            creatineEnabled = true
            UserDefaults.standard.set(true, forKey: creatinePreferenceKey)
        } catch {
            center.removePendingNotificationRequests(withIdentifiers: Self.creatineIDs)
            creatineEnabled = false
            UserDefaults.standard.set(false, forKey: creatinePreferenceKey)
            creatineErrorMessage = "Не удалось включить напоминание. Попробуй ещё раз."
        }
    }

    func disableCreatine() async {
        guard !isBusy else { return }
        center.removePendingNotificationRequests(withIdentifiers: Self.creatineIDs)
        center.removeDeliveredNotifications(withIdentifiers: Self.creatineIDs)
        creatineEnabled = false
        UserDefaults.standard.set(false, forKey: creatinePreferenceKey)
        creatineErrorMessage = nil
    }

    private func scheduleCreatineReminders() async throws {
        for (hour, id) in zip(Self.reminderHours, Self.creatineIDs) {
            try await center.add(Self.dailyReminder(id: id, hour: hour, title: "Креатин",
                body: "Отметь приём креатина в разделе «Сегодня»."))
        }
    }

    private var canNotify: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    private var notificationStatus: String {
        authorizationStatus == .provisional
            ? "Каждые 2 часа с 09:30 до 23:30 · тихая доставка"
            : "Каждые 2 часа с 09:30 до 23:30"
    }

    private func scheduleReminders() async throws {
        for (hour, id) in zip(Self.reminderHours, Self.proteinIDs) {
            let title = hour < 21 ? "Протеин — утренний приём" : "Протеин — вечерний приём"
            try await center.add(Self.dailyReminder(id: id, hour: hour, title: title,
                body: "Отметь приём протеина в разделе «Сегодня»."))
        }
    }

    private static func dailyReminder(id: String, hour: Int, title: String, body: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let components = DateComponents(hour: hour, minute: 30, second: 0)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = notification.request.identifier
        let shouldPresent = Self.proteinIDs.contains(id) || Self.creatineIDs.contains(id) || id == WorkoutRestPresentation.notificationID
        completionHandler(shouldPresent ? [.banner, .list, .sound] : [])
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
