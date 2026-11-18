import Foundation
import Observation
import UserNotifications

/// One local notification a day at a chosen time. Tapping it opens straight
/// into a voice entry. The notification text is fixed and never contains
/// anything from the journal; nothing is sent to a server.
@MainActor
@Observable
final class Reminder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Reminder()

    static let identifier = "daily-reminder"
    static let defaultMinutes = 21 * 60
    private static let onKey = "reminderOn"
    private static let minutesKey = "reminderMinutes"

    private(set) var isOn = false
    /// Minutes after midnight, local time.
    private(set) var minutes = Reminder.defaultMinutes
    var message: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        isOn = defaults.bool(forKey: Self.onKey)
        minutes = Self.clamp(defaults.object(forKey: Self.minutesKey) as? Int ?? Self.defaultMinutes)
    }

    var time: Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    func turnOn() async {
        await update(on: true, minutes: minutes)
    }

    func setTime(_ date: Date) async {
        await update(on: isOn, minutes: Self.minutes(of: date))
    }

    func turnOff() {
        isOn = false
        message = nil
        defaults.set(false, forKey: Self.onKey)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }

    private func update(on: Bool, minutes newMinutes: Int) async {
        minutes = Self.clamp(newMinutes)
        defaults.set(minutes, forKey: Self.minutesKey)
        guard on else { return turnOff() }

        let center = UNUserNotificationCenter.current()
        let allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard allowed else {
            turnOff()
            message = "Notifications are off for Private Notes. Turn them on in Settings to get a reminder."
            return
        }

        let content = UNMutableNotificationContent()
        content.body = "Anything on your mind today?"
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: Self.components(minutes: minutes), repeats: true)
        do {
            // Adding a request with the same identifier replaces the old one.
            try await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger))
            isOn = true
            message = nil
            defaults.set(true, forKey: Self.onKey)
        } catch {
            turnOff()
            message = "Couldn't set the reminder: \(error.localizedDescription)"
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == Self.identifier,
              response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { CaptureRequest.shared.request(.voice) }
    }

    nonisolated static func clamp(_ minutes: Int) -> Int {
        min(max(minutes, 0), 24 * 60 - 1)
    }

    nonisolated static func components(minutes: Int) -> DateComponents {
        let m = clamp(minutes)
        return DateComponents(hour: m / 60, minute: m % 60)
    }

    nonisolated static func minutes(of date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return clamp((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }
}
