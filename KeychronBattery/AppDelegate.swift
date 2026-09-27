//
//  AppDelegate.swift
//  KeychronBattery
//
//  Created by Razvan on 19.12.2025.
//

import Cocoa
import ServiceManagement
import os

@main
class AppDelegate: NSObject, NSApplicationDelegate {
   private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.rrazvan.keychron.battery", category: "AppDelegate")

    let bluetoothMonitor = BluetoothBatteryMonitor()
    let hidManager = HIDManager()

    let lowBatteryNotifier = LowBatteryNotifier()

    var statusMenuController: StatusMenuController?

    private var startupRetryCount = 0
    private var refreshTimer: Timer?

    static let refreshIntervalOptions = [10, 15, 20] // minutes
    private let refreshIntervalKey = "refreshIntervalMinutes"

    var refreshIntervalMinutes: Int {
        get {
            let saved = UserDefaults.standard.integer(forKey: refreshIntervalKey)
            return Self.refreshIntervalOptions.contains(saved) ? saved : 15
        }
        set {
            UserDefaults.standard.set(newValue, forKey: refreshIntervalKey)
            scheduleRefreshTimer()
        }
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {

        statusMenuController = StatusMenuController(appDelegate: self)

        NotificationCenter.default.addObserver(forName: .didUpdateBluetoothBattery, object: nil, queue: .main) { [weak self] notification in
            if let userInfo = notification.userInfo,
               let uuid = userInfo["uuid"] as? String,
               let name = userInfo["name"] as? String,
               let level = userInfo["level"] as? Int {
                self?.logger.info("Received Bluetooth battery update for \(name): \(level)%")
                self?.statusMenuController?.updateBatteryDisplay(uuid: uuid, name: name, level: level, defaultIcon: userInfo["icon"] as? String)
                self?.lowBatteryNotifier.check(uuid: uuid, name: name, level: level)
            }
        }

        NotificationCenter.default.addObserver(forName: .didReceiveBatteryLevel, object: nil, queue: .main) { [weak self] notification in
            if let level = notification.object as? Int {
                self?.logger.info("Received HID battery update: \(level)%")
                // Use a fixed UUID for HID device to treat it as a distinct device
                self?.statusMenuController?.updateBatteryDisplay(uuid: "HID-DEVICE-001", name: "Wired/HID Device", level: level)
                self?.lowBatteryNotifier.check(uuid: "HID-DEVICE-001", name: "Wired/HID Device", level: level)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.bluetoothMonitor.start()
            self.scheduleStartupRetries()
        }

        lowBatteryNotifier.start()
        scheduleRefreshTimer()

        // Battery drains while asleep; refresh once on wake instead of polling more often
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self?.refresh() }
        }
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(refreshIntervalMinutes * 60)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Generous tolerance lets macOS batch this wake-up with others to save energy
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        logger.info("⏱️ Refreshing every \(self.refreshIntervalMinutes) minutes")
    }

    private func scheduleStartupRetries() {
        // Devices that connect later are picked up by the HID/Bluetooth connect callbacks,
        // so a few early retries are enough to cover a slow Bluetooth start after login
        Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            self.startupRetryCount += 1

            if self.startupRetryCount > 3 {
                timer.invalidate()
                self.logger.info("Startup retries finished.")
            } else {
                self.logger.info("Startup retry #\(self.startupRetryCount)")
                self.refresh()
            }
        }
    }

    @objc func refresh() {
        logger.info("Refreshing battery status...")
        bluetoothMonitor.requestBatteryUpdate()
        hidManager.requestBatteryUpdate()
    }

    func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }

        guard let bundleId = Bundle.main.bundleIdentifier else { return false }

        // Fallback for older macOS: Check launchctl list
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["list"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.contains(bundleId)
            }
        } catch {
            logger.error("Failed to check launchctl: \(error.localizedDescription)")
        }

        return false
    }

    func enableLaunchAtLogin() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }

        if #available(macOS 13.0, *) {
            // Use modern API for macOS 13+
            do {
                try SMAppService.mainApp.register()
                logger.info("✅ Enabled launch at login")
            } catch {
                logger.error("❌ Failed to enable launch at login: \(error.localizedDescription)")
            }
        } else {
            // Fallback for older macOS
            let success = SMLoginItemSetEnabled(bundleId as CFString, true)
            if success {
                logger.info("✅ Enabled launch at login")
            } else {
                logger.error("❌ Failed to enable launch at login")
            }
        }
    }

    func disableLaunchAtLogin() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }

        if #available(macOS 13.0, *) {
            // Use modern API for macOS 13+
            do {
                try SMAppService.mainApp.unregister()
                logger.info("✅ Disabled launch at login")
            } catch {
                logger.error("❌ Failed to disable launch at login: \(error.localizedDescription)")
            }
        } else {
            // Fallback for older macOS
            let success = SMLoginItemSetEnabled(bundleId as CFString, false)
            if success {
                logger.info("✅ Disabled launch at login")
            } else {
                logger.error("❌ Failed to disable launch at login")
            }
        }
    }
}
