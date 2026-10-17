import 'dart:async';
import 'dart:typed_data';

import 'channel.dart';
import 'events.dart';
import 'exception.dart';
import 'gatt.dart';
import 'log.dart';
import 'manager.dart';
import 'streams.dart';
import 'types.dart';
import 'uuid.dart';

/// A remote BLE peripheral.
///
/// Instances are unique per [id]: [BleDevice.fromId] and scan results always
/// return the same object for the same peripheral.
class BleDevice {
  /// MAC address on Android, Linux and Windows; CoreBluetooth identifier
  /// (UUID) on iOS/macOS; `BluetoothDevice.id` on Web.
  final String id;

  String? _name;
  String? _advName;
  DeviceConnectionState _state = DeviceConnectionState.disconnected;
  int _mtu = 23;
  List<BleService> _services = const [];
  DisconnectReason? _disconnectReason;
  BondState? _bond;
  BondState? _prevBond;
  PhyUpdate? _phy;
  bool _autoConnect = false;
  int? _autoConnectMtu;

  /// Incremented by every [connect] attempt and every [disconnect], so a
  /// pending attempt knows it was superseded.
  int _attempt = 0;

  final _stateCtrl = StreamController<DeviceConnectionState>.broadcast();
  final _mtuCtrl = StreamController<int>.broadcast();
  final _servicesResetCtrl = StreamController<void>.broadcast();
  final _bondCtrl = StreamController<BondState>.broadcast();
  final _phyCtrl = StreamController<PhyUpdate>.broadcast();

  /// Per characteristic (`valueKey`): last value and its stream.
  /// One map lookup per notification instead of every listener filtering
  /// every event.
  final Map<String, _ValueSlot> _values = {};
  final Map<String, _ValueSlot> _descriptorValues = {};
  final Set<String> _notifying = {};

  BleDevice._(this.id, [this._name]);

  /// Returns the device with [id] (MAC address on Android, identifier on iOS).
  factory BleDevice.fromId(String id) => BleManager.instance.deviceFor(id);

  static BleEvents get _events => BleManager.instance.events;

  /// Name given by the platform (cached by the OS, may be stale), if known.
  String? get name => _name;

  /// Local name from the last advertisement seen while scanning, if any.
  String? get advName => _advName;

  /// Current connection state.
  DeviceConnectionState get state => _state;

  /// Whether [state] is [DeviceConnectionState.connected].
  bool get isConnected => _state == DeviceConnectionState.connected;

  /// Whether [state] is [DeviceConnectionState.disconnected].
  bool get isDisconnected => _state == DeviceConnectionState.disconnected;

  /// Emits the current state on listen, then every change.
  Stream<DeviceConnectionState> get connectionState =>
      currentThen(() => _state, _stateCtrl.stream);

  /// Why the device disconnected the last time, when the platform said so
  /// (Android, iOS, macOS, recent BlueZ). Null before the first disconnection
  /// or when the reason is unknown.
  DisconnectReason? get disconnectReason => _disconnectReason;

  /// Current ATT MTU (23 until negotiated).
  int get mtu => _mtu;

  /// Emits the current MTU on listen, then every change.
  Stream<int> get onMtu => currentThen(() => _mtu, _mtuCtrl.stream);

  /// Services found by the last [discoverServices] call. Emptied when the
  /// device disconnects or its services change.
  List<BleService> get services => _services;

  /// Emits when the peripheral changed its GATT database (broadcast stream,
  /// future events only). Previously
  /// discovered services are invalid: call [discoverServices] again.
  Stream<void> get onServicesReset => _servicesResetCtrl.stream;

  /// Whether the last [connect] used `autoConnect` and [disconnect] has not
  /// been called since.
  bool get isAutoConnectEnabled => _autoConnect;

