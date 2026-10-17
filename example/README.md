# open_blue_plus examples

## The example app

[`lib/main.dart`](lib/main.dart) is a complete BLE explorer:

* scanner with live RSSI and a "name contains" filter;
* device page: connect / disconnect, MTU, bond state, last disconnection
  reason, pair / unpair, read RSSI, clear GATT cache;
* service browser: read, write (hex) and notify on every characteristic,
  re-discovery when the peripheral changes its services.

Run it on a phone, a desktop or Chrome:

```bash
cd example
flutter run            # Android / iOS / macOS / Windows / Linux
flutter run -d chrome  # Web (Chrome, Edge, Opera)
```

## Recipes

Small, self-contained snippets for common jobs, in
[`lib/recipes/`](lib/recipes):

| recipe | what it shows |
|---|---|
| [`heart_rate.dart`](lib/recipes/heart_rate.dart) | scan by service, connect, notifications, decoding the standard Heart Rate Measurement |
| [`battery_level.dart`](lib/recipes/battery_level.dart) | read a characteristic and follow its changes |
| [`beacon_scanner.dart`](lib/recipes/beacon_scanner.dart) | iBeacon scanner: manufacturer data filter, live RSSI, `removeIfGone`, distance estimate |
| [`uart_terminal.dart`](lib/recipes/uart_terminal.dart) | Nordic UART Service: large MTU, sending data in MTU-sized chunks, text lines |
| [`auto_reconnect.dart`](lib/recipes/auto_reconnect.dart) | keeping a device connected: `autoConnect`, retries with back-off, re-subscribing after reconnection and services changes |
| [`pairing.dart`](lib/recipes/pairing.dart) | pairing with an optional PIN on every platform |

## In five lines

```dart
import 'package:open_blue_plus/open_blue_plus.dart';

Future<void> main() async {
  final ble = BleManager.instance;
  if (!await ble.requestPermissions()) return;
  await ble.waitUntilOn();

  ble.scanResults.listen((results) {
    for (final r in results) {
      print('${r.device.id}  ${r.advertisement.localName}  ${r.rssi} dBm');
    }
  });
  await ble.startScan(timeout: const Duration(seconds: 10));
}
```
