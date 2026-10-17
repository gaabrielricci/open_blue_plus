import CoreBluetooth

#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import FlutterMacOS
  import SystemConfiguration
#endif

public class OpenBluePlusPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger  // a property on macOS
    #endif
    let instance = OpenBluePlusPlugin()
    let methods = FlutterMethodChannel(
      name: "open_blue_plus/methods", binaryMessenger: messenger)
    let events = FlutterEventChannel(
      name: "open_blue_plus/events", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(instance, channel: methods)
    events.setStreamHandler(instance)
  }

  /// nil until Dart listens and again between onCancel/onListen (hot
  /// restart): events are dropped then, while connections, notifications and
  /// a running scan carry on, and Dart re-adopts them via getConnectedDevices.
  private var sink: FlutterEventSink?
  private lazy var central = CentralController(emit: { [weak self] event in
    self?.sink?(event)
  })

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    central.handle(method: call.method, args: args, result: result)
  }
}

// MARK: - Errors

private func bleError(_ code: String, _ message: String, _ status: Int? = nil) -> FlutterError {
  FlutterError(code: code, message: message, details: status)
}

private func gattError(_ error: Error, _ op: String) -> FlutterError {
  let ns = error as NSError
  return bleError("gatt_error", "\(op) failed: \(ns.localizedDescription)", ns.code)
}

// MARK: - UUID helpers

private let sigBaseSuffix = "-0000-1000-8000-00805f9b34fb"

/// Full lowercase 128-bit form, matching what Android and Dart use.
private func fullUuid(_ uuid: CBUUID) -> String {
  let s = uuid.uuidString.lowercased()
  switch s.count {
  case 4: return "0000\(s)\(sigBaseSuffix)"
  case 8: return "\(s)\(sigBaseSuffix)"
  default: return s
  }
}

/// Accepts any spelling of a 128/32/16-bit UUID; nil when malformed. The
/// string handed to CBUUID is rebuilt in canonical form because CBUUID raises
/// an Objective-C exception (a crash) on anything else, e.g. a 128-bit UUID
/// without dashes or with misplaced ones.
private func cbUuid(_ s: String) -> CBUUID? {
  let hex = s.filter { $0 != "-" }
  // isHexDigit alone also accepts fullwidth digits, which CBUUID rejects.
  guard hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
  switch hex.count {
  case 4, 8:
    return CBUUID(string: hex)
  case 32:
    let h = Array(hex)
    let dashed = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(h[$0]) }
      .joined(separator: "-")
    return UUID(uuidString: dashed).map { CBUUID(nsuuid: $0) }
  default:
    return nil
  }
}

/// Parses a list of UUID strings; nil if any entry is malformed.
private func cbUuids(_ raw: [String]) -> [CBUUID]? {
  let list = raw.compactMap(cbUuid)
  return list.count == raw.count ? list : nil
}

private let cccdUuid = CBUUID(string: CBUUIDClientCharacteristicConfigurationString)

private let gattMethods: Set<String> = [
  "discoverServices", "read", "write", "setNotify", "readDescriptor", "writeDescriptor",
  "requestMtu", "readRssi",
]

private func bytes(_ v: Any?) -> Data? { (v as? FlutterStandardTypedData)?.data }

/// `(p[i] & m[i]) == (d[i] & m[i])` for every `i < d.count`; a nil mask is all 0xFF.
private func maskedMatch(_ p: Data, _ d: Data, _ m: Data?) -> Bool {
  guard p.count >= d.count else { return false }
  for i in 0..<d.count {
    let mask: UInt8 = m.map { i < $0.count ? $0[$0.startIndex + i] : 0xFF } ?? 0xFF
    if p[p.startIndex + i] & mask != d[d.startIndex + i] & mask { return false }
  }
  return true
}

// MARK: - Scan filter

/// startScan filters (PROTOCOL.md "Scan filtering"): the six lists are
/// OR-combined, namePrefix is AND-ed on top. Always checked here, also when
/// CoreBluetooth pre-filtered by service.
private struct ScanFilter {
  var services: [CBUUID] = []
  var names: Set<String> = []
  var keywords: [String] = []
  var remoteIds: Set<UUID> = []
  /// remoteIds was given, even if none of them is a valid Apple identifier.
  var hasRemoteIds = false
  var manufacturer: [(id: Int, data: Data, mask: Data?)] = []
  var serviceData: [(uuid: CBUUID, data: Data, mask: Data?)] = []
  var prefix: String?

  var hasLists: Bool {
    !services.isEmpty || !names.isEmpty || !keywords.isEmpty || hasRemoteIds
      || !manufacturer.isEmpty || !serviceData.isEmpty
  }

  /// CoreBluetooth can only filter by service: use it only when that is the
  /// sole list filter, so the native result set is a superset.
  var nativeServices: [CBUUID]? {
    services.isEmpty || !names.isEmpty || !keywords.isEmpty || hasRemoteIds
      || !manufacturer.isEmpty || !serviceData.isEmpty
      ? nil : services
  }

  init() {}

