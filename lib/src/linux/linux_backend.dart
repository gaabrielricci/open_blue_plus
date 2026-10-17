import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluez/bluez.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:open_blue_plus/platform_interface.dart';

import 'bluez_mapping.dart';

/// Linux implementation, registered by the Flutter tool.
class OpenBluePlusLinux {
  static void registerWith() {
    // Registering again in the same isolate must not leave the previous
    // backend's discovery, agent or D-Bus connection behind.
    final previous = BleChannel.backend;
    if (previous is LinuxBleBackend) previous.close().ignore();
    BleChannel.backend = LinuxBleBackend();
  }
}

/// [BleBackend] talking to BlueZ over the system D-Bus.
///
/// Adapters and devices go through package:bluez; the GATT database is read
/// with package:dbus directly because package:bluez exposes neither object
/// paths (needed for a stable order) nor `Includes`.
class LinuxBleBackend implements BleBackend {
  static const _bluez = 'org.bluez';
  static const _defaultMtu = 23;
  static const _cccd = '00002902-0000-1000-8000-00805f9b34fb';
  static const _gattMethods = {
    'discoverServices',
    'read',
    'write',
    'setNotify',
    'readDescriptor',
    'writeDescriptor',
    'requestMtu',
    'readRssi',
  };

  /// Device properties that carry advertisement data while scanning.
  static const _advertisementProperties = {
    'RSSI',
    'ManufacturerData',
    'ServiceData',
    'Name',
    'UUIDs',
    'TxPower',
  };
  static final _agentPath =
      DBusObjectPath('/com/riccimobile/open_blue_plus/agent');

  late final StreamController<Map<String, dynamic>> _events =
      StreamController.broadcast(onListen: () => _ready().ignore());

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  DBusClient? _bus;
  BlueZClient? _client;
  DBusRemoteObjectManager? _objectManager;
  Future<void>? _init;
  bool _closed = false;
  int _logLevel = 0;
  BlueZAdapter? _adapter;
  StreamSubscription<List<String>>? _adapterSub;
  String? _lastAdapterState;
  final List<StreamSubscription<Object?>> _busSubs = [];

  /// Property watchers per device address.
  final Map<String, StreamSubscription<List<String>>> _deviceSubs = {};

  /// Devices connected through this plugin, by address.
  final Map<String, _Session> _sessions = {};

  /// Connects in flight, by address; completing the error aborts the call.
  final Map<String, Completer<void>> _pendingConnects = {};

  /// Notification sessions, by characteristic object path.
  final Map<String, _Notification> _notifying = {};

  /// Last `Device1.Disconnected` signal per session device path.
  final Map<String, (String, String)> _disconnectReasons = {};

  // Bonding.
  final Map<String, Future<void>> _bonding = {};
  final Set<Completer<void>> _pendingBonds = {};
  final Map<String, String> _bondStates = {};
  final Map<String, String> _agentPins = {};
  final SerialQueue _agentQueue = SerialQueue();

  /// Exported and registered while [_agentPins] is not empty.
  _PinAgent? _agent;

  // Scan state; null filter = not scanning.
  ScanFilter? _scan;
  bool _allowDuplicates = false;
  ContinuousDivisor? _divisor;
  final Set<String> _seen = {};

  /// Devices that failed the scan filters, re-checked only when a property
  /// in [ScanFilter.relevantProperties] changes.
  final Set<String> _rejected = {};
  final SerialQueue _scanQueue = SerialQueue();

  // ---- setup ----------------------------------------------------------------

  Future<void> _ready() => _init ??= _connectBus();

  Future<void> _connectBus() async {
    if (_closed) return;
    DBusClient? bus;
    BlueZClient client;
    try {
      bus = DBusClient.system();
      client = BlueZClient(bus: bus);
      await _guarded(client.connect).timeout(const Duration(seconds: 10));
    } catch (e) {
      // No system bus or no bluetoothd: report `unavailable`, retry later.
      _init = null;
      _log(2, 'BlueZ not reachable: $e');
      if (bus != null) unawaited(_guarded(bus.close).catchError((_) {}));
      _emitAdapterState();
      return;
    }
    if (_closed) {
      unawaited(_guarded(bus.close).catchError((_) {}));
      return;
    }
    _bus = bus;
    _client = client;
    _objectManager =
        DBusRemoteObjectManager(bus, name: _bluez, path: DBusObjectPath('/'));
    // Same match rule package:bluez already holds, so no extra traffic.
    _busSubs.add(DBusSignalStream(bus, sender: _bluez)
        .listen(_onSignal, onError: (Object _) {}));
    // Subscribed after connect(): the initial objects are handled below.
    _busSubs.addAll([
      client.adapterAdded.listen((_) => _pickAdapter()),
      client.adapterRemoved.listen((_) => _pickAdapter()),
      client.deviceAdded.listen(_watchDevice),
      client.deviceRemoved.listen(_onDeviceRemoved),
    ]);
    _pickAdapter();
    for (final d in client.devices) {
      _watchDevice(d);
    }
    _adoptSessions();
  }

  /// Runs [body] so that errors package:dbus raises outside the returned
  /// future (it does when the bus socket is missing, leaving connect()
  /// pending forever) fail the result instead of reaching the app's zone.
  static Future<void> _guarded(Future<void> Function() body) {
    final done = Completer<void>();
    void fail(Object e, StackTrace st) {
      if (!done.isCompleted) done.completeError(e, st);
    }

    runZonedGuarded(() {
      body().then((_) {
        if (!done.isCompleted) done.complete();
      }, onError: fail);
    }, fail);
    return done.future;
  }

