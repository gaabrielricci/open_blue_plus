import 'dart:async';

import 'package:flutter/foundation.dart';

import 'channel.dart';
import 'device.dart';
import 'events.dart';
import 'exception.dart';
import 'log.dart';
import 'streams.dart';
import 'types.dart';
import 'uuid.dart';

/// Entry point of the plugin: adapter state, permissions and scanning.
///
/// ```dart
/// final ble = BleManager.instance;
/// await ble.requestPermissions();
/// await ble.startScan(timeout: const Duration(seconds: 10));
/// ble.scanResults.listen((results) { ... });
/// ```
class BleManager {
  BleManager._() {
    BleChannel.events.listen(_onEventSafe, onError: (Object e) {
      BleLog.log(BleLogLevel.error, () => 'event channel error: $e');
    });
    _attach();
  }

  /// The single instance.
  static final BleManager instance = BleManager._();

  /// Events of every device in one place.
  final BleEvents events = newBleEvents();

  /// Adopts what survived a Flutter hot restart (or was restored by the OS):
  /// resets the backend's log level, stops a scan the previous Dart session
  /// left running and marks devices still connected through the plugin as
  /// connected. None of these calls creates the platform manager or shows a
  /// prompt (PROTOCOL.md rule 17). The first message is sent synchronously,
  /// so it reaches the platform before any call made by the app.
  Future<void> _attach() async {
    try {
      await BleChannel.invoke<void>(
          'setLogLevel', {'level': BleLog.level.index});
    } catch (_) {}
    try {
      await BleChannel.invoke<void>('stopScan');
    } catch (_) {}
    try {
      await connectedDevices();
    } catch (_) {}
  }

  final Map<String, BleDevice> _devices = {};

  AdapterState _adapterState = AdapterState.unknown;
  int _adapterChanges = 0;
  final _adapterCtrl = StreamController<AdapterState>.broadcast();

  bool _scanning = false;
  final _scanningCtrl = StreamController<bool>.broadcast();
  final Map<String, ScanResult> _results = {};

  /// [_results] ordered by descending RSSI, kept sorted incrementally so a
  /// new advertisement costs O(n) instead of a full sort.
  final List<ScanResult> _sorted = [];
  final _resultsCtrl = StreamController<List<ScanResult>>.broadcast();
  final _resultCtrl = StreamController<ScanResult>.broadcast();
  Timer? _scanTimer;

  /// Returns the unique [BleDevice] for [id] (same as [BleDevice.fromId]),
  /// remembering [name] if given.
  BleDevice deviceFor(String id, [String? name]) {
    id = canonicalDeviceId(id);
    final d = _devices.putIfAbsent(id, () => newBleDevice(id, name));
    d.updateName(name);
    return d;
  }

  /// Device of an event: backends already send canonical ids, so try the
  /// map before normalising (hot path for notifications).
  BleDevice _eventDevice(Object? id) => _devices[id] ?? deviceFor(id as String);

  static final RegExp _macOrUuid = RegExp(
      r'^([0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}|[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})$');

  /// MAC addresses and Apple identifiers are case-insensitive: backends report
  /// them upper-case, so normalise user input to match. Web ids are opaque and
  /// kept as-is.
  static String canonicalDeviceId(String id) =>
      _macOrUuid.hasMatch(id) ? id.toUpperCase() : id;

  // ---- options and logs -----------------------------------------------------

  /// Current log level (default [BleLogLevel.none]).
  BleLogLevel get logLevel => BleLog.level;

  /// Sets how much the plugin logs, in Dart and in the platform backend.
  /// Lines are printed with `debugPrint` (unless [print] is false) and
  /// emitted on [logs].
  Future<void> setLogLevel(BleLogLevel level, {bool print = true}) async {
    BleLog.level = level;
    BleLog.printLogs = print;
    await BleChannel.invoke<void>('setLogLevel', {'level': level.index});
  }

  /// Log lines enabled by [setLogLevel].
  Stream<BleLogRecord> get logs => BleLog.records;