  /// nil when an argument is malformed.
  init?(_ args: [String: Any]) {
    guard let services = cbUuids(args["services"] as? [String] ?? []) else { return nil }
    self.services = services
    names = Set(args["names"] as? [String] ?? [])
    keywords = (args["keywords"] as? [String] ?? []).filter { !$0.isEmpty }
    // Ids that are not UUIDs (e.g. MACs) can never match; they are dropped
    // without turning the filter into "accept all".
    let rawIds = args["remoteIds"] as? [String] ?? []
    remoteIds = Set(rawIds.compactMap { UUID(uuidString: $0) })
    hasRemoteIds = !rawIds.isEmpty
    for e in args["manufacturerData"] as? [[String: Any]] ?? [] {
      guard let id = e["id"] as? Int else { return nil }
      manufacturer.append((id, bytes(e["data"]) ?? Data(), bytes(e["mask"])))
    }
    for e in args["serviceData"] as? [[String: Any]] ?? [] {
      guard let uuid = (e["service"] as? String).flatMap(cbUuid) else { return nil }
      serviceData.append((uuid, bytes(e["data"]) ?? Data(), bytes(e["mask"])))
    }
    let p = args["namePrefix"] as? String
    prefix = p?.isEmpty == false ? p : nil
  }

  func matches(
    id: UUID, name: String?, advertisedServices: [CBUUID], advertisement: [String: Any]
  ) -> Bool {
    if let prefix = prefix, !(name ?? "").hasPrefix(prefix) { return false }
    guard hasLists else { return true }
    if remoteIds.contains(id) { return true }
    if let name = name {
      if names.contains(name) { return true }
      if keywords.contains(where: { name.contains($0) }) { return true }
    }
    if !services.isEmpty && advertisedServices.contains(where: services.contains) { return true }
    if !manufacturer.isEmpty,
      let mfg = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 2
    {
      let company = Int(mfg[mfg.startIndex]) | (Int(mfg[mfg.startIndex + 1]) << 8)
      let payload = mfg.dropFirst(2)
      if manufacturer.contains(where: { $0.id == company && maskedMatch(payload, $0.data, $0.mask) }) {
        return true
      }
    }
    if !serviceData.isEmpty,
      let sd = advertisement[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
    {
      for (uuid, payload) in sd
      where serviceData.contains(where: { $0.uuid == uuid && maskedMatch(payload, $0.data, $0.mask) }) {
        return true
      }
    }
    return false
  }
}

// MARK: - Per-device state

/// Where a characteristic sits in the discoverServices list.
private struct CharAddress {
  let service: String
  let serviceIndex: Int
  let characteristic: String
  let characteristicIndex: Int
}

/// The flattened service list exactly as returned by discoverServices:
/// `peripheral.services` (primary) in order, then included services not seen
/// yet, breadth first. Each CBService object appears once.
private struct Layout {
  let services: [CBService]
  let addresses: [ObjectIdentifier: CharAddress]

  init(_ p: CBPeripheral, _ uuid: (CBUUID) -> String) {
    var list = p.services ?? []
    var seen = Set(list.map(ObjectIdentifier.init))
    var i = 0
    while i < list.count {
      for inc in list[i].includedServices ?? [] where seen.insert(ObjectIdentifier(inc)).inserted {
        list.append(inc)
      }
      i += 1
    }
    var addresses: [ObjectIdentifier: CharAddress] = [:]
    var serviceCount: [String: Int] = [:]
    for svc in list {
      let su = uuid(svc.uuid)
      let si = serviceCount[su, default: 0]
      serviceCount[su] = si + 1
      var charCount: [String: Int] = [:]
      for c in svc.characteristics ?? [] {
        let cu = uuid(c.uuid)
        let ci = charCount[cu, default: 0]
        charCount[cu] = ci + 1
        addresses[ObjectIdentifier(c)] = CharAddress(
          service: su, serviceIndex: si, characteristic: cu, characteristicIndex: ci)
      }
    }
    services = list
    self.addresses = addresses
  }
}

/// A running discoverServices: the callbacks still expected. Callbacks for
/// anything else are ignored.
private final class Discovery {
  enum Step: Hashable {
    case services
    case included(ObjectIdentifier)
    case characteristics(ObjectIdentifier)
    case descriptors(ObjectIdentifier)
  }

  var results: [FlutterResult]
  var pending: Set<Step> = [.services]
  /// Services already being explored (a service can be included many times).
  var explored: Set<ObjectIdentifier> = []

  init(_ result: @escaping FlutterResult) { results = [result] }

  func restart() {
    pending = [.services]
    explored = []
  }
}

/// Everything pending for one peripheral. GATT requests are keyed by the
/// CoreBluetooth object (characteristic / descriptor), not by UUID strings:
/// no string building on the hot path and no collision between two
/// characteristics sharing a UUID.
private final class Session {
  typealias Queues = [ObjectIdentifier: [FlutterResult]]
  private static let queues: [ReferenceWritableKeyPath<Session, Queues>] = [
    \.reads, \.writes, \.notify, \.descriptorReads, \.descriptorWrites,
  ]

