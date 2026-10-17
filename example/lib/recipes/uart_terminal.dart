// Recipe: serial-like terminal over the Nordic UART Service (NUS), used by
// many microcontroller boards (nRF52, ESP32 BLE UART examples, etc.).
//
// Shows how to send data larger than one packet: writes without response
// must fit in `mtu - 3` bytes, so the message is split in chunks.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:open_blue_plus/open_blue_plus.dart';

final nusService = BleUuid('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
final nusRx = BleUuid('6e400002-b5a3-f393-e0a9-e50e24dcca9e'); // app -> device
final nusTx = BleUuid('6e400003-b5a3-f393-e0a9-e50e24dcca9e'); // device -> app

/// A connected UART session.
class UartSession {
  final BleDevice device;
  final BleCharacteristic _rx;
  final BleCharacteristic _tx;

  UartSession._(this.device, this._rx, this._tx);

  /// Connects to [device] (requesting a large MTU) and opens the session.
  static Future<UartSession> open(BleDevice device) async {
    await device.connect(mtu: 247);
    await device.discoverServices();
    final s = device.service(nusService);
    final rx = s?.characteristic(nusRx);
    final tx = s?.characteristic(nusTx);
    if (rx == null || tx == null) {
      await device.disconnect();
      throw const BleException('not_found', 'Nordic UART Service missing');
    }
    await tx.setNotify(true);
    return UartSession._(device, rx, tx);
  }

  /// Bytes received from the device.
  Stream<Uint8List> get received => _tx.onValue;

  /// Text received from the device (UTF-8, tolerant to split characters).
  Stream<String> get lines => _tx.onValue
      .cast<List<int>>()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());

  /// Sends [data], split into packets that fit the current MTU.
  ///
  /// Uses write without response when the characteristic supports it (fast,
  /// typical for UART); writes are queued in order by the plugin.
  Future<void> send(List<int> data) async {
    final fast = _rx.properties.writeWithoutResponse;
    final chunk = fast ? device.mtu - 3 : BleCharacteristic.maxLongWriteLength;
    for (var i = 0; i < data.length; i += chunk) {
      final end = i + chunk < data.length ? i + chunk : data.length;
      await _rx.write(data.sublist(i, end), withoutResponse: fast);
    }
  }

  /// Sends a text line terminated by `\n`.
  Future<void> sendLine(String text) => send(utf8.encode('$text\n'));

  Future<void> close() => device.disconnect();
}
