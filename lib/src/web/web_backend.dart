import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'package:open_blue_plus/platform_interface.dart';

import 'scan_filter.dart';
import 'web_bluetooth.dart';
import 'web_registry.dart';

/// Web registration of `open_blue_plus` (Web Bluetooth).
///
/// Browser specifics:
/// * `startScan` opens the browser device chooser, so it must be called from
///   a user gesture (e.g. a button tap). It reports the chosen device once
///   and, when `watchAdvertisements` is available, its advertisements (RSSI).
/// * Only services listed in the scan filter or in [optionalServices] are
///   accessible after connecting.
class OpenBluePlusWeb {
  OpenBluePlusWeb._();

  /// Extra service UUIDs (any notation) the app wants to access. The browser
  /// hides every service that is neither in the scan filter nor listed here.
  static List<String> optionalServices = [];

  static void registerWith(Registrar registrar) {
    BleChannel.backend = WebBleBackend();
  }
}

/// [BleBackend] on top of `navigator.bluetooth`.
class WebBleBackend implements BleBackend {
  WebBleBackend() {
    // After a hot restart the previous run's listeners are still attached.
    unlistenAll();
    final bt = navigatorBluetooth;
    if (bt == null) return;
    listen(
      bt,
      'availabilitychanged',
      ((web.Event e) {
        final available = (e['value'] as JSBoolean?)?.toDart ?? false;
        _log(3, () => 'availability changed: $available');
        _emit({'type': 'adapterState', 'state': available ? 'on' : 'off'});
        if (!available) {
          _stopWatching();
          for (final d in _devices.values) {
            d.onDisconnected();
          }
        }
      }).toJS,
    );
  }

  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final Map<String, _Device> _devices = {};
  int _logLevel = 0;

  /// The running advertisement watch; [_scanGen] is bumped by every
  /// start/stop so a chooser that resolves late is ignored.
  _Scan? _scan;
  int _scanGen = 0;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  void _emit(Map<String, dynamic> e) => _events.add(e);

  void _log(int level, String Function() message) {
    if (level > _logLevel) return;
    final m = message();
    _emit({'type': 'log', 'level': level, 'message': m});
    if (_logLevel >= 4) {
      final js = '[open_blue_plus] $m'.toJS;
      switch (level) {
        case 1:
          web.console.error(js);
        case 2:
          web.console.warn(js);
        default:
          web.console.log(js);
      }
    }
  }

  @override
  Future<Object?> invoke(String method, Map<String, dynamic>? args) async {
    final a = args ?? const <String, dynamic>{};
    _log(4, () => _logLevel >= 5 ? '$method $a' : method);
    try {
      return await _invoke(method, a);
    } catch (e) {
      final error = _error(e);
      _log(error.code == 'gatt_error' ? 1 : 2, () => '$method failed: $error');
      throw error;
    }
  }

