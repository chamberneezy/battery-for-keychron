# Battery for Keychron

macOS menu bar app (Swift, AppKit) showing battery levels of Keychron keyboards and other Bluetooth devices, with a 20% low battery alert. Fork of rxrdev/keychron-battery-level (remote `upstream`); published at chamberneezy/battery-for-keychron (remote `origin`).

## Build

The project has no signing team set. Build with an ad-hoc signature, universal:

```bash
xcodebuild -project KeychronBattery.xcodeproj -scheme KeychronBattery \
  -configuration Release -derivedDataPath ./build \
  -destination "generic/platform=macOS" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""
```

Output: `build/Build/Products/Release/Battery for Keychron.app`. Without the `ARCHS`/`-destination` flags the build is arm64 only.

- Target, scheme and Swift module are still named `KeychronBattery`; only `PRODUCT_NAME` is "Battery for Keychron". Bundle ID `dev.chamberneezy.BatteryForKeychron`.
- Sources live in a file-system synchronized group: new `.swift` files in `KeychronBattery/` are picked up without editing `project.pbxproj`.
- Deployment target is macOS 15.7.

## Architecture

- `BluetoothBatteryHelper.swift`: CoreBluetooth, BLE devices only (GATT Battery Service 0x180F). Cannot see Bluetooth Classic devices.
- `HIDManager.swift`: two paths.
  - Generic path (the one that works): matches keyboards/mice of any vendor that expose HID usage page 0x06 / usage 0x20 (Battery Strength), reads it with `IOHIDDeviceGetValueWithOptions` + `kIOHIDDeviceGetValueWithUpdate` (0x00020000, not bridged to Swift). The cached value is 0 until forced, so 0 readings are ignored. Skips "Bluetooth Low Energy" transport to avoid duplicating CoreBluetooth.
  - Legacy Keychron path from upstream: VID 0x3434 + Raw HID 0xFF60/0x61 with guessed commands. Untested; only relevant for cable/dongle.
- Both sources post `.didUpdateBluetoothBattery` with `uuid`, `name`, `level`, optional `icon`; `AppDelegate` forwards to `StatusMenuController` and `LowBatteryNotifier`.
- `LowBatteryNotifier.swift`: notifies once at ≤20%, re-arms at ≥25%, state persisted in UserDefaults.
- Refresh timer: 10/15/20 min (default 15) with 20% tolerance, plus refresh on wake.

## Gotchas

- The Keychron K6 on Bluetooth reports Apple's VID 0x05AC / PID 0x0250, not 0x3434.
- Reading keyboards needs Input Monitoring (TCC). The App Sandbox also blocks HID unless the entitlement `com.apple.security.temporary-exception.iokit-user-client-class` = `IOHIDLibUserClient` is present (kernel log: `deny iokit-open-user-client IOHIDLibUserClient`). This exception rules out the Mac App Store.
- Ad-hoc builds change code hash every rebuild, so Input Monitoring must be removed and re-added after each install.
- A sandboxed build with a different signature but an existing container blocks at launch on a hidden "access data from other apps" prompt.
- In zsh, `log` is a builtin; use `/usr/bin/log show --predicate 'process == "Battery for Keychron"' --info`.

## Releases

Tagging `vX.Y.Z` runs `.github/workflows/release.yml`, but GitHub Actions must first be enabled once in the fork's Actions tab. v2.0.0 was built locally and uploaded with `gh release create`. Only the K6 is confirmed; keep other models described as "likely".

## Commits

Commit `db76efc` holds the Bluetooth keyboard fix alone, intended for a possible upstream PR (the upstream maintainer rejects feature PRs).
