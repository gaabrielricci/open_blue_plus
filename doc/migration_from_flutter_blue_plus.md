# Migrating from flutter_blue_plus

`open_blue_plus` is an independent implementation with its own API. The
concepts are the same (manager, device, service, characteristic,
descriptor), so most code migrates by renaming. This page maps the common
calls.

```dart
// before
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
// after
import 'package:open_blue_plus/open_blue_plus.dart';

final ble = BleManager.instance; // replaces the static FlutterBluePlus class
```

## Main differences

* **Instance instead of statics:** `FlutterBluePlus.x` → `BleManager.instance.x`.
* **Timeouts are `Duration`s**, not seconds as `int`.
* **UUIDs:** `Guid('180D')` → `BleUuid('180d')` (16, 32 or 128-bit, any case).
* **Device ids are `String`s:** `DeviceIdentifier` / `remoteId` → `device.id`.
* **Errors:** one `BleException` with a string `code` (`timeout`,
  `not_connected`, `gatt_error`, ...) and the platform `status`, instead of
  numeric codes.
* **`lastValue` is nullable** (`null` until a value was read or notified).
* **Long writes need no flag:** writes with response may be up to 512 bytes.
* **Same scan filter semantics on every platform** (OR between lists,
  name prefix AND-ed).

## Adapter and scanning

| flutter_blue_plus | open_blue_plus |
|---|---|
| `FlutterBluePlus.isSupported` | `ble.isSupported` |
| `FlutterBluePlus.adapterState` / `adapterStateNow` | `ble.adapterState` / `ble.adapterStateNow` |
| `FlutterBluePlus.adapterName` | `ble.adapterName` |
| `FlutterBluePlus.turnOn()` / `turnOff()` | `ble.turnOn()` / `ble.turnOff()` (return `bool`) |
| (permissions requested implicitly) | `ble.requestPermissions()` |
| `startScan(withServices: [Guid(..)])` | `startScan(withServices: [BleUuid(..)])` |
| `withRemoteIds`, `withNames`, `withKeywords` | same names |
| `withMsd: [MsdFilter(id, data: ..)]` | `withManufacturerData: [ManufacturerDataFilter(id, data: ..)]` |
| `withServiceData: [ServiceDataFilter(Guid(..), data: ..)]` | `withServiceData: [ServiceDataFilter(BleUuid(..), data: ..)]` |
| `continuousUpdates: true` | `allowDuplicates: true` |
| `continuousDivisor`, `removeIfGone`, `timeout` | same names |
| `oneByOne: true` | listen to `ble.onScanResult` |
| `androidUsesFineLocation: true` | `ble.requestPermissions(androidFineLocation: true)` |
| `androidLegacy`, `androidScanMode`, `androidCheckLocationServices`, `webOptionalServices` | same names |
| `scanResults`, `onScanResults`, `isScanning`, `isScanningNow`, `lastScanResults` | same names |
| `stopScan()`, `cancelWhenScanComplete(sub)` | same names |
| `FlutterBluePlus.connectedDevices` | `ble.connectedDevicesNow` (or `await ble.connectedDevices()`) |
| `FlutterBluePlus.systemDevices(guids)` | `ble.systemDevices(uuids)` |
| `FlutterBluePlus.bondedDevices` | `ble.bondedDevices()` |
| `FlutterBluePlus.setOptions(showPowerAlert:, restoreState:)` | `ble.setOptions(showPowerAlert:, restoreState:)` (power alert off by default) |
| `FlutterBluePlus.getPhySupport()` | `ble.getPhySupport()` |
| `FlutterBluePlus.setLogLevel(LogLevel.x)` / `logs` | `ble.setLogLevel(BleLogLevel.x)` / `ble.logs` |
| `FlutterBluePlus.events.onX` | `ble.events.onX` (see below) |

## Devices

| flutter_blue_plus | open_blue_plus |
|---|---|
| `BluetoothDevice.fromId(id)` | `BleDevice.fromId(id)` |
| `device.remoteId` / `remoteId.str` | `device.id` |
| `device.platformName` / `advName` | `device.name` / `device.advName` |
| `connect(timeout: Duration, mtu:, autoConnect:)` | same |
| `disconnect(timeout: int)` | `disconnect(timeout: Duration)` |
| `discoverServices()` / `servicesList` | `discoverServices()` / `services` |
| `connectionState`, `isConnected`, `isDisconnected` | same |
| `disconnectReason` (`code`, `description`) | same |
| `mtu` (stream) / `mtuNow` | `onMtu` / `mtu` |
| `requestMtu(n)`, `readRssi()`, `clearGattCache()` | same |
| `requestConnectionPriority(connectionPriorityRequest: ConnectionPriority.high)` | `requestConnectionPriority(ConnectionPriority.high)` |
| `setPreferredPhy(txPhy: .., rxPhy: .., option: ..)` | `setPreferredPhy(tx: {BlePhy.le2m}, rx: {BlePhy.le2m}, codedOption: ..)` |
| `createBond(pin: ..)`, `removeBond()` | same (`pin` is a `String`) |
| `bondState` (stream) / `prevBondState` | `onBondState` / `prevBondState` (and `bondState()` to query) |
| `onServicesReset`, `isAutoConnectEnabled`, `cancelWhenDisconnected(sub, next:)` | same |

## Services, characteristics, descriptors

| flutter_blue_plus | open_blue_plus |
|---|---|
| `BluetoothService` | `BleService` (`uuid`, `isPrimary`, `isSecondary`, `includedServices`, `characteristics`) |
| `BluetoothCharacteristic` | `BleCharacteristic` |
| `read(timeout: int)` | `read(timeout: Duration)` |
| `write(v, withoutResponse:, allowLongWrite:)` | `write(v, withoutResponse:)` |
| `setNotifyValue(true, forceIndications:)` | `setNotify(true, forceIndications:)` |
| `isNotifying`, `lastValue`, `lastValueStream` | same (`lastValue` nullable) |
| `onValueReceived` | `onValue` |
| `BluetoothDescriptor.read()` / `write()` / `onValueReceived` | `BleDescriptor.read()` / `write()` / `onValue` |
| `Guid` | `BleUuid` (`value` = full 128-bit, `shortString`) |

## Global events

| flutter_blue_plus `events.` | open_blue_plus `ble.events.` |
|---|---|
| `onConnectionStateChanged` | `onConnectionStateChanged` |
| `onMtuChanged` | `onMtuChanged` |
| `onCharacteristicReceived` | `onCharacteristicValue` |
| `onCharacteristicWritten` | `onCharacteristicWritten` |
| `onDescriptorRead` / `onDescriptorWritten` | `onDescriptorValue` |
| `onBondStateChanged`, `onNameChanged`, `onServicesReset` | same |
| – | `onPhyChanged` |

## Errors

```dart
try {
  await c.write([1, 2, 3]);
} on BleException catch (e) {
  switch (e.code) {
    case 'not_connected': /* reconnect */
    case 'timeout': /* retry */
    case 'gatt_error': print('device answered ${e.status}');
  }
}
```

See the [error table in the README](../README.md#errors).