  /// iOS / macOS options. Must be called before any other Bluetooth call
  /// (ideally at the start of `main`), because they are fixed when the
  /// system Bluetooth manager is created. Returns whether they were applied:
  /// false on other platforms, or when called too late.
  ///
  /// * [showPowerAlert]: let iOS show its "turn on Bluetooth" alert (off by
  ///   default, also when [setOptions] is never called).
  /// * [restoreState] (iOS): opt into state restoration, so iOS can relaunch
  ///   the app in the background for its connected or pending devices.
  ///   Requires the `bluetooth-central` background mode; connections handed
  ///   back by iOS appear in [connectedDevices].
  /// * [restoreIdentifier]: identifier of the restored manager; keep it
  ///   stable across releases.
  Future<bool> setOptions({
    bool showPowerAlert = false,
    bool restoreState = false,
    String restoreIdentifier = 'open_blue_plus',
  }) async =>
      (await BleChannel.invoke<bool>('setOptions', {
        'showPowerAlert': showPowerAlert,
        'restoreState': restoreState,
        'restoreIdentifier': restoreIdentifier,
      })) ??
      false;

  // ---- adapter --------------------------------------------------------------

  /// Whether the device has Bluetooth LE hardware (or the browser has the
  /// Web Bluetooth API). Never shows a permission prompt.
  Future<bool> get isSupported async =>
      (await BleChannel.invoke<bool>('isSupported')) ?? false;

  /// Name of the local Bluetooth adapter (the device name on iOS/macOS),
  /// or an empty string when unknown.
  Future<String> get adapterName async =>
      (await BleChannel.invoke<String>('getAdapterName')) ?? '';

  /// PHYs supported by the local adapter (Android 8+; both false elsewhere).
  Future<PhySupport> getPhySupport() async {
    final m = await BleChannel.invoke<Map<Object?, Object?>>('getPhySupport');
    return PhySupport(le2m: m?['le2M'] == true, leCoded: m?['leCoded'] == true);
  }

  /// Last known adapter state.
  AdapterState get adapterStateNow => _adapterState;

  /// Emits the current adapter state on listen (queried from the platform),
  /// then every change.
  ///
  /// On iOS/macOS the first query creates the system Bluetooth manager,
  /// which shows the permission prompt.
  Stream<AdapterState> get adapterState => Stream<AdapterState>.multi((out) {
        // Subscribe before querying so a change during the query is not lost.
        // If the state changes meanwhile (including through the query
        // itself), that change is delivered by the subscription; otherwise
        // the queried value is emitted here.
        out.onCancel = _adapterCtrl.stream.listen(out.add).cancel;
        final changes = _adapterChanges;
        getAdapterState().then((s) {
          if (_adapterChanges == changes) out.add(s);
        }, onError: (Object e, StackTrace st) {
          if (_adapterChanges == changes) out.addError(e, st);
        });
      });

  /// Queries the adapter state (see [adapterState]).
  Future<AdapterState> getAdapterState() async {
    final s = await BleChannel.invoke<String>('getAdapterState');
    _setAdapter(AdapterState.parse(s));
    return _adapterState;
  }

  /// Asks for the runtime permissions needed to scan and connect.
  ///
  /// Android: BLUETOOTH_SCAN + BLUETOOTH_CONNECT (Android 12+) or location
  /// (Android 11 and lower). With [androidFineLocation], Android 12+ also
  /// asks for ACCESS_FINE_LOCATION (declare it in your manifest; needed only
  /// if you derive location from scans). iOS: triggers the system Bluetooth
  /// prompt. Returns whether everything was granted.
  Future<bool> requestPermissions({bool androidFineLocation = false}) async =>
      (await BleChannel.invoke<bool>('requestPermissions',
          {'androidFineLocation': androidFineLocation})) ??
      false;

  /// Turns Bluetooth on: system dialog on Android, directly on Linux and
  /// Windows. Returns whether the adapter was enabled. Always false on
  /// iOS, macOS and Web, and when there is no adapter.
  Future<bool> turnOn() async =>
      (await BleChannel.invoke<bool>('turnOn')) ?? false;

  /// Turns Bluetooth off (Android 12 and lower, Linux, Windows). Returns
  /// whether the adapter was disabled; false where apps may not do it.
  Future<bool> turnOff() async =>
      (await BleChannel.invoke<bool>('turnOff')) ?? false;

