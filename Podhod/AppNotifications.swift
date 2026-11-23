import Foundation
import Observation
import UserNotifications
#if os(iOS)
import UIKit
#endif

@MainActor @Observable
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    enum Supplement: String, CaseIterable {
        case protein, creatine

        var preferenceKey: String { "podhod.\(rawValue)-reminders.enabled" }
        var notificationPrefix: String { "dev.podhod.\(rawValue)." }

        var series: [SupplementReminderSchedule.Series] {
            switch self {
            case .protein: [.proteinMorning, .proteinEvening]
            case .creatine: [.creatine]
            }
        }
    }

    private(set) var isBusy = false
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private var enabledSupplements: Set<Supplement> = []
    private var errors: [Supplement: String] = [:]
    @ObservationIgnored private let center: UNUserNotificationCenter
    @ObservationIgnored private var mutedUntil: [SupplementReminderSchedule.Series: Date]?
    @ObservationIgnored private var refreshPending = false

    override init() {
        center = .current()
        super.init()
        enabledSupplements = Set(Supplement.allCases.filter { UserDefaults.standard.bool(forKey: $0.preferenceKey) })
        center.delegate = self
    }

    var enabled: Bool { enabledSupplements.contains(.protein) }
    var creatineEnabled: Bool { enabledSupplements.contains(.creatine) }
    var errorMessage: String? { errors[.protein] }
    var creatineErrorMessage: String? { errors[.creatine] }

    var status: String {
        if authorizationStatus == .denied { return "Уведомления запрещены в настройках устройства" }
        if !enabled { return "Напоминания выключены" }
        if !canNotify { return "Для напоминаний нужно разрешение на уведомления" }
        if errorMessage != nil { return "Не удалось запланировать напоминания" }
        return authorizationStatus == .provisional
            ? "Каждые 2 часа с 09:30 до 23:30 · тихая доставка"
            : "Каждые 2 часа с 09:30 до 23:30"
    }

    func synchronizeSupplements(mutedUntil: [SupplementReminderSchedule.Series: Date]?) {
        self.mutedUntil = mutedUntil
        if isBusy {
            refreshPending = true
        } else {
            Task { await refreshStatus() }
        }
    }

    private func refreshStatus() async {
        guard !isBusy else { refreshPending = true; return }
        isBusy = true
        defer { finishUpdate() }
        authorizationStatus = await center.notificationSettings().authorizationStatus
        await reconcileSupplementRequests()
    }

    func setEnabled(_ enabled: Bool, for supplement: Supplement) async {
        guard !isBusy else { return }
        isBusy = true
        defer { finishUpdate() }
        errors[supplement] = nil

        if enabled {
            do {
                authorizationStatus = await center.notificationSettings().authorizationStatus
                if authorizationStatus == .notDetermined {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                    authorizationStatus = await center.notificationSettings().authorizationStatus
                }
                guard canNotify else { return }
            } catch {
                errors[supplement] = "Не удалось включить напоминания. Попробуй ещё раз."
                return
            }
            enabledSupplements.insert(supplement)
        } else {
            enabledSupplements.remove(supplement)
        }
        UserDefaults.standard.set(enabled, forKey: supplement.preferenceKey)
        await reconcileSupplementRequests()
        if !enabled {
            let delivered = await center.deliveredNotifications()
            let ids = delivered.map(\.request.identifier).filter { $0.hasPrefix(supplement.notificationPrefix) }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    private var canNotify: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    private func finishUpdate() {
        isBusy = false
        if refreshPending {
            refreshPending = false
            Task { await refreshStatus() }
        }
    }

    private func reconcileSupplementRequests() async {
        let pendingIDs = Set(await center.pendingNotificationRequests().map(\.identifier).filter(Self.isSupplementRequest))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = Date()
        let schedule = enabledSupplements.sorted { $0.rawValue < $1.rawValue }.map { supplement in
            let requests: [UNNotificationRequest]
            if let mutedUntil, canNotify {
                requests = supplement.series.flatMap { series in
                    SupplementReminderSchedule.slots(for: series, mutedUntil: mutedUntil[series], now: now, calendar: calendar)
                        .map { Self.supplementRequest(supplement, series: series, slot: $0, calendar: calendar) }
                }
            } else {
                requests = []
            }
            return (supplement, requests)
        }

        let desiredIDs = Set(schedule.flatMap { $0.1.map(\.identifier) })
        center.removePendingNotificationRequests(withIdentifiers: Array(pendingIDs.subtracting(desiredIDs)))
        for (supplement, requests) in schedule {
            errors[supplement] = nil
            for request in requests where !pendingIDs.contains(request.identifier) {
                guard !refreshPending else { return }
                do {
                    try await center.add(request)
                } catch {
                    errors[supplement] = "Не удалось запланировать напоминания. Открой приложение ещё раз."
                }
            }
        }
    }

    private static func supplementRequest(_ supplement: Supplement, series: SupplementReminderSchedule.Series,
                                          slot: SupplementReminderSchedule.Slot, calendar: Calendar) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        let suffix: String
        switch (series, slot.hour) {
        case (.creatine, 9): suffix = "daily"
        case (.proteinMorning, 9): suffix = "morning"
        case (.proteinEvening, 21): suffix = "evening"
        default: suffix = String(slot.hour)
        }
        switch series {
        case .creatine: content.title = "Креатин"
        case .proteinMorning: content.title = "Протеин — утренний приём"
        case .proteinEvening: content.title = "Протеин — вечерний приём"
        }
        content.body = supplement == .creatine
            ? "Отметь приём креатина в разделе «Сегодня»."
            : "Отметь приём протеина в разделе «Сегодня»."
        content.sound = .default
        var id = supplement.notificationPrefix + suffix
        var components = DateComponents(hour: slot.hour, minute: 30, second: 0)
        if let date = slot.date {
            id += ".deferred.\(Int(date.timeIntervalSince1970))"
            components = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: date)
        }
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: slot.date == nil)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }

    nonisolated private static func isSupplementRequest(_ id: String) -> Bool {
        Supplement.allCases.contains { id.hasPrefix($0.notificationPrefix) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = notification.request.identifier
        let shouldPresent = Self.isSupplementRequest(id) || id == WorkoutRestPresentation.notificationID
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