  Future<Object?> _invoke(String method, Map<String, dynamic> a) async {
    switch (method) {
      case 'isSupported':
        return _isSupported();
      case 'setOptions':
        return false;
      case 'setLogLevel':
        _logLevel = (a['level'] as int?) ?? 0;
        return null;
      case 'getAdapterState':
        return _adapterState();
      case 'getAdapterName':
        return '';
      case 'requestPermissions':
        return navigatorBluetooth != null;
      case 'turnOn':
      case 'turnOff':
        return false;
      case 'startScan':
        await _startScan(a);
        return null;
      case 'stopScan':
        _scanGen++;
        _stopWatching();
        return null;
      case 'getConnectedDevices':
        _adoptConnected();
        return [
          for (final d in _devices.values)
            if (d.connected) {'id': d.id, 'name': d.device.name},
        ];
      case 'getSystemDevices':
      case 'getBondedDevices':
        return const <Object>[];
      case 'getBondState':
        return 'unknown';
      case 'createBond':
      case 'removeBond':
        throw const BleException('not_supported',
            'The browser pairs on demand; bonding is not exposed');
      case 'connect':
        await _connect(await _deviceFor(a['id'] as String));
        return null;
      case 'disconnect':
        _disconnect(a['id'] as String);
        return null;
      case 'clearGattCache':
      case 'requestConnectionPriority':
      case 'setPreferredPhy':
        return null;
      case 'getPhySupport':
        return {'le2M': false, 'leCoded': false};
    }

    final d = _connected(a['id'] as String);
    final timeoutMs = a['timeoutMs'] as int?;
    switch (method) {
      case 'discoverServices':
        return d.run(() => _discover(d), timeoutMs);
      case 'read':
        return d.run(() => _read(d, a), timeoutMs);
      case 'write':
        await d.run(() => _write(d, a), timeoutMs);
        return null;
      case 'setNotify':
        await d.run(() => _setNotify(d, a), timeoutMs);
        return null;
      case 'readDescriptor':
        return d.run(() async {
          final desc = await _descriptor(d, a);
          return bytesOf(await desc.readValue().toDart);
        }, timeoutMs);
      case 'writeDescriptor':
        // The browser forbids writing the CCCD; setNotify is the way.
        if (ScanFilter.uuid(a['descriptor'] as String) == _cccd) {
          throw const BleException('not_supported',
              'Writing the CCCD is not allowed on Web; use setNotify');
        }
        return d.run(() async {
          final desc = await _descriptor(d, a);
          await desc.writeValue((a['value'] as Uint8List).toJS).toDart;
          return null;
        }, timeoutMs);
      case 'requestMtu':
        // Not exposed by Web Bluetooth and never changes: no `mtu` event.
        return 23;
      case 'readRssi':
        throw const BleException(
            'not_supported', 'RSSI of a connection is not available on Web');
    }
    throw BleException('not_supported', '$method is not supported on Web');
  }

  // ---- adapter ---------------------------------------------------------------

  /// `getAvailability()` reports whether an adapter is present.
  Future<bool> _isSupported() async {
    final bt = navigatorBluetooth;
    if (bt == null) return false;
    try {
      return (await bt.getAvailability().toDart).toDart;
    } catch (_) {
      return false;
    }
  }

  Future<String> _adapterState() async {
    final bt = navigatorBluetooth;
    if (bt == null) return 'unavailable';
    try {
      return (await bt.getAvailability().toDart).toDart ? 'on' : 'off';
    } catch (_) {
      return 'unknown';
    }
  }

  /// Replaces [e] with `adapter_off` when the failure came from the adapter
  /// being off (checked after the fact so the chooser keeps its user gesture).
  Future<BleException> _adapterOffOr(BleException e) async =>
      await _adapterState() == 'off'
          ? const BleException('adapter_off', 'Bluetooth adapter is off')
          : e;

  Bluetooth _bluetooth() =>
      navigatorBluetooth ??
      (throw const BleException('unavailable',
          'Web Bluetooth is not available (unsupported browser or insecure context)'));

  // ---- scanning --------------------------------------------------------------

  Future<void> _startScan(Map<String, dynamic> a) async {
    final bt = _bluetooth();
    _stopWatching();
    final gen = ++_scanGen;
    final filter = ScanFilter.fromArgs(a);
    final options = _chooserOptions(filter, a);

    // Called without awaiting anything first: the chooser needs the user
    // gesture that triggered startScan to still be active.
    final BluetoothDevice device;
    try {
      device = await bt.requestDevice(options).toDart;
    } catch (e) {
      throw await _adapterOffOr(_error(e));
    }
    final d = _register(device);
    if (gen != _scanGen) return; // stopScan while the chooser was open

    // An accept-all chooser lets the user pick anything: check the choice.
    final verdict =
        filter.needsAcceptAll ? filter.matchesChosen(d.id, device.name) : true;
    if (verdict == false ||
        (verdict == null && !device.hasWatchAdvertisements)) {
      _log(3, () => 'chosen device ${d.id} does not match the scan filters');
      return;
    }
    if (verdict == true) _emitScanResult(d, rssi: 0);
    final divisor = (a['continuousDivisor'] as int?) ?? 1;
    _watch(_Scan(
        d, filter, a['allowDuplicates'] == true, divisor < 1 ? 1 : divisor));
  }

