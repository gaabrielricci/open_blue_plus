## 1.1.0

* Android: Bluetooth Classic printers and other SPP devices. `connect`
  (`transport: auto`, the default) opens an RFCOMM link to Classic-only
  devices, and falls back to it from LE for paired dual-mode ones; the link is
  exposed as service/characteristic `0x1101` (`BleUuids.serialPort`), so code
  written for LE printers works unchanged. `BleDevice.transport` tells which
  one was used; `BleTransport.le` / `.classic` force it.
* Android: `bondedDevices()` now lists Classic-only devices.

## 1.0.0

* First release: central role on Android, iOS, macOS, Web, Linux and Windows.
* Adapter: state stream, `isSupported`, adapter name, runtime permissions
  (optional fine location on Android 12+), turn on / off.
* Scanning: service, name, name prefix, keyword, device id, manufacturer data
  and service data filters (with masks), identical OR/AND semantics on every
  platform; duplicates with `continuousDivisor`, `removeIfGone`, Android scan
  mode, extended advertising (`androidLegacy`) and location services check;
  advertisement parsing.
* Connections: connect / disconnect with timeouts, `autoConnect` (re-requests
  the MTU after every reconnection), connection state stream, disconnect
  reason, adoption of connections that survive a hot restart.
* GATT: service discovery including secondary and included services,
  duplicated UUIDs, characteristic read / write (long writes) / notify /
  indicate (`forceIndications`), descriptor read / write, `isNotifying`,
  last values, services changed notifications, clear GATT cache.
* Pairing: `createBond` (optional PIN / passkey), `removeBond`, bond state
  stream, bonded devices, devices connected to the system.
* MTU, RSSI, connection priority and PHY (Android).
* iOS / macOS options: power alert and state restoration.
* Global event streams (`BleManager.events`) and Dart + native logs.
* Documentation: complete README, guides (migration from flutter_blue_plus,
  testing with a fake backend, background operation, troubleshooting, AI
  assistants), `llms.txt` API reference for AI tools, and example recipes
  (heart rate, battery, iBeacon, UART, auto reconnect, pairing, thermal
  receipt printer with ESC/POS and paper cut).