  /// Identifier string, cached so value events don't rebuild it.
  let id: String
  /// Reached didConnect and not cleaned up yet.
  var connected = false
  var connectResults: [FlutterResult] = []
  var disconnectResults: [FlutterResult] = []
  var discovery: Discovery?
  /// Order of the last discoverServices (built lazily for restored links).
  var layout: Layout?
  var reads: Queues = [:]
  var writes: Queues = [:]
  var notify: Queues = [:]
  var descriptorReads: Queues = [:]
  var descriptorWrites: Queues = [:]
  var rssi: [FlutterResult] = []
  var withoutResponse: [(data: Data, characteristic: CBCharacteristic, result: FlutterResult)] = []

  init(id: String) { self.id = id }

  /// True if Dart was told (or is waiting to be told) about this link.
  var isTracked: Bool { connected || !connectResults.isEmpty || !disconnectResults.isEmpty }

  func failAll(_ err: FlutterError) {
    discovery?.results.forEach { $0(err) }
    discovery = nil
    for q in Session.queues {
      self[keyPath: q].values.forEach { $0.forEach { $0(err) } }
      self[keyPath: q] = [:]
    }
    rssi.forEach { $0(err) }
    rssi = []
    withoutResponse.forEach { $0.result(err) }
    withoutResponse = []
  }

  /// Fails the requests on these attributes (their callbacks will never come).
  func fail(_ objects: Set<ObjectIdentifier>, _ err: FlutterError) {
    guard !objects.isEmpty else { return }
    for q in Session.queues {
      for o in objects { self[keyPath: q].removeValue(forKey: o)?.forEach { $0(err) } }
    }
    var kept: [(data: Data, characteristic: CBCharacteristic, result: FlutterResult)] = []
    for w in withoutResponse {
      if objects.contains(ObjectIdentifier(w.characteristic)) { w.result(err) } else { kept.append(w) }
    }
    withoutResponse = kept
  }
}

private func enqueue(_ q: inout Session.Queues, _ obj: AnyObject, _ r: @escaping FlutterResult) {
  q[ObjectIdentifier(obj), default: []].append(r)
}

private func dequeue(_ q: inout Session.Queues, _ obj: AnyObject) -> FlutterResult? {
  let k = ObjectIdentifier(obj)
  guard var list = q[k], !list.isEmpty else { return nil }
  let r = list.removeFirst()
  q[k] = list.isEmpty ? nil : list
  return r
}

// MARK: - Central

/// Owns the CBCentralManager and the peripherals. Everything runs on the main
/// queue, so no locking is needed.
private final class CentralController: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  typealias Emit = ([String: Any?]) -> Void

  private let emit: Emit
  private var manager: CBCentralManager?
  private var stateWaiters: [() -> Void] = []
  private var logLevel = 0

  private var peripherals: [UUID: CBPeripheral] = [:]
  private var sessions: [UUID: Session] = [:]
  /// GATT UUID strings, computed once (bounded by the GATT tables seen).
  private var uuidStrings: [CBUUID: String] = [:]

  private var scanFilter = ScanFilter()
  private var scanAllowDuplicates = false
  private var scanDivisor = 1
  /// Reports that passed the filter during this scan, per device.
  private var scanSeen: [UUID: Int] = [:]

  init(emit: @escaping Emit) {
    self.emit = emit
  }

  /// The manager is created lazily because creating it triggers the
  /// Bluetooth permission prompt (rule 17: some methods must never create it).
  private var cm: CBCentralManager {
    manager ?? createManager([CBCentralManagerOptionShowPowerAlertKey: false])
  }

  @discardableResult
  private func createManager(_ options: [String: Any]) -> CBCentralManager {
    let m = CBCentralManager(delegate: self, queue: nil, options: options)
    manager = m
    log(4, "CBCentralManager created")
    return m
  }

  private func session(_ p: CBPeripheral) -> Session {
    if let s = sessions[p.identifier] { return s }
    let s = Session(id: p.identifier.uuidString)
    sessions[p.identifier] = s
    return s
  }

  private func gattUuid(_ u: CBUUID) -> String {
    if let s = uuidStrings[u] { return s }
    let s = fullUuid(u)
    uuidStrings[u] = s
    return s
  }

  /// `message` is only built when the level is enabled.
  private func log(_ level: Int, _ message: @autoclosure () -> String) {
    guard level <= logLevel else { return }
    emit(["type": "log", "level": level, "message": message()])
  }

  // MARK: Method dispatch