  /// `requestDevice` options. Each OR entry becomes one filter object; the
  /// AND-ed prefix is copied into each of them.
  JSObject _chooserOptions(ScanFilter f, Map<String, dynamic> a) {
    final prefix = {
      if (f.namePrefix != null) 'namePrefix': f.namePrefix!.toJS,
    };
    // Chromium rejects an empty dataPrefix and a mask without one.
    JSObject data(DataFilter x) => _obj({
          'companyIdentifier': (x.key as int).toJS,
          if (x.data.isNotEmpty) 'dataPrefix': x.data.toJS,
          if (x.data.isNotEmpty && x.mask != null) 'mask': x.mask!.toJS,
        });
    final filters = f.needsAcceptAll
        ? const <JSObject>[]
        : <JSObject>[
            for (final s in f.services)
              _obj({
                'services': [s.toJS].toJS,
                ...prefix,
              }),
            for (final n in f.names) _obj({'name': n.toJS, ...prefix}),
            for (final m in f.manufacturerData)
              _obj({
                'manufacturerData': [data(m)].toJS,
                ...prefix,
              }),
            if (f.hasNoLists && prefix.isNotEmpty) _obj(prefix),
          ];
    final optional = {
      ...f.services,
      // Advertisement events only carry service data of accessible services.
      for (final s in f.serviceData) s.key as String,
      for (final s in (a['webOptionalServices'] as List?) ?? const [])
        ScanFilter.uuid(s as String),
      for (final s in OpenBluePlusWeb.optionalServices) ScanFilter.uuid(s),
    };
    final companies = {for (final m in f.manufacturerData) m.key as int};
    return _obj({
      if (filters.isEmpty)
        'acceptAllDevices': true.toJS
      else
        'filters': filters.toJS,
      if (optional.isNotEmpty)
        'optionalServices': [for (final s in optional) s.toJS].toJS,
      // Without this the advertisement events hide the manufacturer data.
      if (companies.isNotEmpty)
        'optionalManufacturerData': [for (final c in companies) c.toJS].toJS,
    });
  }

  /// Streams advertisements of the chosen device where `watchAdvertisements`
  /// exists. Without duplicates only the first matching one is reported,
  /// which supplies the RSSI the chooser does not give.
  void _watch(_Scan scan) {
    final device = scan.device.device;
    if (!device.hasWatchAdvertisements) return;
    final abort = web.AbortController();
    _scan = scan;
    scanAbort = abort;
    listen(
        device,
        'advertisementreceived',
        ((web.Event e) =>
            _onAdvertisement(scan, e as BluetoothAdvertisingEvent)).toJS);
    void failed(Object e) {
      if (!identical(_scan, scan)) return; // aborted by stopScan
      _log(2, () => 'watchAdvertisements failed: ${_error(e).message}');
      _stopWatching();
    }

    try {
      device
          .watchAdvertisements(_obj({'signal': abort.signal}))
          .toDart
          .then((_) {}, onError: failed);
    } catch (e) {
      failed(e);
    }
  }

  /// Also stops a watch left running by the run before a hot restart.
  void _stopWatching() {
    final scan = _scan;
    _scan = null;
    if (scan != null) unlisten(scan.device.device, 'advertisementreceived');
    scanAbort?.abort();
    scanAbort = null;
  }

  void _onAdvertisement(_Scan scan, BluetoothAdvertisingEvent e) {
    if (!identical(_scan, scan)) return;
    final d = scan.device;
    final localName = e.name;
    final serviceUuids = [for (final u in e.uuids.toDart) u.toDart];
    final manufacturer = <int, Uint8List>{};
    forEachEntry(e.manufacturerData,
        (k, v) => manufacturer[(k as JSNumber).toDartInt] = bytesOf(v));
    final serviceData = <String, Uint8List>{};
    forEachEntry(e.serviceData,
        (k, v) => serviceData[(k as JSString).toDart] = bytesOf(v));
    if (!scan.filter.matches(
      id: d.id,
      name: d.device.name ?? localName,
      serviceUuids: serviceUuids,
      manufacturerData: manufacturer,
      serviceData: serviceData,
    )) {
      return;
    }
    final n = scan.matched++;
    if (n % scan.divisor == 0) {
      _emitScanResult(
        d,
        rssi: e.rssi ?? 0,
        localName: localName,
        txPowerLevel: e.txPower,
        manufacturerData: manufacturer,
        serviceData: serviceData,
        serviceUuids: serviceUuids,
      );
    }
    if (!scan.allowDuplicates) _stopWatching();
  }