  /// Releases everything this backend holds on the bus. Connections stay up
  /// and are adopted by the next backend of this process (see
  /// [_adoptSessions]).
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _scanQueue.run(_stopScan);
    } catch (_) {}
    for (final s in _sessions.values) {
      _closeSession(s);
    }
    _sessions.clear();
    _adapterSub?.cancel().ignore();
    for (final sub in [..._busSubs, ..._deviceSubs.values]) {
      sub.cancel().ignore();
    }
    _busSubs.clear();
    _deviceSubs.clear();
    final bus = _bus;
    _bus = null;
    _client = null;
    _adapter = null;
    // Closing the bus also drops our agent registration and notify sessions.
    if (bus != null) await _guarded(bus.close).catchError((_) {});
    await _events.close();
  }

  void _emit(Map<String, dynamic> event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _log(int level, String message) {
    if (level <= _logLevel) {
      _emit({'type': 'log', 'level': level, 'message': message});
    }
  }

  void _pickAdapter() {
    final adapters = _client?.adapters ?? const <BlueZAdapter>[];
    final next = adapters.isEmpty ? null : adapters.first;
    // Always resubscribe: an adapter removed and added again (USB dongle,
    // bluetoothd restart) keeps its address but is a new object, and the
    // old object's stream never fires again.
    _adapterSub?.cancel();
    if (next?.address != _adapter?.address) {
      // Discovery and connections, if any, ran on the previous adapter.
      _scan = null;
      _dropConnections('Bluetooth adapter removed');
    }
    _adapter = next;
    _adapterSub = next?.propertiesChanged.listen((props) {
      if (props.contains('Powered')) _emitAdapterState();
    });
    _emitAdapterState();
  }

  String _adapterState() {
    final a = _adapter;
    if (_client == null || a == null) return 'unavailable';
    return a.powered ? 'on' : 'off';
  }

  void _emitAdapterState() {
    final s = _adapterState();
    if (s != 'on') {
      _scan = null;
      // Don't wait for BlueZ to report each device: it may never do so
      // when the adapter disappears.
      _dropConnections('Bluetooth is off');
    }
    if (s == _lastAdapterState) return;
    _lastAdapterState = s;
    _log(3, 'adapter $s');
    _emit({'type': 'adapterState', 'state': s});
  }

  BlueZAdapter _poweredAdapter() {
    final a = _adapter;
    if (_client == null || a == null) {
      throw const BleException('unavailable', 'No Bluetooth adapter');
    }
    if (!a.powered) throw const BleException('adapter_off', 'Bluetooth is off');
    return a;
  }

  bool _onAdapter(BlueZDevice d) {
    try {
      return d.adapter.address == _adapter?.address;
    } catch (_) {
      // The adapter object is already gone.
      return false;
    }
  }

  // ---- dispatch -------------------------------------------------------------

  @override
  Future<Object?> invoke(String method, Map<String, dynamic>? args) async {
    final a = args ?? const <String, dynamic>{};
    // Called at start-up: must not need (or open) the bus.
    if (method == 'setLogLevel') {
      _logLevel = (a['level'] as int?) ?? 0;
      return null;
    }
    if (method == 'stopScan' && _init == null) return null;
    await _ready();
    if (_logLevel >= 5) _log(5, '$method $a');
    try {
      return await _dispatch(method, a);
    } on BleException catch (e) {
      _log(4, '$method failed: $e');
      rethrow;
    } on FormatException catch (e) {
      // Malformed UUID in the arguments.
      throw BleException('invalid_argument', '${e.message}: ${e.source}');
    } catch (e) {
      final ex = bleExceptionForError(e) ?? BleException('gatt_error', '$e');
      _log(ex.code == 'gatt_error' ? 1 : 4, '$method failed: $e');
      if (method == 'connect' &&
          ex.code != 'adapter_off' &&
          ex.code != 'unavailable') {
        throw BleException('connect_failed', ex.message, ex.status);
      }
      throw ex;
    }
  }

  Future<Object?> _dispatch(String method, Map<String, dynamic> a) async {
    switch (method) {
      case 'isSupported':
        return _client != null && _adapter != null;
      case 'setOptions':
        return false;
      case 'getAdapterState':
        return _adapterState();
      case 'getAdapterName':
        return _adapter?.alias ?? '';
      case 'requestPermissions':
        return true;
      case 'turnOn':
        return _setPowered(true);
      case 'turnOff':
        return _setPowered(false);
      case 'startScan':
        await _scanQueue.run(() => _startScan(a));
        return null;
      case 'stopScan':
        await _scanQueue.run(_stopScan);
        return null;
      case 'getBondedDevices':
        return [
          for (final d in _client?.devices ?? const <BlueZDevice>[])
            if (d.paired && _onAdapter(d)) _deviceMap(d),
        ];
      case 'getSystemDevices':
        final services = {
          for (final u in (a['services'] as List?) ?? const []) fullUuid('$u'),
        };
        return [
          for (final d in _client?.devices ?? const <BlueZDevice>[])
            if (d.connected &&
                _onAdapter(d) &&
                (services.isEmpty ||
                    d.uuids.any((u) => services.contains(fullUuid('$u')))))
              _deviceMap(d),
        ];
      case 'getBondState':
        final d = _device(a['id'] as String);
        if (d == null) return 'none';
        if (_bonding.containsKey(d.address)) return 'bonding';
        return d.paired ? 'bonded' : 'none';
      case 'createBond':
        await _createBond(a);
        return null;
      case 'removeBond':
        await _removeBond(a['id'] as String);
        return null;
      case 'getConnectedDevices':
        // Only our sessions: they are the ones that get `connectionState`
        // false later. BlueZ connections are system wide.
        return [for (final s in _sessions.values) _deviceMap(s.device)];
      case 'connect':
        await _connect(a['id'] as String);
        return null;
      case 'disconnect':
        await _disconnect(a['id'] as String);
        return null;
      case 'getPhySupport':
        return {'le2M': false, 'leCoded': false};
      // BlueZ manages the GATT cache, PHY and connection parameters itself.
      case 'requestConnectionPriority':
      case 'setPreferredPhy':
      case 'clearGattCache':
        return null;
    }
    if (!_gattMethods.contains(method)) {
      throw BleException('not_supported', 'Unknown method $method');
    }

    final s = _session(a['id'] as String);
    switch (method) {
      case 'discoverServices':
        final tree = await s.guard(_discover(s));
        return [for (final svc in tree) serviceToMap(svc)];
      case 'read':
        return s.guard(_read(s, a));
      case 'write':
        return s.guard(_write(s, a));
      case 'setNotify':
        return s.guard(_setNotify(s, a, a['enable'] == true));
      case 'readDescriptor':
        return s.guard(_readDescriptor(s, a));
      case 'writeDescriptor':
        return s.guard(_writeDescriptor(s, a));
      case 'requestMtu':
        return s.guard(_requestMtu(s));
      case 'readRssi':
        // BlueZ only refreshes RSSI while discovering; 0 means absent.
        final rssi = s.device.rssi;
        if (rssi == 0) {
          throw const BleException(
              'not_supported', 'RSSI is not available on this connection');
        }
        return rssi;
    }
    return null;
  }

  Future<bool> _setPowered(bool on) async {
    final adapter = _adapter;
    if (_client == null || adapter == null) return false;
    try {
      await adapter.setPowered(on);
      return true;
    } catch (e) {
      // e.g. blocked by rfkill.
      _log(2, 'setting Powered=$on failed: $e');
      return false;
    }
  }

  // ---- scanning -------------------------------------------------------------

  Future<void> _startScan(Map<String, dynamic> a) async {
    // Arguments first: a bad UUID is `invalid_argument` in any state.
    final filter = ScanFilter.fromArgs(a);
    final adapter = _poweredAdapter();
    if (_scan != null) await _stopScan();
    _seen.clear();
    _rejected.clear();
    _allowDuplicates = a['allowDuplicates'] == true;
    final divisor = (a['continuousDivisor'] as int?) ?? 1;
    _divisor =
        _allowDuplicates && divisor > 1 ? ContinuousDivisor(divisor) : null;
    try {
      await adapter.setDiscoveryFilter(
        transport: 'le',
        uuids: filter.discoveryUuids,
        duplicateData: _allowDuplicates,
      );
    } on BlueZInvalidArgumentsException {
      // BlueZ < 5.48 has no DuplicateData; it reports every change anyway.
      await adapter.setDiscoveryFilter(
          transport: 'le', uuids: filter.discoveryUuids);
    }
    _scan = filter;
    try {
      await adapter.startDiscovery();
    } on BlueZInProgressException {
      // BlueZ allows one discovery per D-Bus client: ours is still running
      // (an earlier StopDiscovery failed or the state was reset), so the
      // new filter already applies.
    } catch (_) {
      _scan = null;
      rethrow;
    }
    _log(3, 'scan started');
  }

  Future<void> _stopScan() async {
    if (_scan == null) return;
    _scan = null;
    _divisor = null;
    try {
      await _adapter?.stopDiscovery();
    } on DBusMethodResponseException {
      // Already stopped (adapter reset, powered off, ...).
    }
    _log(3, 'scan stopped');
  }

  /// [changed]: the properties that triggered the call, null for a new
  /// device.
  void _maybeReport(BlueZDevice d, [List<String>? changed]) {
    final filter = _scan;
    if (filter == null) return;
    final id = d.address;
    if (!_allowDuplicates && _seen.contains(id)) return;
    // Hot path while scanning: skip devices already rejected by the filters
    // unless something the filters look at changed.
    if (changed != null &&
        _rejected.contains(id) &&
        !changed.any(filter.relevantProperties.contains)) {
      return;
    }
    // RSSI is only present for devices seen during the current discovery.
    final rssi = d.rssi;
    if (rssi == 0) return;
    final name = _nameOf(d);
    final uuids = [for (final u in d.uuids) u.toString()];
    final serviceData = {
      for (final e in d.serviceData.entries) e.key.toString(): e.value,
    };
    final manufacturerData = {
      for (final e in d.manufacturerData.entries) e.key.id: e.value,
    };
    if (!filter.matches(
      id: id,
      name: name,
      serviceUuids: uuids,
      manufacturerData: manufacturerData,
      serviceData: serviceData,
    )) {
      _rejected.add(id);
      return;
    }
    _rejected.remove(id);
    if (_allowDuplicates) {
      if (_divisor?.shouldReport(id) == false) return;
    } else {
      _seen.add(id);
    }
    _emit(scanResultEvent(
      id: id,
      name: name,
      rssi: rssi,
      txPower: d.txPower,
      manufacturerData: manufacturerData,
      serviceData: serviceData,
      serviceUuids: uuids,
    ));
  }

  /// The advertised (remote) name.
  static String? _nameOf(BlueZDevice d) => d.name.isEmpty ? null : d.name;

  /// The name the desktop shows: `Alias` (user set, else the remote name),
  /// without BlueZ' fallback to the address.
  static String? _displayName(BlueZDevice d) {
    final alias = d.alias;
    if (alias.isNotEmpty && alias != d.address.replaceAll(':', '-')) {
      return alias;
    }
    return _nameOf(d);
  }

  static Map<String, Object?> _deviceMap(BlueZDevice d) =>
      {'id': d.address, 'name': _displayName(d)};

  // ---- devices --------------------------------------------------------------

  void _watchDevice(BlueZDevice d) {
    final id = d.address;
    _deviceSubs[id]?.cancel();
    _deviceSubs[id] = d.propertiesChanged.listen((props) {
      if (props.contains('Connected') && !d.connected) _onDisconnected(id);
      if (props.contains('Paired')) _emitBond(id, d.paired ? 'bonded' : 'none');
      final s = _sessions[id];
      if (s != null) {
        if (props.contains('Name') || props.contains('Alias')) _emitName(s);
        if (props.contains('ServicesResolved') &&
            !d.servicesResolved &&
            d.connected) {
          // Re-resolving (Service Changed): handles are about to change.
          _invalidateGatt(s);
        }
      }
      if (_scan != null && props.any(_advertisementProperties.contains)) {
        _maybeReport(d, props);
      }
    });
    _maybeReport(d);
  }

  void _onDeviceRemoved(BlueZDevice d) {
    final id = d.address;
    _deviceSubs.remove(id)?.cancel();
    _onDisconnected(id);
    // RemoveDevice drops the pairing; the object keeps its last values.
    if (d.paired) _emitBond(id, 'none');
  }

  BlueZDevice? _device(String id) {
    final wanted = id.toUpperCase();
    for (final d in _client?.devices ?? const <BlueZDevice>[]) {
      if (d.address.toUpperCase() == wanted) return d;
    }
    return null;
  }

  /// Session of a device connected through this plugin (sessions are
  /// dropped on disconnect).
  _Session _session(String id) {
    final s = _sessions[id.toUpperCase()];
    if (s == null) {
      throw BleException('not_connected', 'Device $id is not connected');
    }
    return s;
  }

  _Session? _sessionUnder(String path) {
    for (final s in _sessions.values) {
      if (path.startsWith(s.path) &&
          (path.length == s.path.length || path[s.path.length] == '/')) {
        return s;
      }
    }
    return null;
  }

  void _emitName(_Session s) {
    final name = _displayName(s.device);
    if (name == null || name == s.name) return;
    s.name = name;
    _emit({'type': 'name', 'id': s.address, 'name': name});
  }

  void _emitBond(String id, String state) {
    if (_bondStates[id] == state) return;
    _bondStates[id] = state;
    _log(3, '$id bond state $state');
    _emit({'type': 'bondState', 'id': id, 'state': state});
  }

  void _onDisconnected(String id) {
    final s = _sessions.remove(id);
    if (s == null) return;
    _closeSession(s);
    final reason = _disconnectReasons.remove(s.path);
    final event = <String, dynamic>{
      'type': 'connectionState',
      'id': id,
      'connected': false,
    };
    if (reason != null && !s.disconnectRequested) {
      final r = disconnectReason(reason.$1, reason.$2);
      if (r.code != null) event['reason'] = r.code;
      event['reasonText'] = r.text;
    }
    _log(3, '$id disconnected');
    _emit(event);
    _saveOwned();
  }

  void _closeSession(_Session s) {
    _notifying.removeWhere((_, n) => identical(n.session, s));
    s.close();
  }

  /// Adapter off or gone: ends every session, pending connect and pending
  /// bond with `not_connected`.
  void _dropConnections(String reason) {
    final pending = [..._pendingConnects.values, ..._pendingBonds];
    _pendingConnects.clear();
    _pendingBonds.clear();
    for (final c in pending) {
      if (!c.isCompleted) {
        c.completeError(BleException('not_connected', reason));
      }
    }
    for (final id in _sessions.keys.toList()) {
      _onDisconnected(id);
    }
  }

  // ---- D-Bus signals --------------------------------------------------------

  /// Every signal BlueZ sends (scan updates included): keep the cheap
  /// rejections first.
  void _onSignal(DBusSignal sig) {
    switch (sig.name) {
      case 'PropertiesChanged':
        final v = sig.values;
        if (v.length != 3 ||
            v[0] is! DBusString ||
            v[0].asString() != gattCharacteristicInterface) {
          return;
        }
        final path = sig.path.value;
        final n = _notifying[path];
        final s = n?.session ?? _sessionUnder(path);
        if (s == null) return;
        final changed = v[1].asStringVariantDict();
        final value = changed['Value'];
        if (n != null && value is DBusArray) {
          final bytes = Uint8List.fromList(value.asByteArray().toList());
          for (final out in n.echo.onValue(bytes)) {
            _emit({...n.event, 'value': out});
          }
        }
        final mtu = changed['MTU'];
        if (mtu is DBusUint16) _updateMtu(s, mtu.value);
      case 'InterfacesAdded' || 'InterfacesRemoved':
        if (sig.interface != 'org.freedesktop.DBus.ObjectManager' ||
            sig.values.isEmpty ||
            sig.values[0] is! DBusObjectPath) {
          return;
        }
        final path = sig.values[0].asObjectPath().value;
        final s = _sessionUnder(path);
        // Only the device's GATT database (`<device>/serviceXXXX/...`).
        if (s == null || !path.startsWith('/service', s.path.length)) return;
        if (sig.name == 'InterfacesRemoved') _notifying.remove(path);
        _invalidateGatt(s);
      case 'Disconnected':
        final v = sig.values;
        if (sig.interface != 'org.bluez.Device1' ||
            v.length != 2 ||
            v[0] is! DBusString ||
            v[1] is! DBusString) {
          return;
        }
        final path = sig.path.value;
        if (_sessions.values.any((s) => s.path == path)) {
          _disconnectReasons[path] = (v[0].asString(), v[1].asString());
        }
    }
  }

  /// The device's GATT database changed: cached attributes are invalid and
  /// the app is told once per burst of changes (`servicesReset`). A burst
  /// caused by a disconnection is not reported.
  void _invalidateGatt(_Session s) {
    s.gattGeneration++;
    if (s.gatt == null) return;
    s.gatt = null;
    s.resetTimer ??= Timer(const Duration(milliseconds: 100), () {
      s.resetTimer = null;
      if (identical(_sessions[s.address], s) && s.device.connected) {
        _log(3, '${s.address} services changed');
        _emit({'type': 'servicesReset', 'id': s.address});
      }
    });
  }

  // ---- connection -----------------------------------------------------------

  Future<void> _connect(String id) async {
    _poweredAdapter();
    final d = _device(id);
    if (d == null) {
      throw BleException('not_found', 'Unknown device $id; scan for it first');
    }
    final address = d.address;
    if (d.connected && _sessions.containsKey(address)) return;
    final abort = Completer<void>();
    _pendingConnects[address] = abort;
    _disconnectReasons.remove(d.path.value);
    final call = _connectDevice(d);
    try {
      await Future.any([call, abort.future]);
    } catch (_) {
      if (abort.isCompleted) {
        // Cancelled: should BlueZ still finish connecting, drop the link.
        call.then((_) {
          if (!_sessions.containsKey(address) &&
              !_pendingConnects.containsKey(address)) {
            d.disconnect().ignore();
          }
        }, onError: (_) {}).ignore();
      }
      rethrow;
    } finally {
      if (identical(_pendingConnects[address], abort)) {
        _pendingConnects.remove(address);
      }
    }
    _sessions.putIfAbsent(address, () => _Session(d, _displayName(d)));
    _saveOwned();
    _log(3, '$address connected');
    _emit({'type': 'connectionState', 'id': address, 'connected': true});
  }

  static Future<void> _connectDevice(BlueZDevice d) async {
    try {
      await d.connect();
    } on BlueZAlreadyConnectedException {
      // Fine: same outcome.
    }
  }

  Future<void> _disconnect(String id) async {
    final d = _device(id);
    if (d == null) return;
    final address = d.address;
    final pending = _pendingConnects.remove(address);
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
          const BleException('connect_failed', 'Connection cancelled'));
    }
    final s = _sessions[address];
    // Leave connections we don't own (other apps, the desktop) alone.
    if (pending == null && s == null) return;
    s?.disconnectRequested = true;
    if (pending == null && !d.connected) {
      _onDisconnected(address);
      return;
    }
    // Disconnect also cancels an outstanding Connect call.
    try {
      await d.disconnect();
    } on BlueZNotConnectedException {
      // Already gone.
    }
    if (d.connected) {
      try {
        await d.propertiesChanged
            .firstWhere((_) => !d.connected)
            .timeout(const Duration(seconds: 5), onTimeout: () => const []);
      } catch (_) {
        // The device object went away (package:bluez throws a String).
      }
    }
    _onDisconnected(address);
  }

  // ---- hot restart ----------------------------------------------------------

  /// Addresses of our sessions, kept outside the isolate: a Flutter hot
  /// restart replaces this backend inside the same process while BlueZ
  /// keeps the connections, and the new backend must adopt them (and only
  /// them) in `getConnectedDevices`. Keyed by pid and process start time so
  /// a recycled pid never sees another process' file.
  ///
  /// Debug builds only (no hot restart otherwise), and only in the private
  /// `XDG_RUNTIME_DIR` (a shared /tmp would allow symlink attacks).
  late final File? _ownedFile = () {
    if (!kDebugMode) return null;
    try {
      final dir = Platform.environment['XDG_RUNTIME_DIR'];
      if (dir == null || dir.isEmpty) return null;
      final key = procStartTime(File('/proc/self/stat').readAsStringSync());
      if (key == null) return null;
      return File('$dir/open_blue_plus-$pid-$key');
    } catch (_) {
      return null;
    }
  }();

  void _saveOwned() {
    final f = _ownedFile;
    if (f == null) return;
    try {
      if (_sessions.isEmpty) {
        if (f.existsSync()) f.deleteSync();
      } else {
        f.writeAsStringSync(_sessions.keys.join('\n'));
      }
    } catch (e) {
      _log(2, 'cannot record connections in ${f.path}: $e');
    }
  }

  void _adoptSessions() {
    final f = _ownedFile;
    List<String> ids;
    try {
      if (f == null || !f.existsSync()) return;
      ids = f.readAsLinesSync();
    } catch (_) {
      return;
    }
    for (final id in ids) {
      final d = _device(id);
      if (d == null || !d.connected || !_onAdapter(d)) continue;
      _sessions.putIfAbsent(d.address, () => _Session(d, _displayName(d)));
      _log(3, '${d.address} adopted after restart');
    }
    _saveOwned();
  }

  // ---- bonding --------------------------------------------------------------

  Future<void> _createBond(Map<String, dynamic> a) async {
    _poweredAdapter();
    final id = a['id'] as String;
    final d = _device(id);
    if (d == null) {
      throw BleException('not_found', 'Unknown device $id; scan for it first');
    }
    if (d.paired) return;
    final address = d.address;
    final running = _bonding[address];
    if (running != null) return running;
    final pin = a['pin'] as String?;
    final timeout = Duration(milliseconds: (a['timeoutMs'] as int?) ?? 60000);
    final bond = _pair(d, pin, timeout);
    _bonding[address] = bond;
    try {
      await bond;
    } finally {
      if (identical(_bonding[address], bond)) _bonding.remove(address);
    }
  }

  Future<void> _pair(BlueZDevice d, String? pin, Duration timeout) async {
    final address = d.address;
    final abort = Completer<void>();
    abort.future.ignore();
    _pendingBonds.add(abort);
    _emitBond(address, 'bonding');
    var bonded = false;
    try {
      if (pin != null && pin.isNotEmpty) {
        await _withAgent(d.path.value, pin, () => _runPair(d, timeout, abort));
      } else {
        // No PIN: whatever agent the desktop registered handles prompts.
        await _runPair(d, timeout, abort);
      }
      bonded = true;
    } on BleException {
      rethrow;
    } catch (e) {
      throw bleExceptionForError(e, bondErrorCode) ??
          BleException('bond_failed', '$e');
    } finally {
      _pendingBonds.remove(abort);
      _emitBond(address, bonded || d.paired ? 'bonded' : 'none');
    }
  }

  Future<void> _runPair(
      BlueZDevice d, Duration timeout, Completer<void> abort) async {
    final call = d.pair();
    try {
      await Future.any([call, abort.future]).timeout(timeout);
    } on DBusMethodResponseException catch (e) {
      if (e.errorName == 'org.bluez.Error.AlreadyExists') return;
      rethrow;
    } catch (e) {
      // Timed out or aborted: stop BlueZ from carrying on.
      call.ignore();
      d.cancelPairing().ignore();
      if (e is TimeoutException) {
        throw BleException('timeout', 'Pairing did not complete in $timeout');
      }
      rethrow;
    }
  }

  /// Runs [body] with our agent registered, answering the prompts of the
  /// device at [devicePath] with [pin]. The agent is registered only while
  /// some pairing with a PIN is in flight.
  Future<void> _withAgent(
      String devicePath, String pin, Future<void> Function() body) async {
    _agentPins[devicePath] = pin;
    try {
      await _agentQueue.run(_registerAgent);
      await body();
    } finally {
      _agentPins.remove(devicePath);
      await _agentQueue.run(_unregisterAgentIfIdle);
    }
  }

  Future<void> _agentManagerCall(String method, List<DBusValue> values) =>
      _bus!.callMethod(
        destination: _bluez,
        path: DBusObjectPath('/org/bluez'),
        interface: 'org.bluez.AgentManager1',
        name: method,
        values: values,
        replySignature: DBusSignature(''),
      );

  /// Exports the agent object and registers it with BlueZ. BlueZ then
  /// routes the prompts of every `Pair()` this connection makes to it.
  Future<void> _registerAgent() async {
    final bus = _bus;
    if (_agent != null || bus == null) return;
    // Only bluetoothd may drive the agent: other peers must not learn PINs.
    final owner = await bus.getNameOwner(_bluez);
    final agent = _PinAgent(_agentPath, owner, (path) => _agentPins[path]);
    await bus.registerObject(agent);
    try {
      await _agentManagerCall(
          'RegisterAgent', [_agentPath, const DBusString('KeyboardDisplay')]);
    } on DBusMethodResponseException catch (e) {
      // AlreadyExists: still registered after a failed UnregisterAgent.
      if (e.errorName != 'org.bluez.Error.AlreadyExists') {
        await _unexport(bus, agent);
        rethrow;
      }
    }
    _agent = agent;
  }

  /// Unregisters and unexports the agent once no pairing with a PIN is left.
  Future<void> _unregisterAgentIfIdle() async {
    final agent = _agent;
    final bus = _bus;
    if (agent == null || _agentPins.isNotEmpty || bus == null) return;
    _agent = null;
    try {
      await _agentManagerCall('UnregisterAgent', [_agentPath]);
    } catch (e) {
      // DoesNotExist: BlueZ already dropped it (bluetoothd restart).
      if (e is! DBusMethodResponseException ||
          e.errorName != 'org.bluez.Error.DoesNotExist') {
        _log(2, 'cannot unregister the pairing agent: $e');
      }
    }
    await _unexport(bus, agent);
  }

  static Future<void> _unexport(DBusClient bus, DBusObject o) async {
    try {
      await bus.unregisterObject(o);
    } catch (_) {
      // Bus already closed.
    }
  }

  Future<void> _removeBond(String id) async {
    final d = _device(id);
    if (d == null || !d.paired) return;
    final adapter = _adapter;
    if (_client == null || adapter == null) {
      throw const BleException('unavailable', 'No Bluetooth adapter');
    }
    try {
      // The device object goes away; a new scan brings it back.
      await adapter.removeDevice(d);
    } on BlueZDoesNotExistException {
      // Already removed.
    }
    _emitBond(d.address, 'none');
  }

  // ---- GATT -----------------------------------------------------------------

  Future<DBusMethodSuccessResponse> _call(
    String path,
    String interface,
    String method, [
    List<DBusValue> values = const [],
    String reply = '',
  ]) =>
      _bus!.callMethod(
        destination: _bluez,
        path: DBusObjectPath(path),
        interface: interface,
        name: method,
        values: values,
        replySignature: DBusSignature(reply),
      );

  /// Fresh database, sharing a load already in flight.
  Future<List<GattServiceInfo>> _discover(_Session s) {
    final loading = s.loading;
    if (loading != null) return loading;
    final load = _loadGatt(s);
    s.loading = load;
    return load.whenComplete(() {
      if (identical(s.loading, load)) s.loading = null;
    });
  }

  /// Cached database, loaded on first use (rule 12: lazy resolution).
  Future<List<GattServiceInfo>> _gatt(_Session s) async =>
      s.gatt ?? await _discover(s);

  Future<List<GattServiceInfo>> _loadGatt(_Session s) async {
    final d = s.device;
    if (!d.servicesResolved) {
      await d.propertiesChanged
          .firstWhere((_) => d.servicesResolved || !d.connected)
          .timeout(const Duration(seconds: 15), onTimeout: () {
        throw const BleException(
            'timeout', 'BlueZ did not resolve services in time');
      });
    }
    if (!d.connected) {
      throw BleException('not_connected', 'Device ${s.address} disconnected');
    }
    final prefix = '${s.path}/';
    for (var attempt = 0;; attempt++) {
      final generation = s.gattGeneration;
      final managed = await _objectManager!.getManagedObjects();
      final tree = buildGattTree(gattObjectsFromDBus(managed, prefix));
      // Changed while reading: read again rather than cache a mix.
      if (generation != s.gattGeneration && attempt < 2) continue;
      s.gatt = tree;
      final mtu =
          knownMtu(tree.expand((svc) => svc.characteristics).map((c) => c.mtu));
      if (mtu != null) _updateMtu(s, mtu);
      return tree;
    }
  }

  Future<GattCharacteristicInfo> _characteristic(
      _Session s, Map<String, dynamic> a) async {
    final service = a['service'] as String;
    final characteristic = a['characteristic'] as String;
    final c = findCharacteristic(
      await _gatt(s),
      service,
      (a['serviceIndex'] as int?) ?? 0,
      characteristic,
      (a['characteristicIndex'] as int?) ?? 0,
    );
    if (c == null) {
      throw BleException(
          'not_found', 'Characteristic $characteristic not found in $service');
    }
    return c;
  }

  Future<GattDescriptorInfo> _descriptor(
      _Session s, Map<String, dynamic> a) async {
    final descriptor = fullUuid(a['descriptor'] as String);
    for (final x in (await _characteristic(s, a)).descriptors) {
      if (x.uuid == descriptor) return x;
    }
    throw BleException('not_found', 'Descriptor $descriptor not found');
  }

  static final _noOptions = DBusDict.stringVariant(const {});

  Future<Uint8List> _readValue(String path, String interface) async {
    final r = await _call(path, interface, 'ReadValue', [_noOptions], 'ay');
    return Uint8List.fromList(r.returnValues[0].asByteArray().toList());
  }

  Future<Uint8List> _read(_Session s, Map<String, dynamic> a) async {
    final c = await _characteristic(s, a);
    final event = c.valueEvent(s.address);
    // With notifications on, the read also shows up as a `Value` change.
    final echo = _notifying[c.path]?.echo;
    echo?.beginRead();
    Uint8List? value;
    try {
      value = await _readValue(c.path, gattCharacteristicInterface);
    } finally {
      for (final v in echo?.endRead(value) ?? const <Uint8List>[]) {
        _emit({...event, 'value': v});
      }
    }
    _emit({...event, 'value': value});
    return value;
  }

  Future<void> _write(_Session s, Map<String, dynamic> a) async {
    final c = await _characteristic(s, a);
    final type = a['withoutResponse'] == true ? 'command' : 'request';
    await _call(c.path, gattCharacteristicInterface, 'WriteValue', [
      DBusArray.byte(a['value'] as List<int>),
      DBusDict.stringVariant({'type': DBusString(type)}),
    ]);
  }

  /// StartNotify picks notifications or indications by itself
  /// (`forceIndications` cannot be honoured); values then arrive as
  /// `Value` property changes, see [_onSignal].
  Future<void> _setNotify(
      _Session s, Map<String, dynamic> a, bool enable) async {
    final c = await _characteristic(s, a);
    final path = c.path;
    if (enable) {
      // A repeated enable shares the outcome of the first StartNotify
      // instead of reporting success before it is known.
      final existing = _notifying[path];
      if (existing != null) return existing.started;
      final n = _Notification(s, c.valueEvent(s.address));
      _notifying[path] = n;
      Future<void> start() async {
        try {
          await _call(path, gattCharacteristicInterface, 'StartNotify');
        } catch (_) {
          if (identical(_notifying[path], n)) _notifying.remove(path);
          rethrow;
        }
      }

      return n.started = start();
    }
    final n = _notifying.remove(path);
    // Nothing of ours to stop (rule 10: also for characteristics without
    // notify).
    if (n == null) return;
    try {
      await n.started;
    } catch (_) {
      return;
    }
    try {
      await _call(path, gattCharacteristicInterface, 'StopNotify');
    } on DBusMethodResponseException {
      // Session already released.
    }
  }

  Future<Uint8List> _readDescriptor(_Session s, Map<String, dynamic> a) async =>
      _readValue((await _descriptor(s, a)).path, gattDescriptorInterface);

  /// BlueZ owns the CCCD and rejects direct writes, so map them to
  /// StartNotify/StopNotify like the other platforms do implicitly.
  Future<void> _writeDescriptor(_Session s, Map<String, dynamic> a) async {
    final value = a['value'] as List<int>;
    if (sameUuid(a['descriptor'] as String, _cccd)) {
      return _setNotify(s, a, cccdEnables(value));
    }
    final x = await _descriptor(s, a);
    await _call(x.path, gattDescriptorInterface, 'WriteValue',
        [DBusArray.byte(value), _noOptions]);
  }

  /// BlueZ negotiates the MTU on its own; this reads its current value.
  Future<int> _requestMtu(_Session s) async {
    final chars = (await _gatt(s)).expand((svc) => svc.characteristics);
    if (chars.isNotEmpty) {
      try {
        final r = await _call(
            chars.first.path,
            'org.freedesktop.DBus.Properties',
            'Get',
            [
              const DBusString(gattCharacteristicInterface),
              const DBusString('MTU'),
            ],
            'v');
        final v = r.returnValues[0].asVariant();
        if (v is DBusUint16) _updateMtu(s, v.value);
      } on DBusMethodResponseException {
        // Older BlueZ without the MTU property.
      }
    }
    return s.mtu ?? _defaultMtu;
  }

  /// Emits `mtu` whenever a new value is learnt.
  void _updateMtu(_Session s, int mtu) {
    if (mtu <= 0 || mtu == s.mtu) return;
    s.mtu = mtu;
    _emit({'type': 'mtu', 'id': s.address, 'mtu': mtu});
  }
}

