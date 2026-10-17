# open_blue_plus

Bluetooth Low Energy (central role) for Flutter on **Android, iOS, macOS, Web, Linux and Windows**.
MIT licensed, no telemetry, no commercial restrictions.

> Independent implementation written from scratch on top of the official
> platform APIs (Android Bluetooth LE, CoreBluetooth, Web Bluetooth, BlueZ,
> Windows.Devices.Bluetooth). The name is a nod to the Flutter Bluetooth
> packages that came before it; this project is not affiliated with or
> endorsed by any of them.

## Features

| | Android | iOS | macOS | Web | Linux | Windows |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| Adapter state stream, `isSupported`, adapter name | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Turn Bluetooth on / off | ✅ / ≤12 | — | — | — | ✅ | ✅ |
| Scan: services, names, prefix, keywords, ids, manufacturer & service data | ✅ | ✅ | ✅ | chooser¹ | ✅ | ✅ |
| Scan: duplicates, divisor, remove if gone | ✅ | ✅ | ✅ | ✅² | ✅ | ✅ |
| Connect / disconnect / state stream / auto connect | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Disconnect reason | ✅ | ✅ | ✅ | — | BlueZ ≥ 5.7x | — |
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

See [PROTOCOL.md](PROTOCOL.md#platform-notes) for every platform difference.

## Setup

### Android

Minimum SDK 24. The plugin declares `BLUETOOTH`, `BLUETOOTH_ADMIN`,
`BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` **without** `maxSdkVersion` or
`usesPermissionFlags`, so it never narrows permissions your app declares.

If you support Android 11 or lower, declare location yourself (BLE scanning
needs it there):

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

Minimum iOS 13, macOS 10.15. Add to `ios/Runner/Info.plist`:

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

Add to `macos/Runner/Info.plist` the same `NSBluetoothAlwaysUsageDescription`
key, and to both `DebugProfile.entitlements` and `Release.entitlements`:

```xml
<key>com.apple.security.device.bluetooth</key>
<true/>
```

### Web

Chromium browsers (Chrome, Edge, Opera) over HTTPS or localhost. Only
services listed in `withServices` or `webOptionalServices` are accessible:

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

> The Windows implementation has not yet been compiled or tested on Windows
> hardware. Treat it as experimental until verified.

## Usage

```dart
import 'package:open_blue_plus/open_blue_plus.dart';

final ble = BleManager.instance;

// 0. optional, first thing in main(): iOS/macOS options and logs
await ble.setOptions(showPowerAlert: false);
await ble.setLogLevel(BleLogLevel.info);

// 1. permissions + adapter
if (!await ble.isSupported) return;
if (!await ble.requestPermissions()) return;
await ble.waitUntilOn();

// 2. scan
ble.scanResults.listen((results) {
  for (final r in results) print('${r.device.id} ${r.advertisement.localName} ${r.rssi}');
});
await ble.startScan(
  withServices: [BleUuid('180d')],
  timeout: const Duration(seconds: 10),
);

// 3. connect + discover
final device = BleDevice.fromId('AA:BB:CC:DD:EE:FF'); // or from a ScanResult
await device.connect(timeout: const Duration(seconds: 15)); // also asks for MTU 512
final services = await device.discoverServices();

// 4. talk to a characteristic
final hr = device.service(BleUuid('180d'))!.characteristic(BleUuid('2a37'))!;
final sub = hr.onValue.listen((bytes) => print('heart rate: $bytes'));
device.cancelWhenDisconnected(sub);
await hr.setNotify(true);

final value = await hr.read();          // if readable
await hr.write([0x01]);                 // with response
await hr.write([0x01], withoutResponse: true);

// 5. cleanup
await device.disconnect();
```

`device.connectionState` emits on every change, so you can react to
unexpected disconnections:

```dart
device.connectionState.listen((s) {
  if (s == DeviceConnectionState.disconnected) {
    print('lost: ${device.disconnectReason}');
  }
});
```

### Scan filters

All list filters are combined with **OR**; `withNamePrefix` is applied on top
(**AND**). Every platform applies them identically.

```dart
await ble.startScan(
  withKeywords: ['Thermo'],                       // name contains
  withRemoteIds: ['AA:BB:CC:DD:EE:FF'],           // known devices
  withManufacturerData: [
    // Apple iBeacon: company 0x004C, payload starting with 02 15
    const ManufacturerDataFilter(0x004C, data: [0x02, 0x15]),
  ],
  withServiceData: [ServiceDataFilter(BleUuid('feaa'))], // Eddystone
  allowDuplicates: true,                          // live RSSI
  continuousDivisor: 3,                           // keep 1 in 3 advertisements
  removeIfGone: const Duration(seconds: 5),       // drop silent devices
);
```

`ble.onScanResult` emits every advertisement one by one; `ble.scanResults`
emits the de-duplicated list sorted by RSSI.

### Pairing

```dart
await device.createBond();               // system dialog when needed
await device.createBond(pin: '123456');  // PIN / passkey supplied for you
device.onBondState.listen(print);        // none / bonding / bonded
await device.removeBond();
```

Android, Linux and Windows. iOS and macOS pair automatically when the app
accesses an encrypted characteristic, and fail with `not_supported` here.

### More

* `ble.systemDevices([BleUuid('180d')])`: devices already connected to the OS
  by any app (call `connect` to use them).
* `ble.bondedDevices()`, `device.bondState()`.
* `device.requestConnectionPriority(ConnectionPriority.high)`,
  `ble.getPhySupport()`, `device.setPreferredPhy(tx: {BlePhy.le2m}, rx: {BlePhy.le2m})`
  (Android).
* `device.clearGattCache()` after a firmware update changed the services
  (Android; Windows bypasses its cache on the next discovery).
* `device.onServicesReset`: the peripheral changed its services; call
  `discoverServices()` again.
* `device.connect(autoConnect: true)`: the OS reconnects whenever the device
  is in range, until `disconnect()` (Android, Windows).
* `ble.events`: streams of every device (connection, MTU, values, writes,
  descriptors, bond, name, PHY, services reset) in one place.
* `ble.logs` + `ble.setLogLevel(...)`: Dart and native logs.
* iOS state restoration: `ble.setOptions(restoreState: true)` first thing in
  `main`, plus the `bluetooth-central` background mode (without it the option
  is ignored and a warning is logged). Devices handed back by iOS appear in
  `ble.connectedDevices()`; call `discoverServices()` before using them.

### Errors

Every failure is a `BleException` with a `code`:

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

## Notes

* Call `discoverServices()` after connecting and before any read / write /
  notify.
* Use `setNotify()` to subscribe. Writing the CCCD (0x2902) directly is mapped
  to `setNotify` on every platform except Web, where it is not allowed.
* Use device ids exactly as reported by scans. MAC addresses and Apple
  identifiers are case-insensitive (normalised to upper-case); Web ids are opaque.
* On iOS and macOS, the first `getAdapterState()`, `adapterState` listener or
  `requestPermissions()` shows the system Bluetooth permission prompt
  (`isSupported` does not).
* Android executes GATT requests one at a time; the plugin queues them for you,
  so you can fire several reads/writes without awaiting each one.
* Values returned by `read()` are also emitted on `onValue`.
* Writes with response may be longer than the MTU (up to 512 bytes, sent as a
  long write if the peripheral supports it); writes without response must fit
  in `mtu - 3` bytes.
* When a peripheral exposes the same service or characteristic UUID more than
  once, `service()` / `characteristic()` return the first one; iterate
  `device.services` / `service.characteristics` to reach the others (each has
  its own `index`).
* After a Flutter hot restart, devices that are still connected are adopted
  (they show up as connected) and a scan left running is stopped.

## Example

See [`example/`](example/lib/main.dart): scanner with name filter, device page
with pairing, RSSI, GATT cache, service browser with read / write / notify.

## License

MIT © Ricci Mobile LTDA