  void _emitScanResult(
    _Device d, {
    required int rssi,
    String? localName,
    int? txPowerLevel,
    Map<int, Uint8List> manufacturerData = const {},
    Map<String, Uint8List> serviceData = const {},
    List<String> serviceUuids = const [],
  }) {
    _log(5, () => 'scanResult ${d.id} rssi $rssi');
    _emit({
      'type': 'scanResult',
      'id': d.id,
      'name': d.device.name,
      'rssi': rssi,
      'connectable': true,
      'localName': localName,
      'txPowerLevel': txPowerLevel,
      'manufacturerData': manufacturerData,
      'serviceData': serviceData,
      'serviceUuids': serviceUuids,
    });
  }

  // ---- devices ---------------------------------------------------------------

  _Device _register(BluetoothDevice device) {
    final existing = _devices[device.id];
    if (existing != null) return existing;
    final d = _Device(device, _emit);
    _devices[d.id] = d;
    rememberDevice(device);
    // Ignore an event that arrives after a newer connect() succeeded.
    listen(
        device,
        'gattserverdisconnected',
        ((web.Event _) {
          if (device.gatt?.connected != true) d.onDisconnected();
        }).toJS);
    // Fired at a service and bubbling up to the device.
    for (final type in const [
      'serviceadded',
      'servicechanged',
      'serviceremoved'
    ]) {
      listen(device, type, ((web.Event _) => d.onServicesChanged()).toJS);
    }
    return d;
  }

  /// Picks up connections that outlived a hot restart: the page (and its
  /// BluetoothDevice objects) survived, this backend did not.
  void _adoptConnected() {
    for (final device in rememberedDevices()) {
      if (_devices.containsKey(device.id)) continue;
      if (device.gatt?.connected != true) continue;
      final d = _register(device);
      d.onConnected(emit: false);
      _log(3, () => 'adopted connection to ${d.id}');
      // Rebuilds the attribute map in the order discoverServices reports it,
      // so notifications started before the restart reach Dart again.
      d.run(() => _discover(d)).ignore();
    }
  }

  /// Devices chosen earlier in this page (before a hot restart) or, where the
  /// browser supports `getDevices()`, in an earlier page load.
  Future<_Device> _deviceFor(String id) async {
    final known = _devices[id];
    if (known != null) return known;
    for (final device in rememberedDevices()) {
      if (device.id == id) return _register(device);
    }
    final bt = _bluetooth();
    if (bt.hasGetDevices) {
      try {
        for (final dev in (await bt.getDevices().toDart).toDart) {
          if (dev.id == id) return _register(dev);
        }
      } catch (_) {}
    }
    throw BleException(
        'not_found', 'Device $id was not chosen in this page; scan first');
  }

  _Device _connected(String id) {
    final d = _devices[id];
    if (d == null || !d.connected) {
      throw BleException('not_connected', 'Device $id is not connected');
    }
    return d;
  }

  /// Concurrent calls share the pending attempt: starting a second one would
  /// make the first look cancelled and tear the connection down.
  Future<void> _connect(_Device d) {
    if (d.connected) return Future.value();
    final pending = d.connecting;
    if (pending != null) return pending;
    late final Future<void> f;
    f = _attemptConnect(d, ++d.attempt).whenComplete(() {
      if (identical(d.connecting, f)) d.connecting = null;
    });
    return d.connecting = f;
  }

  Future<void> _attemptConnect(_Device d, int attempt) async {
    final server = d.device.gatt ??
        (throw const BleException(
            'connect_failed', 'Device has no GATT server'));
    try {
      await server.connect().toDart;
    } catch (e) {
      throw await _adapterOffOr(
          BleException('connect_failed', _error(e).message));
    }
    // A disconnect() during the attempt cancels it. Leave the link alone if
    // a newer connect() is already using it.
    if (attempt != d.attempt || !server.connected) {
      if (d.connecting == null) server.disconnect();
      throw const BleException('connect_failed', 'Connection cancelled');
    }
    d.onConnected();
  }