/// State of one connected device.
class _Session {
  _Session(this.device, this.name)
      : address = device.address,
        path = device.path.value;

  final BlueZDevice device;
  final String address;

  /// D-Bus object path of the device.
  final String path;

  /// Last name reported (for `name` events).
  String? name;

  /// Last MTU reported in an `mtu` event.
  int? mtu;

  /// GATT database as last discovered; null until discovery and after the
  /// database changes.
  List<GattServiceInfo>? gatt;
  Future<List<GattServiceInfo>>? loading;

  /// Bumped on every database change.
  int gattGeneration = 0;
  Timer? resetTimer;
  bool disconnectRequested = false;
  bool _closed = false;

  /// Operations in flight, failed by [close]. One entry per operation (not
  /// a listener on a shared future) so a long session doing many writes
  /// does not accumulate callbacks.
  final Set<Completer<Object?>> _inFlight = {};

  /// Fails [op] with `not_connected` if the device disconnects first.
  Future<T> guard<T>(Future<T> op) {
    if (_closed) {
      op.ignore();
      return Future.error(_notConnected());
    }
    final result = Completer<Object?>();
    _inFlight.add(result);
    op.then((v) {
      if (_inFlight.remove(result)) result.complete(v);
    }, onError: (Object e, StackTrace st) {
      if (_inFlight.remove(result)) result.completeError(e, st);
    });
    return result.future.then((v) => v as T);
  }