  /// Connects to the device.
  ///
  /// Fails with a `timeout` [BleException] if the connection is not
  /// established within [timeout] (the attempt is then cancelled). [timeout]
  /// defaults to 15 seconds, or to no timeout with [autoConnect].
  ///
  /// With [autoConnect] (Android, Windows) the system keeps trying in the
  /// background, also after a later connection loss, until [disconnect] is
  /// called. The future completes on the first connection; you may also not
  /// await it and listen to [connectionState] instead.
  ///
  /// [mtu]: MTU requested right after connecting (Android starts at 23, which
  /// limits writes without response to 20 bytes). Other platforms negotiate it
  /// automatically and just report the value. `null` skips the request.
  /// A failed MTU request does not fail the connection. With [autoConnect]
  /// it is requested again after every automatic reconnection.
  ///
  /// Concurrent calls share the attempt in flight (and its arguments).
  Future<void> connect({
    Duration? timeout,
    bool autoConnect = false,
    int? mtu = 512,
  }) {
    final pending = _connecting;
    if (pending != null) return pending;
    if (isConnected) return Future.value();
    late final Future<void> attempt;
    attempt = _connect(
      timeout ?? (autoConnect ? null : const Duration(seconds: 15)),
      autoConnect,
      mtu,
    ).whenComplete(() {
      // disconnect() may have dropped this attempt and a new one started.
      if (identical(_connecting, attempt)) _connecting = null;
    });
    return _connecting = attempt;
  }

  Future<void>? _connecting;
  Future<List<BleService>>? _discovering;

  Future<void> _connect(Duration? timeout, bool autoConnect, int? mtu) async {
    final attempt = ++_attempt;
    _autoConnect = autoConnect;
    _autoConnectMtu = autoConnect ? mtu : null;
    _setState(DeviceConnectionState.connecting);
    try {
      final f = BleChannel.invoke<void>('connect', {
        'id': id,
        'autoConnect': autoConnect,
      });
      await (timeout == null ? f : f.timeout(timeout));
    } on TimeoutException {
      if (attempt != _attempt) throw _cancelled;
      await _cancelQuietly();
      throw BleException('timeout', 'connect did not complete in $timeout');
    } catch (_) {
      // A superseded attempt must not touch the state of the current one.
      if (attempt == _attempt) {
        _autoConnect = false;
        _autoConnectMtu = null;
        if (_state == DeviceConnectionState.connecting) {
          _setState(DeviceConnectionState.disconnected);
        }
      }
      rethrow;
    }
    // disconnect() was called while this attempt was pending.
    if (attempt != _attempt) throw _cancelled;
    _setState(DeviceConnectionState.connected);
    if (mtu != null) await _requestMtuQuietly(mtu);
  }

  static const _cancelled =
      BleException('connect_failed', 'cancelled by disconnect()');

  Future<void> _requestMtuQuietly(int mtu) async {
    try {
      await requestMtu(mtu);
    } catch (e) {
      // Keep the connection; the peripheral may simply refuse a larger MTU.
      BleLog.log(BleLogLevel.warning, () => '$id: MTU $mtu request failed: $e');
    }
  }

  Future<void> _cancelQuietly() async {
    try {
      await disconnect();
    } catch (_) {
      _setState(DeviceConnectionState.disconnected);
    }
  }

  /// Disconnects, or cancels a pending connection attempt, and turns
  /// `autoConnect` off.
  ///
  /// Always reaches the platform, even when the device is already
  /// disconnected, so it also stops a background `autoConnect` that is still
  /// trying to reconnect.
  Future<void> disconnect(
      {Duration timeout = const Duration(seconds: 10)}) async {
    _autoConnect = false;
    _autoConnectMtu = null;
    // Cancels a pending connect(); the next connect() starts a new attempt.
    _attempt++;
    _connecting = null;
    if (_state == DeviceConnectionState.disconnected) {
      await BleChannel.invokeWithTimeout<void>(
          'disconnect', {'id': id}, timeout);
      return;
    }
    _setState(DeviceConnectionState.disconnecting);
    try {
      await BleChannel.invokeWithTimeout<void>(
          'disconnect', {'id': id}, timeout);
    } finally {
      // A connect() issued meanwhile owns the state now.
      if (_state == DeviceConnectionState.disconnecting) {
        _linkLost(DisconnectReason(null, 'disconnected by the app'));
        _setState(DeviceConnectionState.disconnected);
      }
    }
  }