  void _disconnect(String id) {
    final d = _devices[id];
    if (d == null) return;
    d.attempt++;
    d.connecting = null;
    d.device.gatt?.disconnect();
    d.onDisconnected();
  }

  // ---- GATT ------------------------------------------------------------------

  /// Chrome exposes neither secondary nor included services: the list holds
  /// the accessible primary services, duplicated UUIDs included.
  Future<List<Map<String, dynamic>>> _discover(_Device d) async {
    d.discovering = true;
    final old = d.chars;
    final fresh = <String, _Char>{};
    try {
      final services = await _primaryServices(d);
      d.services = services;
      final result = <Map<String, dynamic>>[];
      final serviceCount = <String, int>{};
      for (final s in services) {
        final su = s.uuid;
        final si = serviceCount[su] ?? 0;
        serviceCount[su] = si + 1;
        final charCount = <String, int>{};
        final chars = <Map<String, dynamic>>[];
        for (final c in await _tolerant(s.getCharacteristics())) {
          final cu = c.uuid;
          final ci = charCount[cu] ?? 0;
          charCount[cu] = ci + 1;
          final k = _Device.key(su, si, cu, ci);
          // Same attribute = same JS object while connected; keep its
          // listener so no notification is lost during rediscovery.
          final previous = old.remove(k);
          if (previous != null && previous.js.strictEquals(c).toDart) {
            fresh[k] = previous;
          } else {
            previous?.dispose();
            fresh[k] = d.newChar(su, si, cu, ci, c);
          }
          final descriptors = await _tolerant(c.getDescriptors());
          chars.add({
            'uuid': cu,
            'properties': c.properties.bits,
            'descriptors': [for (final x in descriptors) x.uuid],
          });
        }
        result.add({
          'uuid': su,
          'primary': s.isPrimary,
          'included': const <int>[],
          'characteristics': chars,
        });
      }
      // A disconnect meanwhile already failed the call; drop the stale map.
      if (!d.connected) {
        throw BleException('not_connected', 'Device ${d.id} disconnected');
      }
      for (final c in old.values) {
        c.dispose();
      }
      d.chars = fresh;
      return result;
    } catch (_) {
      for (final c in [...old.values, ...fresh.values]) {
        c.dispose();
      }
      d.chars = {};
      d.services = null;
      rethrow;
    } finally {
      d.discovering = false;
    }
  }

  Future<List<BluetoothRemoteGATTService>> _primaryServices(_Device d) async {
    final server = d.device.gatt ??
        (throw BleException('not_connected', 'Device ${d.id} has no GATT'));
    try {
      return (await server.getPrimaryServices().toDart).toDart;
    } catch (e) {
      // NotFoundError: no (accessible) services.
      if (_error(e).code == 'not_found') return const [];
      rethrow;
    }
  }

  /// Child lookups fail with NotFoundError when empty or blocklisted.
  Future<List<T>> _tolerant<T extends JSAny>(JSPromise<JSArray<T>> p) async {
    try {
      return (await p.toDart).toDart;
    } catch (_) {
      return const [];
    }
  }

  /// Resolves the characteristic address, lazily (same order as discovery)
  /// when it was not discovered yet.
  Future<_Char> _characteristic(_Device d, Map<String, dynamic> a) async {
    final s = ScanFilter.uuid(a['service'] as String);
    final si = (a['serviceIndex'] as int?) ?? 0;
    final c = ScanFilter.uuid(a['characteristic'] as String);
    final ci = (a['characteristicIndex'] as int?) ?? 0;
    final k = _Device.key(s, si, c, ci);
    final cached = d.chars[k];
    if (cached != null) return cached;
    final services = d.services ??= await _primaryServices(d);
    final matching = [
      for (final x in services)
        if (x.uuid == s) x
    ];
    if (si >= matching.length) {
      throw BleException('not_found', 'Service $s #$si not found');
    }
    final chars = (await matching[si].getCharacteristics(c).toDart).toDart;
    if (ci >= chars.length) {
      throw BleException('not_found', 'Characteristic $c #$ci not found');
    }
    return d.chars[k] ??= d.newChar(s, si, c, ci, chars[ci]);
  }

