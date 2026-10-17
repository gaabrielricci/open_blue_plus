# Integrating open_blue_plus with an AI coding assistant

AI assistants (Claude Code, Cursor, GitHub Copilot, ChatGPT, Gemini...) write
Bluetooth code quickly, but most of them learned Flutter BLE from
*flutter_blue_plus*. Left alone, they will happily generate
`FlutterBluePlus.startScan(...)` and `Guid(...)` for this package. This guide
shows how to give them the right context so the code they write compiles
and follows the package's rules on the first try.

## 1. Give the assistant the API reference

The package ships an [`llms.txt`](../llms.txt): a compact, AI-oriented
reference of the whole API plus the rules that matter (call
`discoverServices` after connecting, subscribe before `setNotify`, chunk
writes to the MTU...). Pick the option that matches your tool.

**Claude Code** — add to your app's `CLAUDE.md`:

```markdown
## Bluetooth
This app uses the `open_blue_plus` package (NOT flutter_blue_plus).
Before writing Bluetooth code, read the API reference:
https://raw.githubusercontent.com/gaabrielricci/open_blue_plus/main/llms.txt
```

**Cursor** — create `.cursor/rules/bluetooth.mdc`:

```markdown
---
description: Bluetooth Low Energy code
globs: lib/**/*.dart
---
This app uses `open_blue_plus` for BLE, not flutter_blue_plus.
@https://raw.githubusercontent.com/gaabrielricci/open_blue_plus/main/llms.txt
```

**GitHub Copilot** — add to `.github/copilot-instructions.md` the same text
as the Claude Code block.

**Any other tool / offline** — the file is also inside the package once you
run `flutter pub get`, so you can point the assistant at it locally:

```bash
# prints where the package lives in your pub cache
grep -A1 '"name": "open_blue_plus"' .dart_tool/package_config.json
```

or just copy `llms.txt` into your repository (for example
`docs/open_blue_plus.md`) and mention it in your prompt.

## 2. Ready-made prompts

Copy, adjust the bracketed parts, and paste into your assistant. They work
best after step 1.

**Add Bluetooth to an existing app**

> Add Bluetooth Low Energy support to this Flutter app using the
> `open_blue_plus` package (read its llms.txt first; it is not
> flutter_blue_plus). Add the dependency, the Android permissions
> (BLUETOOTH_SCAN, BLUETOOTH_CONNECT and ACCESS_FINE_LOCATION with
> maxSdkVersion 30), the iOS `NSBluetoothAlwaysUsageDescription` and the
> macOS entitlement. Create a `BluetoothRepository` class that wraps
> `BleManager.instance` and exposes: adapter state, a scan for devices
> advertising service [UUID], connect/disconnect, and a stream of
> [what you need]. Handle `BleException` codes explicitly.

**Scanner screen**

> Create a screen that lists nearby BLE devices with `open_blue_plus`:
> request permissions, wait for the adapter, show
> `BleManager.instance.scanResults` sorted by RSSI with name, id and RSSI,
> a scan/stop button bound to `isScanning`, and a filter by
> [service UUID / name keyword]. On tap, stop the scan and open a device
> screen.

**Talk to my device**

> My peripheral exposes service [UUID] with characteristic [UUID] that
> [notifies / is written] with [describe the byte format, e.g. "little-endian
> int16 temperature in centi-degrees"]. Using `open_blue_plus`, write a class
> that connects to a device by id, discovers services, subscribes to the
> notifications before enabling them, parses the bytes into a Dart model and
> exposes a `Stream<Model>`. Reconnect automatically on unexpected
> disconnections and re-enable notifications after reconnecting.

**Send large data (OTA, files, UART)**

> Using `open_blue_plus`, send a `Uint8List` of any size to characteristic
> [UUID]. Request MTU 247 on connect, split the data into `device.mtu - 3`
> chunks, use write without response when the characteristic supports it,
> report progress as a stream, and stop with a clear error if the device
> disconnects.

**Tests**

> Write unit tests for my `BluetoothRepository` with no hardware, using a
> fake `BleBackend` installed in `BleChannel.backend` as described in
> open_blue_plus's doc/testing.md. Cover: device found, connect failure
> (`connect_failed`), notification parsing and unexpected disconnection.

**Migrate**

> Migrate this code from flutter_blue_plus to open_blue_plus following
> doc/migration_from_flutter_blue_plus.md. Keep behavior identical, convert
> timeouts to Durations, `Guid` to `BleUuid`, `setNotifyValue` to `setNotify`,
> `onValueReceived` to `onValue`, and error handling to `BleException.code`.

## 3. Review checklist for generated code

Assistants tend to make the same mistakes. Check that the code:

- [ ] imports `package:open_blue_plus/open_blue_plus.dart` and uses
      `BleManager.instance` / `BleDevice` / `BleUuid` (no `FlutterBluePlus`,
      `Guid`, `BluetoothDevice`);
- [ ] calls `requestPermissions()` and waits for `AdapterState.on` before
      scanning;
- [ ] calls `discoverServices()` after **every** connection;
- [ ] listens to `onValue` **before** `setNotify(true)`, and cancels the
      subscription (`cancelWhenDisconnected` helps);
- [ ] never writes more than `device.mtu - 3` bytes without response;
- [ ] stops scans (timeout or `stopScan()`) and disconnects when the screen
      or service is disposed;
- [ ] catches `BleException` and branches on `code`, not on the message;
- [ ] on Web, starts the scan from a button tap and lists every service in
      `withServices` / `webOptionalServices`;
- [ ] doesn't call `createBond` on iOS/macOS expecting it to work (it throws
      `not_supported` there by design).

## 4. Let the assistant debug with logs

When something fails on a device, enable logs and paste them to the
assistant together with the code:

```dart
await BleManager.instance.setLogLevel(BleLogLevel.debug);
// or collect them in-app:
BleManager.instance.logs.listen((r) => myLogBuffer.add(r.toString()));
```

The log shows every call sent to the platform, every event and every
error code, which is usually enough for the assistant to find the problem.
See also [troubleshooting.md](troubleshooting.md).
