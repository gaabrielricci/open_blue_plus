# open_blue_plus

[![pub package](https://img.shields.io/pub/v/open_blue_plus.svg)](https://pub.dev/packages/open_blue_plus)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Bluetooth Low Energy (central role) for Flutter on **Android, iOS, macOS,
Web, Linux and Windows**. Scan, connect, read, write, subscribe to
notifications, pair, and more, with one API that behaves the same on every
platform.

MIT licensed, no telemetry, no commercial restrictions.

> Independent implementation written from scratch on top of the official
> platform APIs (Android Bluetooth LE, CoreBluetooth, Web Bluetooth, BlueZ,
> Windows.Devices.Bluetooth). The name is a nod to the Flutter Bluetooth
> packages that came before it; this project is not affiliated with or
> endorsed by any of them.

## Contents

- [Features](#features)
- [Installation](#installation)
- [Platform setup](#platform-setup)
- [Quick start](#quick-start)
- [Guide](#guide): [adapter & permissions](#adapter-and-permissions) ·
  [scanning](#scanning) · [connecting](#connecting) ·
  [reading, writing, notifications](#reading-writing-and-notifications) ·
  [pairing](#pairing) · [events](#events-of-every-device) ·
  [logs](#logs) · [errors](#errors)
- [Recipes](#recipes)
- [Using AI assistants](#using-ai-assistants)
- [Testing your app](#testing-your-app)
- [More documentation](#more-documentation)
- [FAQ](#faq)

## Features

| | Android | iOS | macOS | Web | Linux | Windows |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| Adapter state stream, `isSupported`, adapter name | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Turn Bluetooth on / off | ✅ / ≤12 | — | — | — | ✅ | ✅ |
| Scan: services, names, prefix, keywords, ids, manufacturer & service data | ✅ | ✅ | ✅ | chooser¹ | ✅ | ✅ |
| Scan: duplicates, divisor, remove if gone | ✅ | ✅ | ✅ | ✅² | ✅ | ✅ |
| Connect / disconnect / state stream / auto connect | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Disconnect reason | ✅ | ✅ | ✅ | — | recent BlueZ | — |
| Discover services (incl. secondary / included) | ✅ | ✅ | ✅ | primary | ✅ | ✅ |
| Same UUID several times in a device | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Read / write / long write / notify / indicate | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Descriptor read / write | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Services changed notification | ✅ (12+) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Pair / unpair / bond state | ✅ | OS³ | OS³ | — | ✅ | ✅ |
| Devices connected to the system | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| MTU | request | auto | auto | 23 | auto | auto |
| Connection RSSI | ✅ | ✅ | ✅ | — | last adv. | — |
| Connection priority, PHY (2M / Coded), clear GATT cache | ✅ | — | — | — | — | cache |
| State restoration (background relaunch) | — | ✅ | — | — | — | — |
| Logs (Dart + native) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

¹ Browsers only allow picking one device through the system chooser, and
`startScan` must be called from a user gesture (button tap).
² Needs Chrome's `watchAdvertisements` (behind a flag in some versions).
³ iOS and macOS pair automatically when an encrypted characteristic is
accessed; apps cannot start or remove pairing.

> **Windows status:** the Windows implementation has not yet been compiled or
> tested on Windows hardware. Treat it as experimental until verified, and
> please [report](https://github.com/gaabrielricci/open_blue_plus/issues)
> what you find.

## Installation

```bash
flutter pub add open_blue_plus
```

```dart
import 'package:open_blue_plus/open_blue_plus.dart';
```

Requires Flutter 3.19+ / Dart 3.3+.

## Platform setup

### Android

Minimum SDK 24. Works with Android Gradle Plugin 8 and 9. The plugin
declares `BLUETOOTH`, `BLUETOOTH_ADMIN`, `BLUETOOTH_SCAN` and
`BLUETOOTH_CONNECT` **without** `maxSdkVersion` or `usesPermissionFlags`, so
it never narrows permissions your app declares.

If you support Android 11 or lower, declare location yourself (BLE scanning
needs it there) in `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"
    android:maxSdkVersion="30" />
```

If you derive the user's location from scans on Android 12+, declare
`ACCESS_FINE_LOCATION` without `maxSdkVersion` and call
`requestPermissions(androidFineLocation: true)`. Otherwise you may assert that
you don't (this also hides some beacons from scans):

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation"
    tools:targetApi="31" />
```

### iOS

Minimum iOS 13. Add to `ios/Runner/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app uses Bluetooth to talk to nearby devices.</string>
```

To keep working in the background (notifications, reconnection, state
restoration), also add:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>bluetooth-central</string>
</array>
```

### macOS

Minimum macOS 10.15. Add the same `NSBluetoothAlwaysUsageDescription` key
to `macos/Runner/Info.plist`, and to both `DebugProfile.entitlements` and
`Release.entitlements`:

```xml
<key>com.apple.security.device.bluetooth</key>
<true/>
```

### Web

Chromium browsers (Chrome, Edge, Opera) over HTTPS or localhost. Only
services listed in `withServices` or `webOptionalServices` are accessible
after connecting:

```dart
await ble.startScan(
  withNames: ['My Sensor'],
  webOptionalServices: [BleUuid('180f')], // ignored on other platforms
);
```

### Linux

Requires BlueZ 5 and access to the system D-Bus (standard on desktop
distributions). No extra setup.

### Windows

Windows 10 version 1803 or newer with a Bluetooth LE adapter. Building
requires Visual Studio 2022 and Windows SDK 10.0.19041 or newer (10.0.22000+
recommended). No extra runtime setup.

## Quick start

```dart
import 'package:open_blue_plus/open_blue_plus.dart';

final ble = BleManager.instance;

Future<void> heartRate() async {
  // 1. permissions + adapter
  if (!await ble.requestPermissions()) return;
  await ble.waitUntilOn();

  // 2. scan for a heart rate monitor
  final found = ble.onScanResult.first;
  await ble.startScan(withServices: [BleUuid('180d')]);
  final device = (await found).device;
  await ble.stopScan();

  // 3. connect + discover services
  await device.connect();
  await device.discoverServices();

  // 4. subscribe to the measurement
  final hr = device.service(BleUuid('180d'))!.characteristic(BleUuid('2a37'))!;
  final sub = hr.onValue.listen((bytes) => print('heart rate: ${bytes[1]}') /* uint8 format */);
  device.cancelWhenDisconnected(sub);
  await hr.setNotify(true);
}
```

## Guide

### Adapter and permissions

```dart
final ble = BleManager.instance;

if (!await ble.isSupported) return;            // no BLE hardware / API
if (!await ble.requestPermissions()) return;   // runtime permissions

ble.adapterState.listen((s) => print('adapter: $s')); // on, off, unauthorized...
await ble.waitUntilOn();                       // throws adapter_off after 10 s

await ble.turnOn();  // Android (system dialog), Linux, Windows; false elsewhere
```

On iOS and macOS the first `getAdapterState()`, `adapterState` listener or
`requestPermissions()` shows the system permission prompt. iOS options must
be set before that, ideally first thing in `main`:

```dart
await ble.setOptions(showPowerAlert: false, restoreState: true);
```

### Scanning

```dart
ble.scanResults.listen((results) {     // de-duplicated, sorted by RSSI
  for (final r in results) {
    print('${r.device.id} ${r.advertisement.localName} ${r.rssi} dBm');
  }
});

await ble.startScan(
  withServices: [BleUuid('180d')],
  timeout: const Duration(seconds: 10), // stops automatically
);
await ble.stopScan();                   // or stop it yourself
```

Filters: every list is combined with **OR**, and `withNamePrefix` is
applied on top (**AND**). Every platform applies them identically.

```dart
await ble.startScan(
  withKeywords: ['Thermo'],                        // name contains
  withNames: ['Thermo 3000'],                      // exact name
  withRemoteIds: ['AA:BB:CC:DD:EE:FF'],            // known devices
  withManufacturerData: [
    // Apple iBeacon: company 0x004C, payload starting with 02 15
    const ManufacturerDataFilter(0x004C, data: [0x02, 0x15]),
  ],
  withServiceData: [ServiceDataFilter(BleUuid('feaa'))], // Eddystone
  withNamePrefix: 'Th',
);
```

Live updates (RSSI, beacons):

```dart
await ble.startScan(
  allowDuplicates: true,                       // every advertisement
  continuousDivisor: 3,                        // keep 1 in 3 per device
  removeIfGone: const Duration(seconds: 5),    // drop silent devices
);
```

* `ble.onScanResult`: every advertisement, one by one.
* `ble.scanResults`: the list of devices, emitted on every change.
* `ble.onScanResults`: same, but starts empty when no scan is running.
* `ble.isScanning` / `ble.isScanningNow`.
* `ble.systemDevices([...])`: devices already connected to the OS by any
  app (they don't advertise); `ble.bondedDevices()`: paired devices.

Each `ScanResult` has the `device`, `rssi`, `timestamp` and the
`advertisement`: `localName`, `txPowerLevel`, `connectable`,
`manufacturerData` (company id → payload), `serviceData`, `serviceUuids`.

### Connecting

```dart
final device = BleDevice.fromId('AA:BB:CC:DD:EE:FF'); // or result.device
await device.connect(timeout: const Duration(seconds: 15));
await device.discoverServices();   // after EVERY connection

device.connectionState.listen((s) {
  if (s == DeviceConnectionState.disconnected) {
    print('lost: ${device.disconnectReason}'); // code + description
  }
});

await device.disconnect();
```

* `connect()` asks for MTU 512 right after connecting (`mtu: null` to skip);
  `device.mtu` / `device.onMtu` give the result.
* `connect(autoConnect: true)`: the OS reconnects whenever the device is in
  range, until `disconnect()` (Android, Windows).
* `device.onServicesReset`: the peripheral changed its services; call
  `discoverServices()` again.
* `device.readRssi()`, `device.requestConnectionPriority(...)`,
  `device.setPreferredPhy(...)`, `device.clearGattCache()`.
* After a Flutter hot restart, devices that are still connected are adopted
  and a scan left running is stopped.

### Reading, writing and notifications

```dart
final service = device.service(BleUuid('180f'))!;
final level = service.characteristic(BleUuid('2a19'))!;

if (level.properties.read) print(await level.read());

final sub = level.onValue.listen(print);  // reads + notifications
device.cancelWhenDisconnected(sub);
await level.setNotify(true);              // listen first, then enable

final cmd = service.characteristic(BleUuid('2a39'))!;
await cmd.write([0x01]);                          // with response
await cmd.write([0x01], withoutResponse: true);   // fast, unconfirmed
```

* Writes without response must fit in `device.mtu - 3` bytes; split larger
  data (see the [UART recipe](example/lib/recipes/uart_terminal.dart)).
  Writes with response may be up to 512 bytes.
* `level.lastValue`, `level.lastValueStream`, `level.isNotifying`.
* Descriptors: `level.descriptor(uuid)?.read()` / `write(...)`. Writing the CCCD
  (0x2902) is the same as `setNotify` (except on Web, where it's forbidden).
* Android runs GATT requests one at a time; the plugin queues them, so you
  can fire several without awaiting each one.
* A device exposing the same UUID twice: `service()` / `characteristic()`
  return the first; iterate `device.services` / `service.characteristics`
  for the others (each has its own `index`).

### Pairing

```dart
await device.createBond();               // system dialog when needed
await device.createBond(pin: '123456');  // PIN / passkey supplied for you
device.onBondState.listen(print);        // none / bonding / bonded
await device.removeBond();
```

Android, Linux and Windows. iOS and macOS pair automatically when the app
accesses an encrypted characteristic, and fail with `not_supported` here. See
the [pairing recipe](example/lib/recipes/pairing.dart) for a cross-platform
helper.

### Events of every device

```dart
ble.events.onConnectionStateChanged.listen((e) => print('${e.device.id} ${e.state}'));
ble.events.onCharacteristicValue.listen((e) => print('${e.characteristicUuid}: ${e.value}'));
```

Also `onMtuChanged`, `onCharacteristicWritten`, `onDescriptorValue`,
`onBondStateChanged`, `onNameChanged`, `onServicesReset`, `onPhyChanged`.

### Logs

```dart
await ble.setLogLevel(BleLogLevel.debug);   // Dart + native, printed
ble.logs.listen((r) => myLogger.add(r.toString()));
```

### Errors

Every failure is a `BleException` with a `code` (and the platform `status`
when there is one):

```dart
try {
  await device.connect();
} on BleException catch (e) {
  if (e.code == 'timeout') { /* out of range? */ }
}
```

| code | meaning |
|---|---|
| `timeout` | operation did not complete in time |
| `permission_denied` | missing runtime permission |
| `adapter_off` | Bluetooth is off |
| `location_services_off` | Android ≤ 11: location toggle is off, scans would find nothing |
| `not_connected` | device not connected (or disconnected during the operation) |
| `connect_failed` | connection could not be established |
| `not_found` | service / characteristic / descriptor / device not found |
| `not_supported` | operation not supported by the characteristic or platform |
| `gatt_error` | the peripheral answered with an error (`status` holds the code) |
| `bond_failed` | pairing was rejected or failed |
| `busy` | an equivalent request is already running |
| `unavailable` | no Bluetooth hardware / API on this device |
| `invalid_argument` | malformed id, UUID or argument |
| `no_activity` | Android: permission or turnOn requested without a foreground activity |

## Recipes

Ready-to-adapt code in [`example/lib/recipes/`](example/lib/recipes):

* [Heart rate monitor](example/lib/recipes/heart_rate.dart): scan by
  service, notifications, decoding.
* [Battery level](example/lib/recipes/battery_level.dart): read + follow changes.
* [iBeacon scanner](example/lib/recipes/beacon_scanner.dart): manufacturer
  filter, live RSSI, distance.
* [UART terminal](example/lib/recipes/uart_terminal.dart): Nordic UART,
  chunked writes, text lines.
* [Keep connected](example/lib/recipes/auto_reconnect.dart): auto connect,
  retries, re-subscribing.
* [Pairing](example/lib/recipes/pairing.dart): PIN, every platform.

The [example app](example/lib/main.dart) is a complete BLE explorer
(scanner, device page, service browser).

## Using AI assistants

The package ships [`llms.txt`](llms.txt), a compact API reference for AI
coding assistants. Point your assistant at it so it doesn't confuse this
API with other Bluetooth packages:

```markdown
<!-- CLAUDE.md, .cursor/rules, .github/copilot-instructions.md -->
This app uses `open_blue_plus` for Bluetooth (not flutter_blue_plus).
Read https://raw.githubusercontent.com/gaabrielricci/open_blue_plus/main/llms.txt
before writing Bluetooth code.
```

The [AI integration guide](doc/ai_integration.md) has ready-made prompts
(scanner screen, device protocol, large transfers, tests, migration) and a
checklist to review generated code.

## Testing your app

Install a fake backend and test your Bluetooth code without hardware:

```dart
BleChannel.backend = FakeBle(); // before the first BleManager.instance
```

See [doc/testing.md](doc/testing.md) for a complete fake you can copy.

## More documentation

* [Migrating from flutter_blue_plus](doc/migration_from_flutter_blue_plus.md)
* [Background operation](doc/background.md) (Android foreground services,
  iOS background mode and state restoration)
* [Troubleshooting](doc/troubleshooting.md)
* [Testing with a fake backend](doc/testing.md)
* [Using AI assistants](doc/ai_integration.md)
* [Platform protocol](PROTOCOL.md): every platform difference, and the
  contract to implement a new backend
* [API reference](https://pub.dev/documentation/open_blue_plus/latest/)

## FAQ

**Does it support the peripheral role (advertising, GATT server)?**
No, central role only.

**Can I connect to several devices at once?**
Yes. Phones usually allow 4 to 7 simultaneous connections.

**Classic Bluetooth (serial, audio)?**
No, Bluetooth Low Energy only.

**Why is the device id different on iPhone?**
iOS and macOS hide MAC addresses; ids are per-phone UUIDs. Save them per
platform.

**Do I need location permission?**
Only on Android 11 and lower, or if you derive location from scans on
Android 12+.

**Something doesn't work.**
See [troubleshooting](doc/troubleshooting.md), then open an
[issue](https://github.com/gaabrielricci/open_blue_plus/issues) with the
debug logs (`setLogLevel(BleLogLevel.debug)`), platform and device models.

## License

MIT © Ricci Mobile LTDA