  /// Waits until the adapter is [AdapterState.on].
  Future<void> waitUntilOn(
      {Duration timeout = const Duration(seconds: 10)}) async {
    final done = Completer<void>();
    final sub = adapterState.listen((s) {
      if (s == AdapterState.on && !done.isCompleted) done.complete();
    }, onError: (Object e, StackTrace st) {
      if (!done.isCompleted) done.completeError(e, st);
    });
    try {
      await done.future.timeout(timeout,
          onTimeout: () =>
              throw const BleException('adapter_off', 'Bluetooth is not on'));
    } finally {
      // Future.timeout does not cancel the source; do it here so the
      // subscription does not outlive the call.
      await sub.cancel();
    }
  }

  // ---- scanning -------------------------------------------------------------

  /// Whether a scan is running.
  bool get isScanningNow => _scanning;

  /// Emits the current scanning flag on listen, then every change.
  Stream<bool> get isScanning =>
      currentThen(() => _scanning, _scanningCtrl.stream);

  /// All devices seen in the current (or last) scan, latest advertisement per
  /// device, sorted by signal strength. Emits the current list on listen.
  Stream<List<ScanResult>> get scanResults =>
      currentThen(_sortedResults, _resultsCtrl.stream);

  /// Like [scanResults], but emits an empty list on listen when no scan is
  /// running, so results of a finished scan are not shown again.
  Stream<List<ScanResult>> get onScanResults => currentThen(
      () => _scanning ? _sortedResults() : const <ScanResult>[],
      _resultsCtrl.stream);

  /// Every single advertisement as it arrives (one by one, including
  /// duplicates when scanning with `allowDuplicates`).
  Stream<ScanResult> get onScanResult => _resultCtrl.stream;

  /// Current value of [scanResults].
  List<ScanResult> get lastScanResults => _sortedResults();