  /// Cancels [subscription] when the device disconnects: now if it is
  /// already disconnected, or at the next disconnection with [next] (useful
  /// to set up subscriptions before calling [connect]).
  ///
  /// The watch itself only ends at that disconnection, so call this once per
  /// subscription, not repeatedly.
  void cancelWhenDisconnected(StreamSubscription<Object?> subscription,
      {bool next = false}) {
    if (!next && isDisconnected) {
      subscription.cancel();
      return;
    }
    late final StreamSubscription<DeviceConnectionState> watch;
    watch = _stateCtrl.stream.listen((s) {
      if (s == DeviceConnectionState.disconnected) {
        watch.cancel();
        subscription.cancel();
      }
    });
  }

  /// Discovers all services, characteristics and descriptors.
  Future<List<BleService>> discoverServices({
    Duration timeout = const Duration(seconds: 20),
  }) {
    // Concurrent callers share the discovery already in flight.
    return _discovering ??=
        _discover(timeout).whenComplete(() => _discovering = null);
  }

  Future<List<BleService>> _discover(Duration timeout) async {
    final raw = await BleChannel.invokeWithTimeout<List<Object?>>(
        'discoverServices', {'id': id}, timeout);
    _services = servicesFromMaps(this, raw ?? const []);
    return _services;
  }

  /// Returns the first discovered service with [uuid], or null.
  BleService? service(BleUuid uuid) {
    for (final s in _services) {
      if (s.uuid == uuid) return s;
    }
    return null;
  }

  /// Android: clears the system's cache of this device's services (useful
  /// after a firmware update that changed them). Windows: the next discovery
  /// bypasses the cache. No-op elsewhere. Call [discoverServices] afterwards.
  Future<void> clearGattCache() async {
    await BleChannel.invoke<void>('clearGattCache', {'id': id});
    _servicesInvalid();
  }

  /// Requests a larger MTU. On iOS the MTU is negotiated by the system and
  /// this simply returns the current value. Returns the resulting MTU.
  Future<int> requestMtu(int mtu,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final v = await BleChannel.invokeWithTimeout<int>(
        'requestMtu', {'id': id, 'mtu': mtu}, timeout);
    _setMtu(v ?? _mtu);
    return _mtu;
  }

  /// Reads the signal strength of the active connection.
  Future<int> readRssi({Duration timeout = const Duration(seconds: 10)}) async {
    final v = await BleChannel.invokeWithTimeout<int>(
        'readRssi', {'id': id}, timeout);
    return v ?? 0;
  }

  /// Android only: requests a connection interval profile. No-op elsewhere.
  Future<void> requestConnectionPriority(ConnectionPriority priority) {
    return BleChannel.invoke<void>(
        'requestConnectionPriority', {'id': id, 'priority': priority.code});
  }

  // ---- PHY --------------------------------------------------------------------

  /// PHYs reported by the last `phy` update (Android), if any.
  PhyUpdate? get phyNow => _phy;

  /// PHY updates of this connection (Android).
  Stream<PhyUpdate> get onPhyChanged => _phyCtrl.stream;

  /// Android 8+: asks for the preferred PHYs (e.g. `{BlePhy.le2m}` for speed,
  /// `{BlePhy.leCoded}` for range; check `BleManager.getPhySupport()` first).
  /// The PHYs actually chosen arrive on [onPhyChanged]. No-op elsewhere.
  Future<void> setPreferredPhy({
    required Set<BlePhy> tx,
    required Set<BlePhy> rx,
    PhyCodedOption codedOption = PhyCodedOption.none,
  }) {
    if (tx.isEmpty || rx.isEmpty) {
      throw ArgumentError('tx and rx need at least one PHY');
    }
    return BleChannel.invoke<void>('setPreferredPhy', {
      'id': id,
      'txPhy': BlePhy.maskOf(tx),
      'rxPhy': BlePhy.maskOf(rx),
      'codedOption': codedOption.code,
    });
  }

  // ---- bonding ----------------------------------------------------------------

  /// Last known pairing state (from [bondState], [createBond], [removeBond]
  /// or system events), or null if never queried.
  BondState? get bondStateNow => _bond;

  /// State before the last change of [bondStateNow].
  BondState? get prevBondState => _prevBond;

  /// Emits the last known pairing state on listen (if known), then every
  /// change reported by the platform (Android, Linux, Windows).
  Stream<BondState> get onBondState =>
      currentThen(() => _bond, _bondCtrl.stream);

