import Foundation
import IOKit.hid
import os

extension Notification.Name {
    static let didReceiveBatteryLevel = Notification.Name("didReceiveBatteryLevel")
}

// MARK: - Battery Command Model
private struct BatteryCommand {
    let reportId: UInt8
    let data: [UInt8]
    let description: String
}

class HIDManager {
    // MARK: - Properties

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.chamberneezy.BatteryForKeychron", category: "HIDManager")
    private var manager: IOHIDManager?
    private let reportSize = 64 // K2 HE uses 64-byte reports
    private var deviceBuffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:] // Keep buffers alive
    private var rawHIDDevice: IOHIDDevice?
    private var isSearchingForBattery = false

    // Devices that expose a standard HID battery element (Generic Device Controls 0x06 / Battery Strength 0x20).
    // Keychron keyboards on Bluetooth Classic report this, but with Apple's vendor ID (0x05AC) instead of 0x3434.
    private struct BatteryDevice {
        let uuid: String
        let name: String
        let icon: String
        let element: IOHIDElement
    }
    private var batteryDevices: [IOHIDDevice: BatteryDevice] = [:]
    private var genericManager: IOHIDManager?
    private let batteryStrengthUsage = 0x20 // HID Usage Tables: Generic Device Controls / Battery Strength
    private let getValueWithUpdate: IOOptionBits = 0x00020000 // kIOHIDDeviceGetValueWithUpdate (not bridged to Swift)

    private let commandSequence: [BatteryCommand] = [
            // 1. VIA/QMK Standard
            BatteryCommand(reportId: 0,
                           data: [0x04, 0xB0] + [UInt8](repeating: 0x00, count: 62),
                           description: "VIA Get Value (0x04)"),

            // 2. Apple Standard Battery Request
            BatteryCommand(reportId: 0,
                           data: [0x02] + [UInt8](repeating: 0x00, count: 63),
                           description: "Standard Battery (0x02)"),

            // 3. Keychron Specific Variations
            BatteryCommand(reportId: 0,
                           data: [0x08, 0x01] + [UInt8](repeating: 0x00, count: 62),
                           description: "Keychron (0x08, 0x01)"),
            BatteryCommand(reportId: 0,
                           data: [0x08, 0x02] + [UInt8](repeating: 0x00, count: 62),
                           description: "Keychron (0x08, 0x02)"),
            BatteryCommand(reportId: 0,
                           data: [0x08, 0x0F] + [UInt8](repeating: 0x00, count: 62),
                           description: "Keychron (0x08, 0x0F)"),

            // 4. Legacy 32-byte report
            BatteryCommand(reportId: 0,
                           data: [0x02] + [UInt8](repeating: 0x00, count: 31),
                           description: "Legacy 32-byte (0x02)")
        ]

    // MARK: - Initialization

    init() {
        logger.info("🚀 HIDManager: Starting search for Keychron devices...")
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // BROAD MATCH: Match ANY device from Keychron (0x3434)
        let matchingDict: [String: Any] = [
            kIOHIDVendorIDKey: 0x3434
        ]

        guard let manager = manager else {
            logger.error("❌ HIDManager: Failed to create manager.")
            return
        }

        IOHIDManagerSetDeviceMatching(manager, matchingDict as CFDictionary)

        // Callback for when a device is matched
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            let this = Unmanaged<HIDManager>.fromOpaque(context!).takeUnretainedValue()
            this.inspectDevice(device)
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            let this = Unmanaged<HIDManager>.fromOpaque(context!).takeUnretainedValue()
            this.deviceRemoved(device)
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        let resultString = openResult == kIOReturnSuccess ? "Success" : "Error \(openResult)"
        logger.info("📡 HIDManager: Open Result = \(resultString)")

        // NEW: Enumerate already-connected devices at startup
        if let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            logger.info("🔎 Enumerating \(deviceSet.count) already-connected HID devices at startup...")
            for device in deviceSet {
                self.inspectDevice(device)
            }
        } else {
            logger.info("🔎 No already-connected HID devices found at startup.")
        }

        startGenericBatteryMonitor()
    }

    // MARK: - Standard HID Battery (any vendor)

    private func startGenericBatteryMonitor() {
        // Reading keyboards requires the Input Monitoring permission; this prompts on first launch.
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            logger.info("🔐 Requesting Input Monitoring access...")
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        genericManager = manager

        // Keyboards and mice; the battery element itself is checked per device
        let matching: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            let this = Unmanaged<HIDManager>.fromOpaque(context!).takeUnretainedValue()
            this.registerBatteryDevice(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            let this = Unmanaged<HIDManager>.fromOpaque(context!).takeUnretainedValue()
            this.unregisterBatteryDevice(device)
        }, context)

        // Pushed battery reports (some devices send them when the level changes)
        IOHIDManagerSetInputValueMatching(manager, [
            kIOHIDElementUsagePageKey: kHIDPage_GenericDeviceControls,
            kIOHIDElementUsageKey: batteryStrengthUsage
        ] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            let this = Unmanaged<HIDManager>.fromOpaque(context!).takeUnretainedValue()
            let device = IOHIDElementGetDevice(IOHIDValueGetElement(value))
            this.reportBattery(device: device, level: IOHIDValueGetIntegerValue(value))
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            logger.error("❌ Battery monitor open failed (\(String(format: "0x%08X", openResult))). Grant Input Monitoring in System Settings → Privacy & Security.")
        }
    }

    private func registerBatteryDevice(_ device: IOHIDDevice) {
        guard batteryDevices[device] == nil else { return }

        // BLE devices are already handled by BluetoothBatteryMonitor via the GATT Battery Service
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        if transport == "Bluetooth Low Energy" { return }

        let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
        guard let element = elements.first(where: {
            IOHIDElementGetUsagePage($0) == kHIDPage_GenericDeviceControls &&
            IOHIDElementGetUsage($0) == batteryStrengthUsage &&
            IOHIDElementGetType($0) == kIOHIDElementTypeInput_Misc
        }) else { return }

        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "HID Device"
        let vid = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0

        let info = BatteryDevice(
            uuid: "HID-\(serial ?? String(format: "%04X-%04X", vid, pid))",
            name: name,
            icon: usage == kHIDUsage_GD_Mouse ? "mouse" : "keyboard",
            element: element
        )
        batteryDevices[device] = info
        logger.info("🔋 Battery-capable HID device: \(name) [\(transport)]")
        readBattery(device: device, info: info)
    }

    private func unregisterBatteryDevice(_ device: IOHIDDevice) {
        guard let info = batteryDevices.removeValue(forKey: device) else { return }
        logger.info("🔌 \(info.name) disconnected")
        postBattery(info: info, level: -1)
    }

    private func readBattery(device: IOHIDDevice, info: BatteryDevice) {
        // The cached value is 0 until the device sends a report, so force a GET_REPORT
        var value = Unmanaged.passUnretained(IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, info.element, 0, 0))
        let result = IOHIDDeviceGetValueWithOptions(device, info.element, &value, getValueWithUpdate)
        guard result == kIOReturnSuccess else {
            logger.error("⚠️ Battery read failed for \(info.name): \(String(format: "0x%08X", result))")
            return
        }
        reportBattery(device: device, level: IOHIDValueGetIntegerValue(value.takeUnretainedValue()))
    }

    private func reportBattery(device: IOHIDDevice, level: Int) {
        // 0 is what an un-refreshed element reports, so treat it as "no reading" rather than an empty battery
        guard let info = batteryDevices[device], (1...100).contains(level) else { return }
        postBattery(info: info, level: level)
    }

    private func postBattery(info: BatteryDevice, level: Int) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .didUpdateBluetoothBattery, object: nil, userInfo: [
                "uuid": info.uuid,
                "name": info.name,
                "level": level,
                "icon": info.icon
            ])
        }
    }

    // MARK: - Device Discovery

    private func inspectDevice(_ device: IOHIDDevice) {
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
        let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "Unknown"

        logger.info("""
        -----------------------------------------
        🔍 Found Device: \(name)
           PID: \(String(format: "0x%04X", pid))
           Transport: \(transport)
           Usage Page: \(String(format: "0x%04X", usagePage))
           Usage ID: \(String(format: "0x%04X", usage))
        -----------------------------------------
        """)

        // Check ALL devices for battery elements
        if let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
            for element in elements {
                let ePage = IOHIDElementGetUsagePage(element)
                let eUsage = IOHIDElementGetUsage(element)
                // Battery System (0x85) or Power Device (0x84)
                if ePage == 0x85 || ePage == 0x84 {
                    logger.info("  🔋 BATTERY ELEMENT: Page=0x\(String(format: "%04X", ePage)), Usage=0x\(String(format: "%04X", eUsage))")
                }
            }
        }

        // Keychron Raw HID is almost always Page: 0xFF60, Usage: 0x61
        if usagePage == 0xFF60 && usage == 0x61 {
            logger.info("✅ MATCH! This is the Raw HID interface. Registering receiver...")
            setupReceiver(device: device)
        }
    }

    private func setupReceiver(device: IOHIDDevice) {
        rawHIDDevice = device

        // Open the device directly
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        let resultString = openResult == kIOReturnSuccess ? "Success" : "Failed (\(openResult))"
        logger.info("🔓 Opened HID device directly: \(resultString)")

        // Enumerate all HID elements to find battery-related ones
        if let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
            logger.info("📋 Found \(elements.count) HID elements:")
            for element in elements.prefix(20) {
                let usagePage = IOHIDElementGetUsagePage(element)
                let usage = IOHIDElementGetUsage(element)
                let type = IOHIDElementGetType(element)
                logger.debug("  • Page: 0x\(String(format: "%04X", usagePage)), Usage: 0x\(String(format: "%04X", usage)), Type: \(type.rawValue)")
            }
        }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)
        deviceBuffers[device] = buffer // Keep buffer alive

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        // Register input report callback
        IOHIDDeviceRegisterInputReportCallback(device, buffer, reportSize, { context, _, _, _, _, report, reportLength in
            let this = Unmanaged<HIDManager>.fromOpaque(context!).takeUnretainedValue()
            this.handleInputReport(report: report, reportLength: reportLength)
        }, context)

        // Also register input value callback (catches different types of reports)
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            let this = Unmanaged<HIDManager>.fromOpaque(context!).takeUnretainedValue()
            this.handleInputValue(value: value)
        }, context)

        // Schedule with run loop
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        logger.info("✅ Input callbacks registered with \(self.reportSize)-byte buffer")
    }

    private func handleInputReport(report: UnsafeMutablePointer<UInt8>, reportLength: CFIndex) {
        let data = UnsafeBufferPointer(start: report, count: reportLength)
        let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        logger.debug("📥 HID Data Received (\(reportLength) bytes): \(hexString)")

        // Keychron can send battery info with different formats, check for common patterns
        if reportLength >= 3 {
            if data[0] == 0x02 && data[2] > 0 && data[2] <= 100 {
                let battery = Int(data[2])

                // ✅ SUCCESS!
                // Stop the retry loop immediately so we don't spam more commands
                if isSearchingForBattery {
                    logger.info("✅ Battery found (\(battery)%). Stopping scan sequence.")
                    isSearchingForBattery = false
                }

                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .didReceiveBatteryLevel, object: battery)
                }
            }
        }
    }

    private func handleInputValue(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)
        logger.debug("📊 Input Value - Page: 0x\(String(format: "%04X", usagePage)), Usage: 0x\(String(format: "%04X", usage)), Value: \(intValue)")
    }

    // MARK: - Memory Management
    private func deviceRemoved(_ device: IOHIDDevice) {
        logger.info("🔌 Device disconnected. Cleaning up resources.")

        // 1. Deallocate the C-pointer buffer
        if let buffer = deviceBuffers[device] {
            buffer.deallocate()
            deviceBuffers.removeValue(forKey: device)
        }

        // 2. If this was our active device, clear it
        if rawHIDDevice == device {
            rawHIDDevice = nil
        }
    }

    private func executeCommandStep(device: IOHIDDevice, index: Int) {
        let totalCommands = commandSequence.count

        guard index < totalCommands, isSearchingForBattery else {
            if index >= totalCommands {
                logger.info("🛑 HID: Finished command sequence. No response from device.")
            }
            isSearchingForBattery = false
            return
        }

        let command = commandSequence[index]
        var report = command.data

        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(command.reportId), &report, report.count)

        let success = (result == kIOReturnSuccess)
        let icon = success ? "📤" : "⚠️"
        logger.debug("\(icon) Trying [\(index + 1)/\(totalCommands)]: \(command.description)")

        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            self.executeCommandStep(device: device, index: index + 1)
        }
    }

    deinit {
        if let manager = manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        if let genericManager = genericManager {
            IOHIDManagerUnscheduleFromRunLoop(genericManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        deviceBuffers.values.forEach { $0.deallocate() }
    }

    // MARK: - Battery Communication Logic

    func requestBatteryUpdate() {
            for (device, info) in batteryDevices {
                readBattery(device: device, info: info)
            }

            guard let device = rawHIDDevice else { return }

            // If we are already running a sequence, don't restart it
            if isSearchingForBattery { return }

            logger.info("🔄 Starting robust battery scan sequence...")
            isSearchingForBattery = true

            // Start the chain with the first command
            executeCommandStep(device: device, index: 0)
        }
}