  /// Starts scanning. Any running scan is restarted.
  ///
  /// Filters are combined with OR: a device matches if it advertises any of
  /// [withServices], has any of [withNames] (exact name), contains any of
  /// [withKeywords] in its name, has any of [withRemoteIds], or matches any
  /// of [withManufacturerData] / [withServiceData]. Without any of them every
  /// device matches. [withNamePrefix] is applied on top of that (AND).
  ///
  /// * [timeout]: stops the scan automatically.
  /// * [allowDuplicates]: report every advertisement (keeps RSSI and
  ///   [ScanResult.timestamp] up to date, costs more power).
  /// * [continuousDivisor]: with [allowDuplicates], report only the first
  ///   and then every Nth advertisement of each device (reduces load).
  /// * [removeIfGone]: with [allowDuplicates], drop devices from
  ///   [scanResults] once no advertisement arrived for that long.
  /// * [androidScanMode]: Android power/latency trade-off.
  /// * [androidLegacy]: Android 8+: `true` scans legacy advertisements on the
  ///   1M PHY only; `false` also receives extended advertising (all PHYs).
  /// * [androidCheckLocationServices]: Android 11 and lower: fail with
  ///   `location_services_off` when the location toggle is off (scans
  ///   silently find nothing otherwise).
  /// * [webOptionalServices]: on Web, services you will access after
  ///   connecting that are not in [withServices] (the browser blocks every
  ///   other service).
  ///
  /// On Web the browser's device chooser opens instead; it must be called
  /// from a user gesture and reports at most one device.
  ///
  /// Fails with a `gatt_error` [BleException] (status = platform code) if
  /// the platform reports a scan failure before the call returns; a failure
  /// reported later only turns [isScanning] false.
  Future<void> startScan({
    List<BleUuid> withServices = const [],
    List<String> withNames = const [],
    List<String> withKeywords = const [],
    List<String> withRemoteIds = const [],
    List<ManufacturerDataFilter> withManufacturerData = const [],
    List<ServiceDataFilter> withServiceData = const [],
    String? withNamePrefix,
    Duration? timeout,
    bool allowDuplicates = false,
    int continuousDivisor = 1,
    Duration? removeIfGone,
    AndroidScanMode androidScanMode = AndroidScanMode.lowLatency,
    bool androidLegacy = false,
    bool androidCheckLocationServices = true,
    List<BleUuid> webOptionalServices = const [],
  }) async {
    if (continuousDivisor < 1) {
      throw ArgumentError.value(
          continuousDivisor, 'continuousDivisor', 'must be >= 1');
    }
    if (removeIfGone != null && !allowDuplicates) {
      throw ArgumentError('removeIfGone requires allowDuplicates');
    }
    final filter = _ScanFilter(
      services: withServices,
      names: withNames,
      keywords: withKeywords,
      remoteIds: {for (final id in withRemoteIds) canonicalDeviceId(id)},
      manufacturerData: withManufacturerData,
      serviceData: withServiceData,
      namePrefix: withNamePrefix,
    );
    final args = {
      'services': withServices.map((u) => u.value).toList(),
      'names': withNames,
      'keywords': withKeywords,
      'remoteIds': filter.remoteIds.toList(),
      'manufacturerData': [for (final f in withManufacturerData) f.toMap()],
      'serviceData': [for (final f in withServiceData) f.toMap()],
      'namePrefix': withNamePrefix,
      'allowDuplicates': allowDuplicates,
      'continuousDivisor': continuousDivisor,
      'androidScanMode': androidScanMode.code,
      'androidLegacy': androidLegacy,
      'androidCheckLocationServices': androidCheckLocationServices,
      'webOptionalServices': webOptionalServices.map((u) => u.value).toList(),
    };
    if (_scanning) await stopScan();
    _endScan();
    final scan = ++_scan;
    _scanFailure = null;
    _results.clear();
    _sorted.clear();
    _resultsCtrl.add(const []);
    _filter = filter;
    // Results may arrive before invoke() returns.
    _accepting = true;
    try {
      await BleChannel.invoke<void>('startScan', args);
    } catch (_) {
      if (scan == _scan) _accepting = false;
      rethrow;
    }
    // Another startScan meanwhile: it owns the scan now.
    if (scan != _scan) return;
    final failure = _scanFailure;
    if (failure != null) {
      _scanFailure = null;
      throw failure;
    }
    if (!_accepting) return; // stopScan meanwhile
    _setScanning(true);
    if (timeout != null) {
      _scanTimer = Timer(timeout, () => stopScan().catchError((_) {}));
    }
    if (removeIfGone != null) {
      final period = Duration(
          milliseconds: (removeIfGone.inMilliseconds ~/ 4).clamp(100, 1000));
      _goneTimer = Timer.periodic(period, (_) => _removeGone(removeIfGone));
    }
  }

  _ScanFilter? _filter;
  bool _accepting = false;
  Timer? _goneTimer;

  /// Incremented by every [startScan], so a superseded call does not mark
  /// the scan as running or arm its timers.
  int _scan = 0;

  /// A `scanFailed` that arrived before `startScan` returned.
  BleException? _scanFailure;

  /// Stops the scan. Always reaches the platform, even when no scan is
  /// known to be running.
  Future<void> stopScan() async {
    _endScan();
    final scan = _scan;
    try {
      await BleChannel.invoke<void>('stopScan');
    } finally {
      // A startScan issued meanwhile owns the flag now.
      if (scan == _scan) _setScanning(false);
    }
  }

  void _endScan() {
    _accepting = false;
    _scanTimer?.cancel();
    _scanTimer = null;
    _goneTimer?.cancel();
    _goneTimer = null;
  }

  void _removeGone(Duration maxAge) {
    final limit = DateTime.now().subtract(maxAge);
    final gone = _sorted.where((r) => r.timestamp.isBefore(limit)).toList();
    if (gone.isEmpty) return;
    for (final r in gone) {
      _results.remove(r.device.id);
      _sorted.remove(r);
    }
    if (_resultsCtrl.hasListener) _resultsCtrl.add(_sortedResults());
  }

  /// Cancels [subscription] when the current scan ends, or when the next
  /// one ends if no scan is running.
  void cancelWhenScanComplete(StreamSubscription<Object?> subscription) {
    var started = _scanning;
    late final StreamSubscription<bool> watch;
    watch = _scanningCtrl.stream.listen((scanning) {
      if (scanning) {
        started = true;
      } else if (started) {
        watch.cancel();
        subscription.cancel();
      }
    });
  }

