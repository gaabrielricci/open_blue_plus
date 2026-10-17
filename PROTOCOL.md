# Backend protocol

Contract between the Dart API (`lib/src/`) and every platform implementation.
Native backends (Android, iOS/macOS, Windows) implement it over
`MethodChannel('open_blue_plus/methods')` and
`EventChannel('open_blue_plus/events')`. Pure Dart backends (Web,
Linux) implement `BleBackend` from `package:open_blue_plus/platform_interface.dart`
and install themselves with `BleChannel.backend = ...` in `registerWith()`.

## Conventions

* **UUIDs** are always sent and returned as full 128-bit lowercase strings
  (`0000180d-0000-1000-8000-00805f9b34fb`). Backends must expand 16/32-bit UUIDs.
* **Device id**: a stable string. Android = MAC address, Apple = CoreBluetooth
  identifier, Linux = MAC address, Web = `BluetoothDevice.id`, Windows = MAC
  address formatted `AA:BB:CC:DD:EE:FF`.
* **Bytes**: `Uint8List` (`FlutterStandardTypedData` natively).
* **Errors**: `PlatformException`/`FlutterError`/`BleException` with one of
  these codes, `details`/`status` = platform status int when available:
  `timeout`, `permission_denied`, `adapter_off`, `unavailable`, `not_connected`,
  `connect_failed`, `not_found`, `not_supported`, `gatt_error`, `busy`,
  `invalid_argument`, `no_activity`, `bond_failed`, `location_services_off`.
* **Attribute addressing.** A characteristic is addressed by
  `(id, service, serviceIndex, characteristic, characteristicIndex)`; a
  descriptor additionally by `descriptor`. `serviceIndex` is the 0-based
  position of the service among the services **with the same UUID** in the
  list returned by the last `discoverServices`; `characteristicIndex` is the
  0-based position among the characteristics **with the same UUID** inside that
  service. Both default to `0` when absent (so a device without duplicated
  UUIDs never needs them). Backends must resolve them against the same order
  they returned from `discoverServices`. Descriptors are addressed by UUID only
  (first match).
* Operations that don't apply to a platform must be no-ops or return the
  documented fallback, never `notImplemented`.

## Normative rules

These resolve cross-platform differences found in review; every backend must follow them.

1. **Device id case.** MAC addresses and Apple identifiers are emitted upper-case.
   Backends accept any case on input. The Dart layer normalises MAC/UUID-shaped
   ids to upper-case; other ids (Web) are opaque and case-sensitive.
2. **Scan filters.** See [Scan filtering](#scan-filtering). Backends apply every
   filter in software **before** de-duplicating, so a first advertisement
   without a name (or without manufacturer data) does not hide the device for
   the rest of the scan.
3. **CCCD writes.** `writeDescriptor` on `00002902-…` behaves exactly like
   `setNotify` (any non-zero value enables; value `02 00` = indications,
   otherwise notify preferred over indicate) and must register the local
   listener so `value` events arrive. Where the platform forbids it (Web) →
   `not_supported`.
4. **`timeoutMs`.** Every GATT method called through `invokeWithTimeout`
   carries `timeoutMs: int`. A backend with a native per-operation timeout must
   use this value (or a larger one), never a shorter fixed one.
5. **`getConnectedDevices`** returns only connections made through this plugin
   (including connections restored by the OS, see `setOptions`), and the
   backend must later emit `connectionState` false for every id it returned.
6. **Unknown device.** `connect` to an id the backend cannot resolve →
   `not_found` (Android can connect to any valid MAC and does so). Ids returned
   by `getSystemDevices` and `getBondedDevices` must be resolvable.
7. **Adapter off.** `startScan` / `connect` / `createBond` with the adapter off
   → `adapter_off`. When the adapter turns off, every connected device gets
   `connectionState` false and all pending operations fail with `not_connected`.
8. **`turnOn` / `turnOff`** without an adapter return `false` (no error).
9. **`requestConnectionPriority` / `setPreferredPhy`** are no-ops returning
   `null` where unsupported; where supported (Android) they fail with
   `not_connected` when not connected.
10. **`setNotify(false)`** on a characteristic without notify/indicate succeeds (no-op).
11. **`mtu` event** is emitted whenever the backend learns a new MTU value,
    including right after connecting when the platform knows it.
12. **GATT before discovery.** Apps must call `discoverServices` first. Backends
    may resolve attributes lazily (Web, Linux) but are not required to.
13. **Concurrency.** The Dart layer shares in-flight `connect` and
    `discoverServices` calls, so backends never see them concurrently for one device.
14. **Unexpected errors** use `gatt_error`, never `unavailable` (reserved for
    "no Bluetooth hardware/API").
15. **`connectionState` false during `connecting`** may arrive for a failed
    attempt; the Dart layer ignores it and relies on the `connect` result.
16. **`status`/`details`** carry the platform's own code: Android GATT status,
    Apple `NSError.code`, Linux/Windows ATT error code, Web none. `scanFailed.code`
    is the Android `ScanCallback` error or the Windows `BluetoothError`.
17. **No side effects on attach.** `getConnectedDevices`, `stopScan` and
    `setLogLevel` must never create the platform manager or show a permission
    prompt (Apple: return `[]` / `null` while no `CBCentralManager` exists). The
    Dart layer calls them at start-up to adopt connections that survived a
    Flutter hot restart or were restored by the OS.
18. **Services changed.** When the peripheral's GATT database changes (Android
    `onServiceChanged`, Apple `didModifyServices`, Windows `GattServicesChanged`,
    BlueZ attributes removed/re-resolved, Web `servicechanged`/`serviceadded`/
    `serviceremoved`), emit `servicesReset`. Attribute handles cached by the
    backend for that device are invalid until the next `discoverServices`.
