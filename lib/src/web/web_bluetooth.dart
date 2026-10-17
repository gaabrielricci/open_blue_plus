// Minimal Web Bluetooth bindings (package:web only ships BluetoothUUID).
// https://webbluetoothcg.github.io/web-bluetooth/
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// `navigator.bluetooth`, or null when the browser (or an insecure context)
/// does not expose Web Bluetooth.
Bluetooth? get navigatorBluetooth {
  final nav = web.window.navigator as JSObject;
  if (!nav.has('bluetooth')) return null;
  return nav['bluetooth'] as Bluetooth?;
}

extension type Bluetooth._(JSObject _) implements web.EventTarget {
  external JSPromise<JSBoolean> getAvailability();
  external JSPromise<BluetoothDevice> requestDevice(JSObject options);

  /// Behind a flag in Chrome; check [hasGetDevices] first.
  external JSPromise<JSArray<BluetoothDevice>> getDevices();
  bool get hasGetDevices => has('getDevices');
}

extension type BluetoothDevice._(JSObject _) implements web.EventTarget {
  external String get id;
  external String? get name;
  external BluetoothRemoteGATTServer? get gatt;

  /// Behind a flag in Chrome; check [hasWatchAdvertisements] first.
  external JSPromise<JSAny?> watchAdvertisements(JSObject options);
  bool get hasWatchAdvertisements => has('watchAdvertisements');
}

extension type BluetoothRemoteGATTServer._(JSObject _) implements JSObject {
  external bool get connected;
  external JSPromise<BluetoothRemoteGATTServer> connect();
  external void disconnect();
  external JSPromise<JSArray<BluetoothRemoteGATTService>> getPrimaryServices();
}

extension type BluetoothRemoteGATTService._(JSObject _) implements JSObject {
  external String get uuid;
  external bool get isPrimary;

  /// With [uuid], only those characteristics, in the same (handle) order.
  external JSPromise<JSArray<BluetoothRemoteGATTCharacteristic>>
      getCharacteristics([String uuid]);
}

extension type BluetoothRemoteGATTCharacteristic._(JSObject _)
    implements web.EventTarget {
  external String get uuid;
  external BluetoothCharacteristicProperties get properties;
  external JSDataView? get value;
  external JSPromise<JSDataView> readValue();
  external JSPromise<JSAny?> writeValue(JSAny value);
  external JSPromise<JSAny?> writeValueWithResponse(JSAny value);
  external JSPromise<JSAny?> writeValueWithoutResponse(JSAny value);
  external JSPromise<JSAny?> startNotifications();
  external JSPromise<JSAny?> stopNotifications();
  external JSPromise<JSArray<BluetoothRemoteGATTDescriptor>> getDescriptors();
  external JSPromise<BluetoothRemoteGATTDescriptor> getDescriptor(String uuid);

  /// Older browsers only have the deprecated `writeValue`.
  bool get hasExplicitWrites => has('writeValueWithResponse');
}

extension type BluetoothCharacteristicProperties._(JSObject _)
    implements JSObject {
  external bool get broadcast;
  external bool get read;
  external bool get writeWithoutResponse;
  external bool get write;
  external bool get notify;
  external bool get indicate;
  external bool get authenticatedSignedWrites;
  external bool get reliableWrite;
  external bool get writableAuxiliaries;

  /// Bit layout of `PROTOCOL.md`.
  int get bits =>
      (broadcast ? 0x01 : 0) |
      (read ? 0x02 : 0) |
      (writeWithoutResponse ? 0x04 : 0) |
      (write ? 0x08 : 0) |
      (notify ? 0x10 : 0) |
      (indicate ? 0x20 : 0) |
      (authenticatedSignedWrites ? 0x40 : 0) |
      (reliableWrite || writableAuxiliaries ? 0x80 : 0);
}

extension type BluetoothRemoteGATTDescriptor._(JSObject _) implements JSObject {
  external String get uuid;
  external JSPromise<JSDataView> readValue();
  external JSPromise<JSAny?> writeValue(JSAny value);
}

extension type BluetoothAdvertisingEvent._(JSObject _) implements web.Event {
  external BluetoothDevice get device;
  external JSArray<JSString> get uuids;
  external String? get name;
  external int? get txPower;
  external int? get rssi;

  /// Maplike: company id (number) -> DataView.
  external JSObject get manufacturerData;

  /// Maplike: service UUID (string) -> DataView.
  external JSObject get serviceData;
}

/// Iterates a JS maplike (`BluetoothManufacturerDataMap`, ...).
void forEachEntry(JSObject map, void Function(JSAny key, JSDataView value) f) {
  map.callMethod<JSAny?>(
    'forEach'.toJS,
    ((JSDataView value, JSAny key) => f(key, value)).toJS,
  );
}

/// The bytes of a Web Bluetooth value as a [Uint8List].
///
/// The spec hands out a fresh ArrayBuffer for every read and notification, so
/// dart2js can wrap it without copying. dart2wasm copies once (a bulk copy)
/// into Wasm memory; a JS-backed list would cross the interop boundary on
/// every element access.
Uint8List bytesOf(JSDataView view) {
  final data = view.toDart;
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  return _isWasm ? Uint8List.fromList(bytes) : bytes;
}

const bool _isWasm = bool.fromEnvironment('dart.tool.dart2wasm');