  BleException _notConnected() =>
      BleException('not_connected', 'Device $address disconnected');

  void close() {
    _closed = true;
    resetTimer?.cancel();
    resetTimer = null;
    final pending = [..._inFlight];
    _inFlight.clear();
    for (final c in pending) {
      c.completeError(_notConnected());
    }
  }
}

/// A notification session started with StartNotify.
class _Notification {
  _Notification(this.session, this.event);

  final _Session session;

  /// `value` event fields, built once.
  final Map<String, Object?> event;
  final ReadEchoFilter echo = ReadEchoFilter();

  /// Completes when StartNotify does.
  late Future<void> started;
}

/// `org.bluez.Agent1` answering pairing prompts with the PIN of the pairing
/// in flight for that device; anything else is rejected.
class _PinAgent extends DBusObject {
  _PinAgent(super.path, this._bluezOwner, this._pinFor);

  /// Unique bus name of bluetoothd.
  final String? _bluezOwner;
  final String? Function(String devicePath) _pinFor;

  static DBusMethodResponse _rejected() =>
      DBusMethodErrorResponse('org.bluez.Error.Rejected');

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != 'org.bluez.Agent1') {
      return DBusMethodErrorResponse.unknownInterface();
    }
    if (_bluezOwner == null || call.sender != _bluezOwner) return _rejected();
    final v = call.values;
    final pin = v.isNotEmpty && v[0] is DBusObjectPath
        ? _pinFor(v[0].asObjectPath().value)
        : null;
    switch (call.name) {
      case 'Release':
      case 'Cancel':
        return DBusMethodSuccessResponse();
      case 'RequestPinCode':
        return pin == null
            ? _rejected()
            : DBusMethodSuccessResponse([DBusString(pin)]);
      case 'RequestPasskey':
        final passkey = pin == null ? null : int.tryParse(pin);
        return passkey == null || passkey < 0 || passkey > 999999
            ? _rejected()
            : DBusMethodSuccessResponse([DBusUint32(passkey)]);
      case 'DisplayPinCode':
      case 'DisplayPasskey':
      case 'RequestConfirmation':
      case 'RequestAuthorization':
      case 'AuthorizeService':
        return pin == null ? _rejected() : DBusMethodSuccessResponse();
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }
}