  /// Pairing state (Android, Linux, Windows); [BondState.unknown] elsewhere.
  Future<BondState> bondState() async {
    final s = BondState.parse(
        await BleChannel.invoke<String>('getBondState', {'id': id}));
    _setBond(s);
    return s;
  }

  /// Pairs with the device (Android, Linux, Windows). Completes once bonded
  /// (at once if it already is). [pin]: PIN or passkey given to the system
  /// automatically if the peripheral asks for one; otherwise the system
  /// shows its own pairing dialog when needed.
  ///
  /// Fails with `bond_failed` if pairing is rejected or fails, and with
  /// `not_supported` on iOS, macOS and Web, where the OS pairs by itself
  /// when an encrypted characteristic is accessed.
  Future<void> createBond({
    String? pin,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (pin != null && pin.isEmpty) {
      throw ArgumentError.value(pin, 'pin', 'must not be empty');
    }
    await BleChannel.invokeWithTimeout<void>(
        'createBond', {'id': id, 'pin': pin}, timeout);
    _setBond(BondState.bonded);
  }

  /// Removes the pairing (Android, Linux, Windows). Fails with
  /// `not_supported` where the platform does not allow it.
  Future<void> removeBond(
      {Duration timeout = const Duration(seconds: 30)}) async {
    await BleChannel.invokeWithTimeout<void>('removeBond', {'id': id}, timeout);
    _setBond(BondState.none);
  }

  void _linkLost(DisconnectReason? reason) {
    // During an attempt the reason belongs to a failed try (PROTOCOL.md rule
    // 15); once disconnected, a duplicate event without a reason must not
    // erase the one already known.
    if (_state != DeviceConnectionState.connecting &&
        (reason != null || _state != DeviceConnectionState.disconnected)) {
      _disconnectReason = reason;
    }
    _services = const [];
    _notifying.clear();
    _setMtu(23);
  }

  void _servicesInvalid() {
    _services = const [];
    _notifying.clear();
  }

  void _setBond(BondState s) {
    if (s == _bond) return;
    _prevBond = _bond;
    _bond = s;
    _bondCtrl.add(s);
    _events.bond(BleBondEvent(this, s, _prevBond));
  }

  void _setState(DeviceConnectionState s) {
    if (s == _state) return;
    // A failed attempt has no disconnection reason of its own.
    final linked = _state != DeviceConnectionState.connecting;
    _state = s;
    _stateCtrl.add(s);
    _events.connection(BleConnectionEvent(
        this,
        s,
        s == DeviceConnectionState.disconnected && linked
            ? _disconnectReason
            : null));
  }

  void _setMtu(int m) {
    if (m == _mtu) return;
    _mtu = m;
    _mtuCtrl.add(m);
    _events.mtu(BleMtuEvent(this, m));
  }

  @override
  bool operator ==(Object other) => other is BleDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'BleDevice($id${_name == null ? '' : ', $_name'})';
}

/// Creates the unique instance for [id] (not exported; `BleManager` keeps
/// one per id).
BleDevice newBleDevice(String id, [String? name]) => BleDevice._(id, name);

/// Key of a characteristic in the value maps (canonical UUIDs).
String characteristicKey(String service, int serviceIndex,
        String characteristic, int characteristicIndex) =>
    '$service#$serviceIndex|$characteristic#$characteristicIndex';

/// State shared with `BleManager` and the GATT classes (not exported).
extension BleDeviceInternal on BleDevice {
  /// Last value seen for [c].
  Uint8List? lastValueOf(BleCharacteristic c) => _values[c.valueKey]?.last;

  /// Values seen for [c].
  Stream<Uint8List> valuesOf(BleCharacteristic c) =>
      _slot(_values, c.valueKey).ctrl.stream;

  /// Whether notifications were enabled on [c] through the plugin.
  bool isNotifyingChar(BleCharacteristic c) => _notifying.contains(c.valueKey);

  /// Last value read or written for [d].
  Uint8List? lastDescriptorValueOf(BleDescriptor d) =>
      _descriptorValues[d.valueKey]?.last;

  /// Values read or written for [d].
  Stream<Uint8List> descriptorValuesOf(BleDescriptor d) =>
      _slot(_descriptorValues, d.valueKey).ctrl.stream;

  void updateName(String? name) {
    if (name != null && name.isNotEmpty) _name = name;
  }

