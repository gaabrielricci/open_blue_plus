# Bluetooth in the background

What keeps working when the app is not in the foreground depends on the OS,
not on the plugin.

## Android

* Connections, notifications and `autoConnect` keep working while the
  process is alive. Android may kill a background process at any time, and
  scans started in the background are throttled.
* For long-running work (data loggers, wearables) run your Dart code in a
  **foreground service** (for example with `flutter_foreground_task` or
  `flutter_background_service`) and use the plugin from that isolate's
  Flutter engine. Declare `FOREGROUND_SERVICE_CONNECTED_DEVICE`
  (Android 14+) in your manifest.
* Background scans without filters return nothing on many devices with the
  screen off; scan with `withServices` / `withManufacturerData` /
  `withServiceData` / `withRemoteIds` so native filters are used.
* `connect(autoConnect: true)` lets the OS reconnect whenever the device is
  in range, at low power, until you call `disconnect()`.

## iOS

1. Add the background mode to `ios/Runner/Info.plist`:

   ```xml
   <key>UIBackgroundModes</key>
   <array>
     <string>bluetooth-central</string>
   </array>
   ```

2. Connections and notifications keep working while the app is suspended:
   iOS wakes it briefly for each event.
3. Background scans must filter by service (`withServices`); duplicates are
   coalesced and `allowDuplicates` is ignored by iOS.
4. **State restoration**: if iOS terminates the app for memory, it can
   relaunch it in the background when one of your devices connects or
   notifies. Opt in first thing in `main`:

   ```dart
   Future<void> main() async {
     WidgetsFlutterBinding.ensureInitialized();
     await BleManager.instance.setOptions(restoreState: true);
     runApp(const MyApp());
   }
   ```

   Restored connections show up in `await ble.connectedDevices()`; call
   `discoverServices()` and `setNotify(true)` again before using them.
   Without the background mode the option is ignored and a warning is
   logged.

## macOS, Windows, Linux

Desktop apps keep running in the background; nothing special is needed.

## Web

Browsers stop Bluetooth activity when the tab is closed and may throttle
hidden tabs.