  Future<BluetoothRemoteGATTDescriptor> _descriptor(
      _Device d, Map<String, dynamic> a) async {
    final c = await _characteristic(d, a);
    return c.js
        .getDescriptor(ScanFilter.uuid(a['descriptor'] as String))
        .toDart;
  }

  Future<Uint8List> _read(_Device d, Map<String, dynamic> a) async {
    final c = await _characteristic(d, a);
    // The browser also fires characteristicvaluechanged for reads with the
    // same DataView; deliver() emits the value event only once.
    return c.deliver(await c.js.readValue().toDart);
  }

  Future<void> _write(_Device d, Map<String, dynamic> a) async {
    final c = await _characteristic(d, a);
    final value = (a['value'] as Uint8List).toJS;
    if (!c.js.hasExplicitWrites) {
      await c.js.writeValue(value).toDart;
    } else if (a['withoutResponse'] == true) {
      await c.js.writeValueWithoutResponse(value).toDart;
    } else {
      await c.js.writeValueWithResponse(value).toDart;
    }
  }

  /// The browser picks notify or indicate (`forceIndications` is ignored).
  Future<void> _setNotify(_Device d, Map<String, dynamic> a) async {
    final c = await _characteristic(d, a);
    if (a['enable'] == true) {
      await c.js.startNotifications().toDart;
    } else {
      final p = c.js.properties;
      // Chrome rejects stopNotifications on such characteristics.
      if (!p.notify && !p.indicate) return;
      await c.js.stopNotifications().toDart;
    }
  }

  // ---- helpers ---------------------------------------------------------------

  /// The browser always returns the canonical lowercase 128-bit form, so its
  /// UUIDs need no conversion.
  static const _cccd = '00002902-0000-1000-8000-00805f9b34fb';

  static JSObject _obj(Map<String, JSAny> fields) {
    final o = JSObject();
    fields.forEach((k, v) => o[k] = v);
    return o;
  }
}

/// Maps a rejected Web Bluetooth promise (a DOMException) or any other
/// failure to a [BleException].
BleException _error(Object e) {
  if (e is BleException) return e;
  if (e is ArgumentError || e is TypeError || e is FormatException) {
    return BleException('invalid_argument', '$e');
  }
  String? name;
  String? message;
  try {
    // Promise rejections surface as the raw JS error object.
    final js = e as JSObject;
    name = (js['name'] as JSString?)?.toDart;
    message = (js['message'] as JSString?)?.toDart;
  } catch (_) {
    message = '$e';
  }
  final code = switch (name) {
    'NotFoundError' => 'not_found', // includes "chooser cancelled"
    'SecurityError' || 'NotAllowedError' => 'permission_denied',
    'NetworkError' => 'not_connected',
    'NotSupportedError' => 'not_supported',
    'TypeError' || 'InvalidModificationError' => 'invalid_argument',
    // Chromium: the service/characteristic/descriptor no longer exists.
    'InvalidStateError' => 'not_found',
    _ => 'gatt_error',
  };
  return BleException(code, name == null ? message : '$name: $message');
}

/// An advertisement watch started by `startScan`.
class _Scan {
  _Scan(this.device, this.filter, this.allowDuplicates, this.divisor);

  final _Device device;
  final ScanFilter filter;
  final bool allowDuplicates;
  final int divisor;

  /// Matching advertisements seen so far (for `continuousDivisor`).
  int matched = 0;
}

/// State kept for one chosen device.
class _Device {
  _Device(this.device, this._emit);

  final BluetoothDevice device;
  final void Function(Map<String, dynamic>) _emit;

  /// Primary services in `getPrimaryServices()` order; null until fetched.
  List<BluetoothRemoteGATTService>? services;
  Map<String, _Char> chars = {};

  bool connected = false;
  bool discovering = false;
  Timer? _resetTimer;

  /// Bumped by disconnect() to cancel a pending connect.
  int attempt = 0;

  /// Web Bluetooth rejects concurrent GATT operations ("operation already in
  /// progress"), so they run one at a time.
  Future<void> _queue = Future.value();
  Completer<Never> _lost = Completer();

