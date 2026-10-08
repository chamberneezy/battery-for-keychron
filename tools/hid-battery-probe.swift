import Foundation
import IOKit.hid

func hex(_ r: IOReturn) -> String { String(format: "0x%08X", UInt32(bitPattern: r)) }
print("IOHIDCheckAccess(listen):", IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue, "(0=granted,1=denied,2=unknown)")
let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatchingMultiple(m, [
    [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
    [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse]
] as CFArray)
print("manager open:", hex(IOHIDManagerOpen(m, 0)))
for d in (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> ?? []) {
    let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "?"
    let tr = IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String ?? "?"
    let vid = IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int ?? 0
    let pid = IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int ?? 0
    let els = IOHIDDeviceCopyMatchingElements(d, nil, 0) as? [IOHIDElement] ?? []
    let batt = els.filter { IOHIDElementGetUsagePage($0) == 0x06 && IOHIDElementGetUsage($0) == 0x20 }
    print("\n\(name) [\(tr)] vid=\(String(vid, radix: 16)) pid=\(String(pid, radix: 16)) elements=\(els.count) battery elements=\(batt.count)")
    guard !batt.isEmpty else { continue }
    print("  device open:", hex(IOHIDDeviceOpen(d, 0)))
    for e in batt {
        var v = Unmanaged.passUnretained(IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, e, 0, 0))
        let t = IOHIDElementGetType(e).rawValue
        let rid = IOHIDElementGetReportID(e)
        let r1 = IOHIDDeviceGetValueWithOptions(d, e, &v, 0x00020000)
        print("  type=\(t) reportID=\(rid) forced read:", hex(r1), r1 == kIOReturnSuccess ? "value=\(IOHIDValueGetIntegerValue(v.takeUnretainedValue()))" : "")
        var v2 = Unmanaged.passUnretained(IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, e, 0, 0))
        let r2 = IOHIDDeviceGetValue(d, e, &v2)
        print("  cached read:", hex(r2), r2 == kIOReturnSuccess ? "value=\(IOHIDValueGetIntegerValue(v2.takeUnretainedValue()))" : "")
    }
}
