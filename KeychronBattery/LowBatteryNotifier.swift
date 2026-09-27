import Foundation
import UserNotifications
import os

class LowBatteryNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.rrazvan.keychron.battery", category: "LowBatteryNotifier")

    static let threshold = 20
    // Re-arm only after the device is charged back above this, so a level hovering around 20% alerts once
    private let rearmLevel = 25
    private let notifiedKey = "lowBatteryNotified"
    private let enabledKey = "lowBatteryAlertsEnabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    // Device UUIDs already alerted during the current discharge; persisted so a relaunch doesn't repeat the alert
    private var notified: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: notifiedKey) }
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error = error {
                self?.logger.error("❌ Notification authorization failed: \(error.localizedDescription)")
            } else {
                self?.logger.info("🔔 Notifications \(granted ? "allowed" : "denied")")
            }
        }
    }

    func check(uuid: String, name: String, level: Int) {
        guard level >= 0 else { return }

        if level >= rearmLevel {
            notified.remove(uuid)
            return
        }

        guard level <= Self.threshold, isEnabled, !notified.contains(uuid) else { return }
        notified.insert(uuid)
        post(identifier: "low-battery-\(uuid)", name: name, level: level)
    }

    func sendTest() {
        post(identifier: "low-battery-test", name: "Test Device", level: Self.threshold)
    }

    private func post(identifier: String, name: String, level: Int) {
        let content = UNMutableNotificationContent()
        content.title = "\(name) battery low"
        content.body = "\(level)% remaining. Charge it soon."
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error = error {
                self?.logger.error("❌ Failed to post low battery notification: \(error.localizedDescription)")
            } else {
                self?.logger.info("🔔 Low battery notification sent for \(name) at \(level)%")
            }
        }
    }

    // Show the banner even though the menu bar app counts as active
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