19. **Bond state** changes observed by the backend (pairing started, finished,
    removed — by this app or by the system) are emitted as `bondState`.

## Scan filtering

`startScan` arguments that filter (all optional, empty = no filter of that kind):

| arg | type | a device matches when |
|---|---|---|
| `services` | `List<String>` | it advertises any of these service UUIDs (in `serviceUuids`; use `serviceData` to match service data) |
| `names` | `List<String>` | `name ?? localName` equals one of them |
| `keywords` | `List<String>` | `name ?? localName` contains one of them (case-sensitive substring) |
| `remoteIds` | `List<String>` | its id equals one of them (case-insensitive for MAC/Apple ids) |
| `manufacturerData` | `List<Map>` `{id: int, data: Uint8List, mask: Uint8List?}` | it has manufacturer data for company `id` whose payload (without the 2 id bytes) matches `data` under `mask` |
| `serviceData` | `List<Map>` `{service: String, data: Uint8List, mask: Uint8List?}` | it has service data for `service` whose payload matches `data` under `mask` |
| `namePrefix` | `String?` | `name ?? localName` starts with it |

* The six list filters are **OR**-combined: the device must match at least one
  entry of at least one non-empty list. If all six are empty, every device
  passes. `namePrefix` is then **AND**-ed on top.
* **Masked match:** payload `p` matches `data` `d` under `mask` `m` when
  `p.length >= d.length` and for every `i < d.length`:
  `(p[i] & m[i]) == (d[i] & m[i])`. A null mask means all `0xFF`. An empty `data`
  matches any payload of that company/service. The Dart layer guarantees
  `mask.length == data.length`.
* Backends may use native scan filters as a pre-filter (saves power, required
  for Android background scans), but only when the native filter set is
  exactly equivalent or a superset; they must always re-check in software.
  Android: native filters only if `keywords` and `names` are empty
  (services, remoteIds, manufacturerData, serviceData each map to
  `ScanFilter`s); `ScanFilter.setDeviceName` only sees the advertised name,
  not the cached `name`, so it is not equivalent. Apple: native service
  filter only when `services` is the only non-empty list. Windows: no native
  filter (the watcher filters each packet separately and would drop the scan
  response carrying the name).
* Web uses the filters to build the chooser (`requestDevice`): services, names,
  namePrefix and manufacturerData map to `BluetoothLEScanFilter`s
  (namePrefix is copied into every filter object); `keywords`, `remoteIds` and
  `serviceData` (not implemented by Chromium) cannot be expressed, so when
  present the chooser accepts all devices and the chosen one is checked in
  software (no `scanResult` if it does not match). The chooser result carries
  no advertisement data, so the Dart layer does not re-check filters on Web.

Other `startScan` arguments:

| arg | type | meaning |
|---|---|---|
| `allowDuplicates` | `bool` | report every advertisement, not only the first per device |
| `continuousDivisor` | `int >= 1` | with `allowDuplicates`, report the 1st advertisement of each device and then every Nth one (per device). `1` = all. Applied after filtering. |
| `androidScanMode` | `int` | 0 lowPower, 1 balanced, 2 lowLatency (Android only) |
| `androidLegacy` | `bool` | Android 8+: `true` = legacy advertisements on 1M PHY only; `false` (default) = also extended advertising on all supported PHYs |
| `androidCheckLocationServices` | `bool` | Android ≤ 11: fail with `location_services_off` when the system location toggle is off (scans silently return nothing otherwise) |
| `webOptionalServices` | `List<String>` | Web: extra services the page may access after connecting |

## Methods

