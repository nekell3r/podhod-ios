import ActivityKit
import Foundation
import Observation
import UserNotifications

struct WorkoutRestPresentationState: Equatable {
    let attributes: WorkoutRestAttributes
    let content: WorkoutRestAttributes.ContentState

    init?(archive: TrainingArchive, workspaceID: String?) {
        guard let workspaceID, let session = archive.active, let deadline = archive.restUntil,
              WorkoutRestLink(workspaceID: workspaceID, sessionID: session.id,
                expectedDeadline: deadline, action: .open) != nil else { return nil }
        attributes = WorkoutRestAttributes(workspaceID: workspaceID, sessionID: session.id)
        content = WorkoutRestAttributes.ContentState(deadline: deadline,
            betweenExercises: archive.restKind == .betweenExercises)
    }

    var identity: String {
        "\(attributes.workspaceID):\(attributes.sessionID):\(content.deadline.timeIntervalSinceReferenceDate.bitPattern)"
    }
}

@MainActor @Observable
final class WorkoutRestPresentation {
    nonisolated static let notificationID = "dev.podhod.rest.finished"
    private(set) var liveEnabled: Bool
    private(set) var notificationsEnabled: Bool
    private(set) var isRequestingPermission = false
    private(set) var liveStatus = "Live Activity включены"
    private(set) var notificationStatus = "Уведомление выключено"
    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var latest: WorkoutRestPresentationState?
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var platformTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    private let liveKey = "podhod.rest.live-activity.enabled"
    private let notificationKey = "podhod.rest.notification.enabled"
    private let requestedKey = "podhod.rest.live-activity.requested"

    init() {
        liveEnabled = UserDefaults.standard.object(forKey: "podhod.rest.live-activity.enabled") as? Bool ?? true
        notificationsEnabled = UserDefaults.standard.bool(forKey: "podhod.rest.notification.enabled")
        if !liveEnabled { liveStatus = "Live Activity выключены" }
        if notificationsEnabled { notificationStatus = "Уведомление включено" }
    }

    func setLiveEnabled(_ enabled: Bool) {
        liveEnabled = enabled
        defaults.set(enabled, forKey: liveKey)
        if enabled { defaults.removeObject(forKey: requestedKey) }
        synchronize(latest, foreground: foreground)
    }

    func enableNotifications() async {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        do {
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                status = await center.notificationSettings().authorizationStatus
            }
            guard status == .authorized || status == .provisional else {
                notificationStatus = "Уведомления запрещены в настройках iOS"
                return
            }
            notificationsEnabled = true
            defaults.set(true, forKey: notificationKey)
            synchronize(latest, foreground: foreground)
        } catch { notificationStatus = "Не удалось включить уведомление. Повтори действие." }
    }

    func disableNotifications() {
        notificationsEnabled = false
        defaults.set(false, forKey: notificationKey)
        synchronize(latest, foreground: foreground)
    }

    func synchronize(_ snapshot: WorkoutRestPresentationState?, foreground: Bool) {
        latest = snapshot
        self.foreground = foreground
        generation = UUID()
        let operation = generation
        expiryTask?.cancel()
        expiryTask = nil
        if snapshot == nil { defaults.removeObject(forKey: requestedKey) }
        let previous = platformTask
        platformTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.generation == operation else { return }
            await self.updateLiveActivity(snapshot, foreground: foreground, operation: operation)
            guard self.generation == operation else { return }
            await self.updateNotification(snapshot, operation: operation)
            guard self.generation == operation, foreground, let deadline = snapshot?.content.deadline,
                  deadline > Date() else { return }
            self.expiryTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
                catch { return }
                guard let self, self.generation == operation else { return }
                self.synchronize(self.latest, foreground: self.foreground)
            }
        }
    }

    private func updateLiveActivity(_ snapshot: WorkoutRestPresentationState?, foreground: Bool, operation: UUID) async {
        let allowed = ActivityAuthorizationInfo().areActivitiesEnabled
        let desired = liveEnabled && allowed && (snapshot?.content.deadline ?? .distantPast) > Date() ? snapshot : nil
        var current: Activity<WorkoutRestAttributes>?
        for activity in Activity<WorkoutRestAttributes>.activities {
            if let desired, activity.attributes == desired.attributes, current == nil,
               activity.activityState == .active || activity.activityState == .stale {
                current = activity
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
                guard generation == operation else { return }
            }
        }
        guard let desired else {
            liveStatus = !liveEnabled ? "Live Activity выключены" : !allowed ? "Live Activity запрещены в настройках iOS" : "Нет текущего отдыха"
            return
        }
        let content = ActivityContent(state: desired.content, staleDate: desired.content.deadline)
        if let current {
            await current.update(content)
            guard generation == operation else { return }
            defaults.set(desired.identity, forKey: requestedKey)
            liveStatus = "Таймер показан вне приложения"
        } else if foreground, defaults.string(forKey: requestedKey) != desired.identity {
            do {
                _ = try Activity<WorkoutRestAttributes>.request(attributes: desired.attributes, content: content, pushType: nil)
                defaults.set(desired.identity, forKey: requestedKey)
                liveStatus = "Таймер показан вне приложения"
            } catch { liveStatus = "Не удалось показать Live Activity. Таймер в приложении работает." }
        } else {
            liveStatus = foreground ? "Этот таймер закрыт в системе" : "Live Activity откроется в приложении"
        }
    }

    private func updateNotification(_ snapshot: WorkoutRestPresentationState?, operation: UUID) async {
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        guard notificationsEnabled else { notificationStatus = "Уведомление выключено"; return }
        let settings = await center.notificationSettings()
        guard generation == operation else { return }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            notificationStatus = "Уведомления запрещены в настройках iOS"
            return
        }
        guard let snapshot, snapshot.content.deadline > Date(),
              let url = snapshot.attributes.link(.open, deadline: snapshot.content.deadline) else {
            notificationStatus = "Нет текущего отдыха"
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Отдых окончен"
        content.body = "Можно продолжать тренировку."
        content.sound = .default
        content.userInfo = ["restControlURL": url.absoluteString]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, snapshot.content.deadline.timeIntervalSinceNow), repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: trigger))
            guard generation == operation else {
                center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
                return
            }
            notificationStatus = "Уведомление запланировано на конец отдыха"
        } catch { if generation == operation { notificationStatus = "Не удалось запланировать уведомление. Повтори включение." } }
    }
}