  func handle(method: String, args: [String: Any], result: @escaping FlutterResult) {
    switch method {
    case "isSupported":
      // CoreBluetooth always exists; only the simulator may lack an adapter,
      // and that is known only once a manager reported its state.
      #if targetEnvironment(simulator)
        result(manager.map { $0.state != .unsupported } ?? true)
      #else
        result(true)
      #endif
    case "setOptions":
      setOptions(args, result)
    case "setLogLevel":
      logLevel = args["level"] as? Int ?? 0
      result(nil)
    case "getAdapterState":
      whenStateKnown { result(self.stateName()) }
    case "getAdapterName":
      result(adapterName())
    case "requestPermissions":
      whenStateKnown {
        if #available(iOS 13.1, macOS 10.15, *) {
          result(CBCentralManager.authorization == .allowedAlways)
        } else {
          result(self.cm.state != .unauthorized)
        }
      }
    case "turnOn", "turnOff":
      result(false)
    case "startScan":
      startScan(args, result)
    case "stopScan":
      if let m = manager, m.state == .poweredOn { m.stopScan() }
      scanSeen = [:]
      result(nil)
    case "getBondedDevices":
      // CoreBluetooth does not expose the system's paired devices.
      result([])
    case "getBondState":
      result("unknown")
    case "createBond", "removeBond":
      result(bleError("not_supported", "iOS/macOS pair on demand; bonds cannot be managed by apps"))
    case "getConnectedDevices":
      // Only links made through this plugin (or restored by the OS):
      // cleanup() later reports each of them disconnected.
      result(
        sessions.compactMap { uuid, s -> [String: Any?]? in
          guard s.connected, let p = peripherals[uuid] else { return nil }
          return ["id": s.id, "name": p.name]
        })
    case "getSystemDevices":
      getSystemDevices(args, result)
    case "connect":
      connect(args, result)
    case "disconnect":
      disconnect(args, result)
    case "requestConnectionPriority", "setPreferredPhy", "clearGattCache":
      // Not exposed by CoreBluetooth (the OS manages them).
      result(nil)
    case "getPhySupport":
      result(["le2M": false, "leCoded": false])
    default:
      gattCall(method, args, result)
    }
  }

  private func setOptions(_ args: [String: Any], _ result: FlutterResult) {
    guard manager == nil else {
      result(false)
      return
    }
    var options: [String: Any] = [
      CBCentralManagerOptionShowPowerAlertKey: args["showPowerAlert"] as? Bool ?? false
    ]
    #if os(iOS)
      if args["restoreState"] as? Bool ?? false {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        // CoreBluetooth asserts when restoring without this background mode.
        if modes.contains("bluetooth-central") {
          let id = args["restoreIdentifier"] as? String ?? ""
          options[CBCentralManagerOptionRestoreIdentifierKey] = id.isEmpty ? "open_blue_plus" : id
        } else {
          log(2, "restoreState ignored: UIBackgroundModes lacks bluetooth-central")
        }
      }
    #endif
    createManager(options)
    result(true)
  }

  private func adapterName() -> String {
    #if os(iOS)
      // iOS 16+ returns the model ("iPhone") unless the app has the
      // user-assigned-device-name entitlement.
      return UIDevice.current.name
    #else
      // Reads the configured computer name; unlike Host.current() it does
      // not block on name resolution.
      return SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ""
    #endif
  }

  private func whenStateKnown(_ block: @escaping () -> Void) {
    if cm.state == .unknown || cm.state == .resetting {
      stateWaiters.append(block)
    } else {
      block()
    }
  }

  private func stateName() -> String {
    switch cm.state {
    case .poweredOn: return "on"
    case .poweredOff: return "off"
    case .unauthorized: return "unauthorized"
    case .unsupported: return "unavailable"
    default: return "unknown"
    }
  }

  private func requirePoweredOn(_ result: FlutterResult) -> Bool {
    switch cm.state {
    case .poweredOn: return true
    case .unauthorized:
      result(bleError("permission_denied", "Bluetooth permission not granted"))
    case .unsupported:
      result(bleError("unavailable", "Bluetooth LE is not supported"))
    default:
      result(bleError("adapter_off", "Bluetooth is off"))
    }
    return false
  }

  // MARK: Scanning

  private func startScan(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let filter = ScanFilter(args) else {
      result(bleError("invalid_argument", "Invalid scan filter"))
      return
    }
    whenStateKnown {
      guard self.requirePoweredOn(result) else { return }
      self.scanFilter = filter
      self.scanAllowDuplicates = args["allowDuplicates"] as? Bool ?? false
      self.scanDivisor = max(1, args["continuousDivisor"] as? Int ?? 1)
      self.scanSeen = [:]
      // Drop peripherals from earlier scans that are not in use; connect()
      // gets them back through retrievePeripherals(withIdentifiers:).
      self.peripherals = self.peripherals.filter {
        self.sessions[$0.key] != nil || $0.value.state != .disconnected
      }
      let native = filter.nativeServices
      // Without duplicates CoreBluetooth reports a device once, possibly
      // before its name or data is known; when filtering in software every
      // report is needed and de-duplication happens here instead.
      let softwareOnly = filter.prefix != nil || (filter.hasLists && native == nil)
      self.cm.stopScan()
      self.cm.scanForPeripherals(
        withServices: native,
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: self.scanAllowDuplicates || softwareOnly])
      self.log(3, "scan started (native services: \(native?.count ?? 0))")
      result(nil)
    }
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi RSSI: NSNumber
  ) {
    // 127 means "not available" in CoreBluetooth.
    let rssi = RSSI.intValue
    if rssi == 127 { return }
    let uuid = peripheral.identifier
    let name = peripheral.name
    let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
    let advertisedServices =
      (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
      + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])

    // Filter before de-duplicating: the first report of a device often has
    // no name yet (it arrives with the scan response).
    guard
      scanFilter.matches(
        id: uuid, name: name ?? localName, advertisedServices: advertisedServices,
        advertisement: advertisementData)
    else { return }
    if !scanAllowDuplicates {
      if scanSeen[uuid] != nil { return }
      scanSeen[uuid] = 1
    } else if scanDivisor > 1 {
      let n = scanSeen[uuid, default: 0]
      scanSeen[uuid] = n + 1
      if n % scanDivisor != 0 { return }
    }

    peripherals[uuid] = peripheral

    var manufacturer: [Int: FlutterStandardTypedData] = [:]
    if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 2 {
      let company = Int(data[data.startIndex]) | (Int(data[data.startIndex + 1]) << 8)
      manufacturer[company] = FlutterStandardTypedData(bytes: data.subdata(in: (data.startIndex + 2)..<data.endIndex))
    }
    var serviceData: [String: FlutterStandardTypedData] = [:]
    if let sd = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
      for (k, v) in sd { serviceData[gattUuid(k)] = FlutterStandardTypedData(bytes: v) }
    }

    emit([
      "type": "scanResult",
      "id": uuid.uuidString,
      "name": name,
      "rssi": rssi,
      "connectable": (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true,
      "localName": localName,
      "txPowerLevel": (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue,
      "manufacturerData": manufacturer,
      "serviceData": serviceData,
      "serviceUuids": advertisedServices.map(gattUuid),
    ])
  }

  // MARK: Adapter state

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    let state = central.state
    log(3, "adapter state \(stateName())")
    if state != .unknown && state != .resetting {
      let waiters = stateWaiters
      stateWaiters.removeAll()
      waiters.forEach { $0() }
    }
    // .unknown is the transient start-up state: keep restored peripherals.
    if state != .poweredOn && state != .unknown {
      // CoreBluetooth drops every connection without delegate callbacks here,
      // and peripheral.state is already .disconnected, so use our own bookkeeping.
      for uuid in Array(sessions.keys) { cleanup(uuid, message: "Bluetooth turned off") }
      // After .resetting the old CBPeripheral objects are stale; connect()
      // retrieves fresh ones by identifier.
      peripherals.removeAll()
      scanSeen = [:]
    }
    emit(["type": "adapterState", "state": stateName()])
  }

  /// Called before centralManagerDidUpdateState when iOS relaunches the app
  /// for a manager created with a restore identifier (setOptions). Restored
  /// peripherals keep their discovered services and notification states;
  /// value events are addressed against that tree until Dart calls
  /// discoverServices again.
  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
    log(3, "restoring \(restored.count) peripheral(s)")
    for p in restored {
      p.delegate = self
      peripherals[p.identifier] = p
      let s = session(p)
      // A pending connection (.connecting) is reported once didConnect fires.
      if p.state == .connected && !s.connected {
        s.connected = true
        emit(["type": "connectionState", "id": s.id, "connected": true])
      }
    }
  }

  // MARK: Connections

  private func peripheral(for args: [String: Any], _ result: FlutterResult) -> CBPeripheral? {
    guard let rawId = args["id"] as? String else {
      result(bleError("invalid_argument", "Missing device id"))
      return nil
    }
    // UUID parsing accepts any case; CoreBluetooth identifiers are uppercase.
    guard let uuid = UUID(uuidString: rawId) else {
      result(bleError("invalid_argument", "Invalid device id: \(rawId)"))
      return nil
    }
    if let p = peripherals[uuid] { return p }
    if let p = cm.retrievePeripherals(withIdentifiers: [uuid]).first {
      peripherals[uuid] = p
      return p
    }
    result(bleError("not_found", "Unknown device \(rawId); scan for it first"))
    return nil
  }

  private func getSystemDevices(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let parsed = cbUuids(args["services"] as? [String] ?? []) else {
      result(bleError("invalid_argument", "Invalid service UUID"))
      return
    }
    whenStateKnown {
      guard self.cm.state == .poweredOn else {
        result([])
        return
      }
      // CoreBluetooth requires at least one service; every LE device has GAP.
      let services = parsed.isEmpty ? [CBUUID(string: "1800")] : parsed
      let list = self.cm.retrieveConnectedPeripherals(withServices: services)
      // Kept so connect() resolves these ids (rule 6).
      for p in list { self.peripherals[p.identifier] = p }
      result(list.map { ["id": $0.identifier.uuidString, "name": $0.name] as [String: Any?] })
    }
  }

  private func connect(_ args: [String: Any], _ result: @escaping FlutterResult) {
    whenStateKnown {
      guard self.requirePoweredOn(result), let p = self.peripheral(for: args, result) else { return }
      let s = self.session(p)
      p.delegate = self
      if p.state == .connected {
        if !s.connected {
          s.connected = true
          self.emit(["type": "connectionState", "id": s.id, "connected": true])
          self.emit(["type": "mtu", "id": s.id, "mtu": self.currentMtu(p)])
        }
        result(nil)
        return
      }
      // A second caller (e.g. a Dart isolate after hot restart) shares the attempt.
      s.connectResults.append(result)
      guard s.connectResults.count == 1 else { return }
      self.log(3, "connecting \(s.id)")
      // autoConnect is Android only: CoreBluetooth connection attempts never
      // time out, Dart cancels them with disconnect.
      self.cm.connect(p, options: nil)
    }
  }

  private func disconnect(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let rawId = args["id"] as? String, let uuid = UUID(uuidString: rawId),
      let p = peripherals[uuid], let cm = manager, cm.state == .poweredOn
    else {
      result(nil)
      return
    }
    log(3, "disconnecting \(uuid.uuidString)")
    if p.state == .connected || p.state == .disconnecting {
      session(p).disconnectResults.append(result)
      cm.cancelPeripheralConnection(p)
    } else {
      // Cancelling a pending connection does not always produce a callback.
      if p.state == .connecting { cm.cancelPeripheralConnection(p) }
      cleanup(uuid, message: "Connection attempt cancelled")
      result(nil)
    }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    // No session: the attempt was cancelled by disconnect() (or the adapter
    // reset) but CoreBluetooth completed it anyway. Nobody wants this link.
    guard let s = sessions[peripheral.identifier] else {
      central.cancelPeripheralConnection(peripheral)
      return
    }
    s.connected = true
    log(3, "connected \(s.id)")
    emit(["type": "connectionState", "id": s.id, "connected": true])
    emit(["type": "mtu", "id": s.id, "mtu": currentMtu(peripheral)])
    let results = s.connectResults
    s.connectResults = []
    results.forEach { $0(nil) }
  }

  /// A callback for an attempt that disconnect() already cancelled can arrive
  /// after connect() started a new one (the peripheral is .connecting again);
  /// it must not fail the new attempt.
  private func isStale(_ p: CBPeripheral) -> Bool {
    p.state == .connecting && sessions[p.identifier]?.connected == false
  }

  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) {
    guard !isStale(peripheral) else { return }
    let ns = error as NSError?
    cleanup(
      peripheral.identifier, message: "Connection failed", error: ns,
      connectError: bleError("connect_failed", ns?.localizedDescription ?? "Connection failed", ns?.code))
  }

  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
  ) {
    guard !isStale(peripheral) else { return }
    // error is nil for a disconnect requested by the app.
    let ns = error as NSError?
    cleanup(peripheral.identifier, message: ns?.localizedDescription ?? "Disconnected", error: ns)
  }

  /// Fails every pending request for the device and reports it disconnected
  /// (once: a second callback for the same link finds no session).
  private func cleanup(
    _ uuid: UUID, message: String, error: NSError? = nil, connectError: FlutterError? = nil
  ) {
    guard let s = sessions.removeValue(forKey: uuid) else { return }
    let tracked = s.isTracked
    log(3, "disconnected \(s.id): \(message)")
    let connectErr = connectError ?? bleError("connect_failed", message)
    s.connectResults.forEach { $0(connectErr) }
    s.disconnectResults.forEach { $0(nil) }
    s.failAll(bleError("not_connected", message))
    guard tracked else { return }
    var event: [String: Any?] = ["type": "connectionState", "id": s.id, "connected": false]
    if let error = error {
      event["reason"] = error.code
      event["reasonText"] = error.localizedDescription
    }
    emit(event)
  }

  // MARK: GATT

  private func currentMtu(_ p: CBPeripheral) -> Int {
    p.maximumWriteValueLength(for: .withoutResponse) + 3
  }

  private func connectedPeripheral(_ args: [String: Any], _ result: FlutterResult) -> CBPeripheral? {
    guard let id = args["id"] as? String, let uuid = UUID(uuidString: id),
      let p = peripherals[uuid], p.state == .connected
    else {
      result(bleError("not_connected", "Device is not connected"))
      return nil
    }
    return p
  }

  private func layout(_ p: CBPeripheral, _ s: Session) -> Layout {
    if let l = s.layout { return l }
    let l = Layout(p, gattUuid)
    s.layout = l
    return l
  }

  private func findCharacteristic(
    _ p: CBPeripheral, _ s: Session, _ args: [String: Any], _ result: FlutterResult
  ) -> CBCharacteristic? {
    let svcArg = args["service"] as? String ?? ""
    let chrArg = args["characteristic"] as? String ?? ""
    let svcIndex = args["serviceIndex"] as? Int ?? 0
    let chrIndex = args["characteristicIndex"] as? Int ?? 0
    guard let svc = cbUuid(svcArg), let chr = cbUuid(chrArg), svcIndex >= 0, chrIndex >= 0 else {
      result(bleError("invalid_argument", "Invalid address: \(svcArg)[\(svcIndex)] / \(chrArg)[\(chrIndex)]"))
      return nil
    }
    // CBUUID equality treats 16/32-bit and their 128-bit forms as equal.
    let service = layout(p, s).services.lazy.filter { $0.uuid == svc }.dropFirst(svcIndex).first
    let c = service?.characteristics?.lazy.filter { $0.uuid == chr }.dropFirst(chrIndex).first
    if c == nil {
      result(bleError("not_found", "No characteristic \(chrArg) (did you call discoverServices?)"))
    }
    return c
  }

  private func findDescriptor(
    _ p: CBPeripheral, _ s: Session, _ args: [String: Any], _ result: FlutterResult
  ) -> CBDescriptor? {
    guard let c = findCharacteristic(p, s, args, result) else { return nil }
    let arg = args["descriptor"] as? String ?? ""
    guard let uuid = cbUuid(arg) else {
      result(bleError("invalid_argument", "Invalid descriptor UUID: \(arg)"))
      return nil
    }
    let d = c.descriptors?.first { $0.uuid == uuid }
    if d == nil { result(bleError("not_found", "No descriptor \(arg)")) }
    return d
  }

  /// Starts setNotifyValue (shared by setNotify and CCCD writes). Disabling
  /// on a characteristic without notify/indicate is a successful no-op.
  /// CoreBluetooth picks notify or indicate itself (forceIndications is ignored).
  private func setNotify(
    _ p: CBPeripheral, _ s: Session, _ c: CBCharacteristic, _ enable: Bool,
    _ result: @escaping FlutterResult
  ) {
    if !c.properties.contains(.notify) && !c.properties.contains(.indicate) {
      result(
        enable ? bleError("not_supported", "Characteristic supports neither notify nor indicate") : nil)
      return
    }
    enqueue(&s.notify, c, result)
    p.setNotifyValue(enable, for: c)
  }

  private func gattCall(_ method: String, _ args: [String: Any], _ result: @escaping FlutterResult) {
    guard gattMethods.contains(method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let p = connectedPeripheral(args, result) else { return }
    let s = session(p)

    switch method {
    case "discoverServices":
      // Dart shares concurrent discoveries (rule 13); a caller from before a
      // hot restart may still be waiting, so join the running one.
      if let d = s.discovery {
        d.results.append(result)
        return
      }
      s.discovery = Discovery(result)
      p.discoverServices(nil)

    case "read":
      guard let c = findCharacteristic(p, s, args, result) else { return }
      enqueue(&s.reads, c, result)
      p.readValue(for: c)

    case "write":
      guard let c = findCharacteristic(p, s, args, result) else { return }
      let data = bytes(args["value"]) ?? Data()
      if args["withoutResponse"] as? Bool ?? false {
        if s.withoutResponse.isEmpty && p.canSendWriteWithoutResponse {
          p.writeValue(data, for: c, type: .withoutResponse)
          result(nil)
        } else {
          s.withoutResponse.append((data, c, result))
        }
      } else {
        enqueue(&s.writes, c, result)
        p.writeValue(data, for: c, type: .withResponse)
      }

    case "setNotify":
      guard let c = findCharacteristic(p, s, args, result) else { return }
      setNotify(p, s, c, args["enable"] as? Bool ?? true, result)

    case "readDescriptor":
      guard let d = findDescriptor(p, s, args, result) else { return }
      enqueue(&s.descriptorReads, d, result)
      p.readValue(for: d)

    case "writeDescriptor":
      guard let d = findDescriptor(p, s, args, result) else { return }
      let value = bytes(args["value"]) ?? Data()
      if d.uuid == cccdUuid {
        // CoreBluetooth throws if the CCCD is written directly; map it to setNotify.
        guard let c = d.characteristic else {
          result(bleError("not_found", "Descriptor has no characteristic"))
          return
        }
        // Any non-zero value enables (rule 3); all zeros disables.
        setNotify(p, s, c, value.contains { $0 != 0 }, result)
        return
      }
      enqueue(&s.descriptorWrites, d, result)
      p.writeValue(value, for: d)

    case "requestMtu":
      // iOS negotiates the MTU automatically; report the current one.
      let mtu = currentMtu(p)
      emit(["type": "mtu", "id": s.id, "mtu": mtu])
      result(mtu)

    default:  // readRssi
      s.rssi.append(result)
      p.readRSSI()
    }
  }

  // MARK: Discovery chain: services -> included services + characteristics -> descriptors

  /// Discovers a service's included services and characteristics, once per
  /// CBService object.
  private func explore(_ p: CBPeripheral, _ svc: CBService, _ d: Discovery) {
    let id = ObjectIdentifier(svc)
    guard d.explored.insert(id).inserted else { return }
    d.pending.insert(.included(id))
    d.pending.insert(.characteristics(id))
    p.discoverIncludedServices(nil, for: svc)
    p.discoverCharacteristics(nil, for: svc)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let s = sessions[peripheral.identifier], let d = s.discovery,
      d.pending.remove(.services) != nil
    else { return }
    if let error = error {
      s.discovery = nil
      log(1, "discoverServices failed: \(error.localizedDescription)")
      d.results.forEach { $0(gattError(error, "discoverServices")) }
      return
    }
    for svc in peripheral.services ?? [] { explore(peripheral, svc, d) }
    finishDiscoveryIfDone(peripheral, s)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: Error?
  ) {
    guard let s = sessions[peripheral.identifier], let d = s.discovery,
      d.pending.remove(.included(ObjectIdentifier(service))) != nil
    else { return }
    if error == nil {
      for inc in service.includedServices ?? [] { explore(peripheral, inc, d) }
    }
    finishDiscoveryIfDone(peripheral, s)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
  ) {
    guard let s = sessions[peripheral.identifier], let d = s.discovery,
      d.pending.remove(.characteristics(ObjectIdentifier(service))) != nil
    else { return }
    let chars = error == nil ? (service.characteristics ?? []) : []
    for c in chars {
      d.pending.insert(.descriptors(ObjectIdentifier(c)))
      peripheral.discoverDescriptors(for: c)
    }
    finishDiscoveryIfDone(peripheral, s)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard let s = sessions[peripheral.identifier],
      s.discovery?.pending.remove(.descriptors(ObjectIdentifier(characteristic))) != nil
    else { return }
    finishDiscoveryIfDone(peripheral, s)
  }

  /// Service Changed indication (rule 18). Requests on the invalidated
  /// attributes never complete, so they fail now; a running discovery is
  /// restarted because its pending callbacks may never arrive either.
  func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
    guard let s = sessions[peripheral.identifier] else { return }
    log(3, "services changed on \(s.id)")
    s.layout = nil
    var objects = Set<ObjectIdentifier>()
    for svc in invalidatedServices {
      for c in svc.characteristics ?? [] {
        objects.insert(ObjectIdentifier(c))
        c.descriptors?.forEach { objects.insert(ObjectIdentifier($0)) }
      }
    }
    s.fail(objects, bleError("gatt_error", "Services changed; call discoverServices again"))
    emit(["type": "servicesReset", "id": s.id])
    if let d = s.discovery {
      d.restart()
      peripheral.discoverServices(nil)
    }
  }

  private func finishDiscoveryIfDone(_ p: CBPeripheral, _ s: Session) {
    guard let d = s.discovery, d.pending.isEmpty else { return }
    s.discovery = nil
    let l = Layout(p, gattUuid)
    s.layout = l
    var position: [ObjectIdentifier: Int] = [:]
    for (i, svc) in l.services.enumerated() { position[ObjectIdentifier(svc)] = i }
    let services: [[String: Any]] = l.services.map { svc in
      [
        "uuid": gattUuid(svc.uuid),
        "primary": svc.isPrimary,
        "included": (svc.includedServices ?? []).compactMap { position[ObjectIdentifier($0)] },
        "characteristics": (svc.characteristics ?? []).map { c in
          [
            "uuid": gattUuid(c.uuid),
            "properties": Int(c.properties.rawValue & 0xFF),
            "descriptors": (c.descriptors ?? []).map { gattUuid($0.uuid) },
          ] as [String: Any]
        },
      ]
    }
    log(4, "discovered \(services.count) service(s) on \(s.id)")
    d.results.forEach { $0(services) }
  }

  // MARK: Values

  /// Address of a characteristic in the last discoverServices order. A
  /// characteristic missing from it (discovered since) gets its address
  /// from the current tree.
  private func address(_ p: CBPeripheral, _ s: Session, _ c: CBCharacteristic) -> CharAddress {
    let k = ObjectIdentifier(c)
    if let a = layout(p, s).addresses[k] ?? Layout(p, gattUuid).addresses[k] { return a }
    return CharAddress(
      service: c.service.map { gattUuid($0.uuid) } ?? "", serviceIndex: 0,
      characteristic: gattUuid(c.uuid), characteristicIndex: 0)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard let s = sessions[peripheral.identifier] else { return }
    // A notification can't be told apart from a read response; the oldest
    // pending read (if any) takes the value.
    let pending = s.reads.isEmpty ? nil : dequeue(&s.reads, characteristic)
    if let error = error {
      pending?(gattError(error, "read"))
      return
    }
    let value = FlutterStandardTypedData(bytes: characteristic.value ?? Data())
    let a = address(peripheral, s, characteristic)
    emit([
      "type": "value",
      "id": s.id,
      "service": a.service,
      "serviceIndex": a.serviceIndex,
      "characteristic": a.characteristic,
      "characteristicIndex": a.characteristicIndex,
      "value": value,
    ])
    pending?(value)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard let s = sessions[peripheral.identifier], let r = dequeue(&s.writes, characteristic)
    else { return }
    r(error.map { gattError($0, "write") })
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard let s = sessions[peripheral.identifier], let r = dequeue(&s.notify, characteristic)
    else { return }
    r(error.map { gattError($0, "setNotify") })
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?
  ) {
    guard let s = sessions[peripheral.identifier], let r = dequeue(&s.descriptorReads, descriptor)
    else { return }
    if let error = error {
      r(gattError(error, "readDescriptor"))
      return
    }
    r(FlutterStandardTypedData(bytes: descriptorBytes(descriptor.value)))
  }

  func peripheral(
    _ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?
  ) {
    guard let s = sessions[peripheral.identifier], let r = dequeue(&s.descriptorWrites, descriptor)
    else { return }
    r(error.map { gattError($0, "writeDescriptor") })
  }

  /// CoreBluetooth decodes some descriptors into NSNumber / String.
  private func descriptorBytes(_ value: Any?) -> Data {
    switch value {
    case let d as Data: return d
    case let s as String: return Data(s.utf8)
    case let n as NSNumber:
      let v = n.uint16Value
      return Data([UInt8(v & 0xFF), UInt8(v >> 8)])
    default: return Data()
    }
  }

  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    guard let s = sessions[peripheral.identifier] else { return }
    while peripheral.canSendWriteWithoutResponse, !s.withoutResponse.isEmpty {
      let w = s.withoutResponse.removeFirst()
      peripheral.writeValue(w.data, for: w.characteristic, type: .withoutResponse)
      w.result(nil)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
    guard let s = sessions[peripheral.identifier], !s.rssi.isEmpty else { return }
    let r = s.rssi.removeFirst()
    r(error.map { gattError($0, "readRssi") } ?? RSSI.intValue)
  }

  func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
    guard let s = sessions[peripheral.identifier] else { return }
    emit(["type": "name", "id": s.id, "name": peripheral.name ?? ""])
  }
}