  /// Devices paired with the system (Android, Linux, Windows). Classic-only
  /// Android devices are excluded because they cannot be reached over GATT.
  /// Empty on iOS, macOS and Web.
  Future<List<BleDevice>> bondedDevices() async {
    final raw = await BleChannel.invoke<List<Object?>>('getBondedDevices');
    return _devicesFrom(raw);
  }

  /// Devices currently connected through this plugin.
  ///
  /// Devices that are disconnected in this Dart session (e.g. after a hot
  /// restart, or restored by iOS) are marked connected.
  Future<List<BleDevice>> connectedDevices() async {
    final raw = await BleChannel.invoke<List<Object?>>('getConnectedDevices');
    final devices = _devicesFrom(raw);
    for (final d in devices) {
      // A connect() or disconnect() in flight decides the state itself.
      if (d.isDisconnected) d.handleConnectionEvent(true);
    }
    return devices;
  }

  /// Devices whose state is connected, without asking the platform.
  List<BleDevice> get connectedDevicesNow => [
        for (final d in _devices.values)
          if (d.isConnected) d
      ];

  /// LE devices connected to the system by any app (e.g. a watch or a
  /// keyboard). You still need to call `connect` to use them in your app.
  ///
  /// iOS/macOS only return devices exposing one of [withServices] (the
  /// Generic Access service 0x1800 when empty). Empty on Web.
  Future<List<BleDevice>> systemDevices(
      [List<BleUuid> withServices = const []]) async {
    final raw = await BleChannel.invoke<List<Object?>>('getSystemDevices', {
      'services': withServices.map((u) => u.value).toList(),
    });
    return _devicesFrom(raw);
  }

  List<BleDevice> _devicesFrom(List<Object?>? raw) => [
        for (final e in raw ?? const [])
          () {
            final m = Map<String, dynamic>.from(e as Map);
            return deviceFor(m['id'] as String, m['name'] as String?);
          }(),
      ];

  // ---- events ---------------------------------------------------------------

  /// A malformed event must not become an uncaught error (repeated for every
  /// advertisement or notification).
  void _onEventSafe(Map<String, dynamic> e) {
    try {
      _onEvent(e);
    } catch (error) {
      BleLog.log(BleLogLevel.error, () => 'bad event $e: $error');
    }
  }

  void _onEvent(Map<String, dynamic> e) {
    final type = e['type'];
    if (type != 'scanResult' && type != 'value' && type != 'log') {
      BleLog.log(BleLogLevel.debug, () => 'event $e');
    }
    switch (type) {
      case 'adapterState':
        _setAdapter(AdapterState.parse(e['state'] as String?));
        if (_adapterState != AdapterState.on && _scanning) {
          _endScan();
          _setScanning(false);
        }
      case 'scanResult':
        _onScanResult(e);
      case 'scanFailed':
        final code = e['code'] as int?;
        BleLog.log(BleLogLevel.error, () => 'scan failed: $code');
        if (_accepting && !_scanning) {
          _scanFailure = BleException('gatt_error', 'scan failed', code);
        }
        _endScan();
        _setScanning(false);
      case 'connectionState':
        final connected = e['connected'] == true;
        final code = e['reason'] as int?;
        final text = e['reasonText'] as String?;
        _eventDevice(e['id']).handleConnectionEvent(
            connected,
            connected || (code == null && text == null)
                ? null
                : DisconnectReason(code, text));
      case 'mtu':
        _eventDevice(e['id']).handleMtuEvent(e['mtu'] as int);
      case 'value':
        _eventDevice(e['id']).handleValueEvent(
          e['service'] as String,
          (e['serviceIndex'] as int?) ?? 0,
          e['characteristic'] as String,
          (e['characteristicIndex'] as int?) ?? 0,
          bytesFrom(e['value']),
        );
      case 'servicesReset':
        _eventDevice(e['id']).handleServicesReset();
      case 'bondState':
        _eventDevice(e['id']).handleBondEvent(e['state'] as String?);
      case 'name':
        _eventDevice(e['id']).handleNameEvent(e['name'] as String?);
      case 'phy':
        _eventDevice(e['id']).handlePhyEvent(e['tx'] as int?, e['rx'] as int?);
      case 'log':
        final level = (e['level'] as int?) ?? BleLogLevel.debug.index;
        BleLog.log(
          BleLogLevel.values[level.clamp(1, BleLogLevel.values.length - 1)],
          () => '${e['message']}',
          native: true,
        );
    }
  }