  String get id => device.id;

  static String key(String service, int serviceIndex, String characteristic,
          int characteristicIndex) =>
      '$service#$serviceIndex|$characteristic#$characteristicIndex';

  /// Pending connect shared by concurrent `connect` calls.
  Future<void>? connecting;

  /// Runs [op] after the previous operation; fails with `not_connected` as
  /// soon as the device disconnects and with `timeout` after [timeoutMs], so
  /// a promise the browser never settles cannot block the queue. An op
  /// queued before a disconnect never starts, even if the device has
  /// reconnected by its turn.
  Future<T> run<T>(Future<T> Function() op, [int? timeoutMs]) {
    final lost = _lost;
    final result = _queue.then((_) {
      if (lost.isCompleted) return lost.future;
      final f = Future.any<T>([_guard(op), lost.future]);
      if (timeoutMs == null || timeoutMs <= 0) return f;
      return f.timeout(Duration(milliseconds: timeoutMs),
          onTimeout: () => throw BleException(
              'timeout', 'Operation did not complete in $timeoutMs ms'));
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Chromium also uses NetworkError for "operation already in progress"
  /// (e.g. after a timed-out operation) and pairing failures: it only means
  /// `not_connected` when the link is really gone.
  Future<T> _guard<T>(Future<T> Function() op) async {
    try {
      return await op();
    } catch (e) {
      final error = _error(e);
      if (error.code == 'not_connected' && device.gatt?.connected == true) {
        throw BleException('gatt_error', error.message);
      }
      throw error;
    }
  }

  _Char newChar(String service, int serviceIndex, String characteristic,
      int characteristicIndex, BluetoothRemoteGATTCharacteristic js) {
    return _Char(js, (bytes) {
      _emit({
        'type': 'value',
        'id': id,
        'service': service,
        'serviceIndex': serviceIndex,
        'characteristic': characteristic,
        'characteristicIndex': characteristicIndex,
        'value': bytes,
      });
    });
  }

  void _invalidate() {
    for (final c in chars.values) {
      c.dispose();
    }
    chars = {};
    services = null;
  }

  /// Bursts of service events (one per changed service) collapse into one
  /// `servicesReset`. Events during our own discovery are ignored.
  void onServicesChanged() {
    if (!connected || discovering) return;
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(milliseconds: 100), () {
      _resetTimer = null;
      if (!connected) return;
      _invalidate();
      _emit({'type': 'servicesReset', 'id': id});
    });
  }

  void onConnected({bool emit = true}) {
    connected = true;
    _lost = Completer();
    if (emit) _emit({'type': 'connectionState', 'id': id, 'connected': true});
  }

  void onDisconnected() {
    _resetTimer?.cancel();
    _resetTimer = null;
    // The browser drops its attribute objects on disconnection.
    _invalidate();
    if (!connected) return;
    connected = false;
    _lost.future.ignore();
    _lost.completeError(
        BleException('not_connected', 'Device $id disconnected'));
    _emit({'type': 'connectionState', 'id': id, 'connected': false});
  }
}

/// A characteristic plus its `characteristicvaluechanged` listener (at most
/// one per JS object, see [listen]).
class _Char {
  _Char(this.js, this._onValue) {
    listen(js, 'characteristicvaluechanged', _listener);
  }

  final BluetoothRemoteGATTCharacteristic js;
  final void Function(Uint8List) _onValue;
  JSDataView? _lastView;
  Uint8List? _lastBytes;

  late final JSFunction _listener = ((web.Event _) {
    final v = js.value;
    if (v != null) deliver(v);
  }).toJS;

  /// Emits [view] as a `value` event unless it was already emitted, and
  /// returns its bytes.
  Uint8List deliver(JSDataView view) {
    final last = _lastView;
    if (last != null && last.strictEquals(view).toDart) return _lastBytes!;
    final bytes = bytesOf(view);
    _lastView = view;
    _lastBytes = bytes;
    _onValue(bytes);
    return bytes;
  }

  void dispose() => unlisten(js, 'characteristicvaluechanged', _listener);
}
