# Troubleshooting

Turn on logs first; most problems are explained there:

```dart
await BleManager.instance.setLogLevel(BleLogLevel.debug);
```

## Scanning finds nothing

* **Permissions:** call `await ble.requestPermissions()` and check the result.
* **Android 11 and lower:** the system location toggle must be on
  (`location_services_off` error tells you so), and
  `ACCESS_FINE_LOCATION` must be declared with `android:maxSdkVersion="30"`.
* **Android 12+ with `neverForLocation`:** some beacons are filtered out by
  the OS. Remove the flag and use `requestPermissions(androidFineLocation: true)`
  if you need them.
* **Filters:** remember they are OR-combined, and `withNamePrefix` is AND-ed
  on top. Try without filters.
* **iOS:** iBeacon advertisements are hidden from CoreBluetooth (use
  CoreLocation). Devices already connected to the phone by another app don't
  advertise: use `ble.systemDevices([...])`.
* **Android `busy` error:** Android allows 5 scan starts per 30 seconds per
  app. Don't restart the scan in a loop.
* **Web:** `startScan` must run inside a user gesture (button tap) and opens
  the browser's device chooser.

## Connection fails or drops

* `connect_failed` with status `133` (Android): generic stack error. Retry
  after a short delay; make sure you are not connecting to the same device
  from two places, and call `disconnect()` before reconnecting.
* Check `device.disconnectReason` after a drop: `0x08` supervision timeout
  (out of range / interference), `0x13` the device closed the link, `0x16`
  the phone closed it.
* Phones keep a limited number of simultaneous connections (often 4 to 7).
* Long-running connections: see [background.md](background.md).

## Reads / writes fail

* Call `discoverServices()` after every connection; services are cleared on
  disconnection and when `onServicesReset` fires.
* `invalid_argument` on `write(withoutResponse: true)`: the value is longer
  than `device.mtu - 3`. Request a larger MTU (`connect(mtu: 247)` or
  `requestMtu`) or split the data (see the UART recipe in `example/`).
* `gatt_error` with status 5 / 15 (insufficient authentication / encryption):
  the characteristic needs pairing. See `createBond` and the pairing recipe.
* A device that changed its firmware may be served from a stale cache:
  `device.clearGattCache()` (Android) and discover again.

## Notifications don't arrive

* Subscribe to `onValue` **before** calling `setNotify(true)`.
* Re-enable them after every reconnection (they are lost with the link).
* Some devices only support indications: `setNotify` chooses automatically;
  `forceIndications: true` forces them on Android and Windows.

## iOS / macOS specifics

* The permission prompt appears on the first `getAdapterState()`,
  `adapterState` listener or `requestPermissions()`. Call `setOptions(...)`
  before any of those if you use it.
* macOS apps need the `com.apple.security.device.bluetooth` entitlement.
* Device ids are per-phone UUIDs, not MAC addresses, and they change if the
  user resets network settings.

## Linux

* Requires BlueZ 5 and access to the system D-Bus. Flatpak/Snap apps need
  the Bluetooth permission/plug.
* Pairing with a PIN registers a temporary BlueZ agent; without a PIN the
  desktop's own agent (GNOME, KDE) shows the dialog.

## Still stuck?

Open an issue with the debug logs, platform/OS version, phone model and the
peripheral model: https://github.com/gaabrielricci/open_blue_plus/issues