  void _onScanResult(Map<String, dynamic> e) {
    final filter = _filter;
    if (!_accepting || filter == null) return; // left over from a stopped scan
    final adv = AdvertisementData.fromMap(e);
    final rawId = e['id'] as String;
    final known = _devices[rawId];
    final id = known?.id ?? canonicalDeviceId(rawId);
    final name = (e['name'] as String?) ?? adv.localName;
    if (recheckScanFilters && !filter.matches(id, name, adv)) return;
    final device = known ?? deviceFor(id);
    device
      ..updateName(e['name'] as String?)
      ..updateAdvName(adv.localName);
    final r = ScanResult(
      device: device,
      rssi: (e['rssi'] as int?) ?? 0,
      advertisement: adv,
      timestamp: DateTime.now(),
    );
    BleLog.log(BleLogLevel.verbose, () => 'scan $r');
    final previous = _results[device.id];
    _results[device.id] = r;
    if (previous != null) _sorted.remove(previous);
    _sorted.insert(_insertionIndex(r.rssi), r);
    _resultCtrl.add(r);
    if (_resultsCtrl.hasListener) _resultsCtrl.add(_sortedResults());
  }

  /// First index whose RSSI is lower than [rssi] (binary search).
  int _insertionIndex(int rssi) {
    var lo = 0, hi = _sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_sorted[mid].rssi >= rssi) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  List<ScanResult> _sortedResults() => List.of(_sorted);

  void _setAdapter(AdapterState s) {
    if (s == _adapterState) return;
    _adapterState = s;
    _adapterChanges++;
    _adapterCtrl.add(s);
  }

  void _setScanning(bool v) {
    if (v == _scanning) return;
    _scanning = v;
    _scanningCtrl.add(v);
  }
}

/// Whether scan results are re-checked against the filters in Dart (not
/// exported; tests change it). Not on Web: the chooser result carries no
/// advertised services or manufacturer/service data (the browser hides
/// them), so the check would drop the device the user picked; the Web
/// backend already applies the filters through the chooser or in software.
bool recheckScanFilters = !kIsWeb;

/// Scan filter semantics of PROTOCOL.md, re-checked in Dart so every
/// platform behaves the same even if a backend pre-filters loosely.
class _ScanFilter {
  final List<BleUuid> services;
  final List<String> names;
  final List<String> keywords;
  final Set<String> remoteIds;
  final List<ManufacturerDataFilter> manufacturerData;
  final List<ServiceDataFilter> serviceData;
  final String? namePrefix;

  _ScanFilter({
    required this.services,
    required this.names,
    required this.keywords,
    required this.remoteIds,
    required this.manufacturerData,
    required this.serviceData,
    required this.namePrefix,
  });

  late final bool _hasAny = services.isNotEmpty ||
      names.isNotEmpty ||
      keywords.isNotEmpty ||
      remoteIds.isNotEmpty ||
      manufacturerData.isNotEmpty ||
      serviceData.isNotEmpty;

  bool matches(String id, String? name, AdvertisementData adv) {
    final prefix = namePrefix;
    if (prefix != null && !(name ?? '').startsWith(prefix)) return false;
    if (!_hasAny) return true;
    if (remoteIds.contains(id)) return true;
    if (name != null) {
      if (names.contains(name)) return true;
      for (final k in keywords) {
        if (name.contains(k)) return true;
      }
    }
    for (final s in services) {
      if (adv.serviceUuids.contains(s)) return true;
    }
    for (final f in manufacturerData) {
      if (f.matches(adv)) return true;
    }
    for (final f in serviceData) {
      if (f.matches(adv)) return true;
    }
    return false;
  }
}