| method | args | returns |
|---|---|---|
| `isSupported` | – | `bool`: the device has a BLE adapter / API. Must not show a permission prompt (Apple: CoreBluetooth is always present → `true`, except the simulator where the first adapter state decides). |
| `setOptions` | `showPowerAlert: bool`, `restoreState: bool`, `restoreIdentifier: String` | `bool`: `true` if applied. Apple only (creates the `CBCentralManager` with `ShowPowerAlert` / `RestoreIdentifier`); must be called before anything that creates the manager, otherwise it returns `false` and changes nothing. `false` on other platforms. |
| `setLogLevel` | `level: int` (0 none, 1 error, 2 warning, 3 info, 4 debug, 5 verbose) | `null`. Backend emits `log` events up to that level. Default 0. |
| `getAdapterState` | – | `String`: `unknown` `unavailable` `unauthorized` `turningOn` `on` `turningOff` `off` |
| `getAdapterName` | – | `String` local adapter name (`""` when unknown/unavailable). Apple: the device name (iOS 16+: generic "iPhone" without the device-name entitlement). Windows: the computer name (what Windows advertises). Linux: adapter `Alias`. Web: `""`. |
| `requestPermissions` | `androidFineLocation: bool` | `bool` all granted. With `androidFineLocation`, Android 12+ also requests `ACCESS_FINE_LOCATION` (the app must declare it). |
| `turnOn` | – | `bool` adapter enabled (false where unsupported) |
| `turnOff` | – | `bool` adapter disabled (false where unsupported: Apple, Web, Android 13+) |
| `startScan` | see [Scan filtering](#scan-filtering) | `null` |
| `stopScan` | – | `null` |
| `getConnectedDevices` | – | `List<Map>` of `{id, name}` |
| `getSystemDevices` | `services: List<String>` | `List<Map>` of `{id, name}`: LE devices currently connected to the OS by **any** app. Apple requires services (`retrieveConnectedPeripherals`; empty list → `[00001800-…]`); Android ignores them (`BluetoothManager.getConnectedDevices(GATT)`); Linux: `Connected` devices, filtered by `UUIDs` when services given; Windows: connected LE devices; Web: `[]`. The app must still call `connect`. |
| `getBondedDevices` | – | `List<Map>` of `{id, name}` paired with the system (Android: LE/dual only; Linux: `Paired`; Windows: paired LE devices); `[]` where unsupported |
| `getBondState` | `id` | `String`: `none` `bonding` `bonded` `unknown` (`unknown` where unsupported) |
| `createBond` | `id`, `pin: String?`, `timeoutMs: int` | `null` once bonded (immediately if already bonded). `pin`: digits supplied automatically when the peripheral asks for a passkey/PIN. Failure/rejection → `bond_failed`; Apple/Web → `not_supported`. Works connected or not (Android/Windows). |
| `removeBond` | `id` | `null` once unpaired (succeeds if not bonded). Apple/Web → `not_supported`. Android uses the hidden `removeBond` API; if blocked → `not_supported`. |
| `connect` | `id`, `autoConnect: bool` | `null` once connected; error `connect_failed` otherwise. No timeout natively (Dart applies it and calls `disconnect`). |
| `disconnect` | `id` | `null` once disconnected. Must also cancel a pending connect. Succeeds if unknown/not connected. |
| `discoverServices` | `id` | `List<Map>` (see below) |
| `clearGattCache` | `id` | `null`. Android: `BluetoothGatt.refresh()` (hidden API; `not_connected` without a GATT, `not_supported` if blocked). Windows: next `discoverServices` uses `Uncached`. Others: no-op. Call `discoverServices` afterwards. |
| `read` | characteristic address | `Uint8List`. Must ALSO emit a `value` event. |
| `write` | characteristic address, `value: Uint8List`, `withoutResponse: bool` | `null` |
| `setNotify` | characteristic address, `enable: bool`, `forceIndications: bool` | `null`. Uses notify if supported, else indicate; with `forceIndications`, indicate (`not_supported` if the characteristic has no indicate). Apple, Linux and Web ignore `forceIndications` (the OS chooses). |
| `readDescriptor` | characteristic address, `descriptor` | `Uint8List` |
| `writeDescriptor` | characteristic address, `descriptor`, `value` | `null` |
| `requestMtu` | `id, mtu: int` | `int` resulting MTU (current MTU where not negotiable). Emit `mtu` event on change. |
| `readRssi` | `id` | `int` dBm |
| `requestConnectionPriority` | `id, priority: int` (0 balanced, 1 high, 2 lowPower) | `null` (no-op where unsupported) |
| `getPhySupport` | – | `Map` `{le2M: bool, leCoded: bool}` (Android 8+; `false`/`false` elsewhere) |
| `setPreferredPhy` | `id, txPhy: int, rxPhy: int, codedOption: int` | `null`. PHY masks: 1 = 1M, 2 = 2M, 4 = Coded. `codedOption`: 0 none, 1 S2, 2 S8. Android 8+; no-op elsewhere. The result arrives as a `phy` event. |

`discoverServices` result:

```
[{
  uuid: String, primary: bool,
  included: [int],               // positions (in this list) of included services
  characteristics: [{uuid: String, properties: int, descriptors: [String]}]
}]
```

The list contains **every** service, primary and secondary, flattened once
(an included service appears once, at its own position, and is referenced by
position from `included`). `serviceIndex`/`characteristicIndex` are derived by
the Dart layer from this order, so backends must keep it stable until the next
discovery.

`properties` bit layout: 0x01 broadcast, 0x02 read, 0x04 writeWithoutResponse,
0x08 write, 0x10 notify, 0x20 indicate, 0x40 authenticatedSignedWrites,
0x80 extendedProperties.

All GATT methods (`discoverServices` … `readRssi`, `clearGattCache`,
`setPreferredPhy`) fail with `not_connected` when the device is not connected
(except where documented as no-ops), and every pending one fails with
`not_connected` when the device disconnects.

## Events (`type` key)

| type | fields |
|---|---|
| `adapterState` | `state` (same values as `getAdapterState`) |
| `scanResult` | `id`, `name?`, `rssi: int`, `connectable: bool`, `localName?`, `txPowerLevel?: int`, `manufacturerData: Map<int, Uint8List>` (company id → payload without the 2 id bytes), `serviceData: Map<String uuid, Uint8List>`, `serviceUuids: List<String>` |
| `scanFailed` | `code: int` |
| `connectionState` | `id`, `connected: bool`, `reason?: int`, `reasonText?: String`. `reason`/`reasonText` only with `connected: false`: Android GATT status (`0x08` supervision timeout, `0x13` remote terminated, `0x16` local host, `133` error…), Apple `NSError.code` + `localizedDescription` (absent for a requested disconnect), Linux `Disconnected` signal reason mapped to HCI codes (timeout 0x08, remote 0x13, local 0x16, authentication 0x05) when BlueZ provides it; absent when unknown (Web, Windows). |
| `mtu` | `id`, `mtu: int` |
| `value` | `id`, `service`, `serviceIndex`, `characteristic`, `characteristicIndex`, `value: Uint8List` (notifications, indications and read results; indices may be omitted when 0) |
| `servicesReset` | `id` |
| `bondState` | `id`, `state` (`none` `bonding` `bonded`) |
| `name` | `id`, `name`: the peripheral's name changed (Apple `peripheralDidUpdateName`, Linux `Alias`/`Name`, Windows `NameChanged`, Android `ACTION_NAME_CHANGED`) |
| `phy` | `id`, `tx: int`, `rx: int` (1 = 1M, 2 = 2M, 3 = Coded) |
| `log` | `level: int`, `message: String` |

## Platform notes

| | Android | iOS / macOS | Web | Linux | Windows |
|---|---|---|---|---|---|
| `turnOn` | system dialog | `false` | `false` | `Powered = true` | `Radio.SetStateAsync` |
| `turnOff` | `disable()` (≤ 12), else `false` | `false` | `false` | `Powered = false` | `Radio.SetStateAsync(Off)` |
| `requestPermissions` | runtime perms | system prompt | `true` if API exists | `true` | `true` |
| `startScan` | scanner (max 5 starts / 30 s, else `busy`) | scanner | device chooser (needs user gesture), one result | discovery | advertisement watcher |
| `createBond` / `removeBond` | yes (PIN via pairing request) | `not_supported` (OS pairs on demand) | `not_supported` | `Pair()` (+ agent for PIN) / `RemoveDevice()` | `PairAsync` / `UnpairAsync` |
| `requestMtu` | negotiated | current value | `23` | current value | current value |
| `readRssi` | yes | yes | `not_supported` | last advertisement value (`not_supported` if none) | `not_supported` |
| `requestConnectionPriority`, `setPreferredPhy` | yes | no-op | no-op | no-op | no-op |
| `autoConnect` | yes | ignored | ignored | ignored | keeps trying (`MaintainConnection`) |
| CCCD `writeDescriptor` | = setNotify | = setNotify | `not_supported` | = setNotify | = setNotify |
| `setOptions` | `false` | applied before first use | `false` | `false` | `false` |

Web only exposes services listed in the scan filter, in `webOptionalServices`
or in `OpenBluePlusWeb.optionalServices`.

Apple: creating the Bluetooth manager (first `getAdapterState`, `adapterState`
listener or `requestPermissions`; never `isSupported`) shows the system
permission prompt. With `restoreState`, the OS may relaunch the app in the
background and hand back connected peripherals (`willRestoreState`); they are
reported by `getConnectedDevices` and keep emitting events. Requires the
`bluetooth-central` background mode.