  void updateAdvName(String? name) {
    if (name != null && name.isNotEmpty) _advName = name;
  }

  void handleNameEvent(String? name) {
    if (name == null || name.isEmpty || name == _name) return;
    _name = name;
    BleDevice._events.name(BleNameEvent(this, name));
  }

  void handleConnectionEvent(bool connected, [DisconnectReason? reason]) {
    if (connected) {
      // While disconnect() runs, a `connected: true` is a stale leftover.
      if (_state == DeviceConnectionState.connected ||
          _state == DeviceConnectionState.disconnecting) {
        return;
      }
      final reconnection = _autoConnect && _connecting == null;
      _setState(DeviceConnectionState.connected);
      final mtu = _autoConnectMtu;
      if (reconnection && mtu != null) _requestMtuQuietly(mtu);
    } else {
      _linkLost(reason ??
          (_state == DeviceConnectionState.disconnecting
              ? DisconnectReason(null, 'disconnected by the app')
              : null));
      // A pending connect() decides the outcome itself (it fails, or the
      // platform reports `connected`); a `connected: false` arriving now is
      // stale (left over from a previous link) and must not hide the attempt.
      if (_state == DeviceConnectionState.connecting) return;
      _setState(DeviceConnectionState.disconnected);
    }
  }

  void handleMtuEvent(int mtu) => _setMtu(mtu);

  void handleValueEvent(String service, int serviceIndex, String characteristic,
      int characteristicIndex, Uint8List value) {
    // Backends send canonical UUIDs (PROTOCOL.md), so the raw key normally
    // hits; only normalise on a miss.
    var key = characteristicKey(
        service, serviceIndex, characteristic, characteristicIndex);
    var slot = _values[key];
    if (slot == null) {
      key = characteristicKey(BleUuid(service).value, serviceIndex,
          BleUuid(characteristic).value, characteristicIndex);
      slot = _slot(_values, key);
    }
    slot.last = value;
    if (slot.ctrl.hasListener) slot.ctrl.add(value);
    BleDevice._events.value(() => BleValueEvent(
          this,
          BleUuid(service),
          serviceIndex,
          BleUuid(characteristic),
          characteristicIndex,
          value,
          _findCharacteristic(key),
        ));
  }

  BleCharacteristic? _findCharacteristic(String key) {
    for (final s in _services) {
      for (final c in s.characteristics) {
        if (c.valueKey == key) return c;
      }
    }
    return null;
  }

  /// Records the result of a read as [c]'s last value, so it is visible as
  /// soon as `read()` completes (the matching `value` event may arrive later).
  void handleReadResult(BleCharacteristic c, Uint8List value) {
    _slot(_values, c.valueKey).last = value;
  }

  void handleWritten(BleCharacteristic c, Uint8List value) =>
      BleDevice._events.write(BleWriteEvent(c, value));

  void handleNotifying(BleCharacteristic c, bool enabled) {
    if (enabled) {
      _notifying.add(c.valueKey);
    } else {
      _notifying.remove(c.valueKey);
    }
  }

  void handleDescriptorValue(BleDescriptor d, Uint8List value) {
    final slot = _slot(_descriptorValues, d.valueKey);
    slot.last = value;
    if (slot.ctrl.hasListener) slot.ctrl.add(value);
    BleDevice._events.descriptor(BleDescriptorEvent(d, value));
  }

  void handleServicesReset() {
    _servicesInvalid();
    if (_servicesResetCtrl.hasListener) _servicesResetCtrl.add(null);
    BleDevice._events.servicesReset(BleServicesResetEvent(this));
  }

  void handleBondEvent(String? state) => _setBond(BondState.parse(state));

  void handlePhyEvent(int? tx, int? rx) {
    final p = PhyUpdate(BlePhy.fromEvent(tx), BlePhy.fromEvent(rx));
    _phy = p;
    if (_phyCtrl.hasListener) _phyCtrl.add(p);
    BleDevice._events.phy(BlePhyEvent(this, p));
  }
}

_ValueSlot _slot(Map<String, _ValueSlot> map, String key) =>
    map.putIfAbsent(key, _ValueSlot.new);

class _ValueSlot {
  Uint8List? last;
  final ctrl = StreamController<Uint8List>.broadcast();
}
