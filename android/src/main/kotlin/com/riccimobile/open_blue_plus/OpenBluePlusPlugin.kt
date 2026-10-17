package com.riccimobile.open_blue_plus

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry

@SuppressLint("MissingPermission")
class OpenBluePlusPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.ActivityResultListener {

    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private val handler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissions: Result? = null
    private var pendingPermissionList: List<String> = emptyList()
    private var pendingTurnOn: Result? = null

    private val sessions = HashMap<String, GattSession>()
    private val log = BleLog(::emit)
    private lateinit var bonds: BondManager

    private var scanCallback: ScanCallback? = null
    private val seenDuringScan = HashSet<String>()
    private val countsDuringScan = HashMap<String, Int>()
    // getName() is a binder call: remember the names already resolved during this scan.
    private val namesDuringScan = HashMap<String, String>()
    private val scanStarts = ArrayDeque<Long>()

    private val manager: BluetoothManager?
        get() = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager

    private val adapter: BluetoothAdapter?
        get() = manager?.adapter

    // ---- lifecycle ----------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "open_blue_plus/methods")
        methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "open_blue_plus/events")
        events.setStreamHandler(this)
        bonds = BondManager(context, handler, log)
        val filter = IntentFilter().apply {
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
            addAction(BluetoothDevice.ACTION_NAME_CHANGED)
        }
        registerSystemReceiver(context, systemReceiver, filter)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopScanInternal()
        sessions.values.toList().forEach { it.close(null, "Plugin detached") }
        bonds.failAll("not_connected", "Plugin detached")
        try {
            context.unregisterReceiver(systemReceiver)
        } catch (_: IllegalArgumentException) {
        }
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
    }

    // A Flutter hot restart cancels and re-listens: GATT sessions are kept on purpose so
    // the restarted Dart side can adopt them through getConnectedDevices.
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        // The activity is gone for good: its results will never arrive.
        pendingPermissions?.error("no_activity", "Activity detached before permissions were answered", null)
        pendingPermissions = null
        pendingTurnOn?.error("no_activity", "Activity detached before Bluetooth was enabled", null)
        pendingTurnOn = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    // Pending requests survive a configuration change: the recreated activity gets the result.
    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    private fun emit(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) sink?.success(event)
        else handler.post { sink?.success(event) }
    }

    // ---- method calls -------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "isSupported" -> result.success(
                    adapter != null && context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
                )
                "setOptions" -> result.success(false)
                "setLogLevel" -> {
                    log.level = call.argument<Number>("level")?.toInt() ?: 0
                    result.success(null)
                }
                "getAdapterState" -> result.success(adapterStateName())
                "getAdapterName" -> getAdapterName(result)
                "requestPermissions" -> requestPermissions(call.argument<Boolean>("androidFineLocation") ?: false, result)
                "turnOn" -> turnOn(result)
                "turnOff" -> turnOff(result)
                "getSystemDevices" -> getSystemDevices(result)
                "getPhySupport" -> getPhySupport(result)
                "startScan" -> startScan(call, result)
                "stopScan" -> {
                    stopScanInternal()
                    result.success(null)
                }
                "getConnectedDevices" -> result.success(
                    sessions.values.filter { it.connected }.map {
                        mapOf("id" to it.id, "name" to safeName(it))
                    }
                )
                "getBondedDevices" -> getBondedDevices(result)
                "getBondState" -> getBondState(call, result)
                "createBond", "removeBond" -> bond(call, result)
                "connect" -> connect(call, result)
                "disconnect" -> {
                    val s = sessions[call.id]
                    if (s == null) result.success(null) else s.disconnect(result)
                }
                else -> withSession(call, result)
            }
        } catch (e: SecurityException) {
            result.error("permission_denied", e.message ?: "Missing Bluetooth permission", null)
        } catch (e: IllegalArgumentException) {
            result.error("invalid_argument", e.message ?: "Invalid argument", null)
        } catch (e: ClassCastException) {
            // An argument of an unexpected type (MethodCall.argument casts unchecked).
            result.error("invalid_argument", e.message ?: "Invalid argument type", null)
        }
    }

    private fun withSession(call: MethodCall, result: Result) {
        val s = sessions[call.id]
        if (s == null || !s.connected) {
            if (call.method in GATT_METHODS) result.error("not_connected", "Device ${call.id} is not connected", null)
            else result.notImplemented()
            return
        }
        val timeoutMs = call.long("timeoutMs")
        when (call.method) {
            "discoverServices" -> s.discoverServices(timeoutMs, result)
            "read" -> s.read(call.target(), timeoutMs, result)
            "write" -> s.write(
                call.target(),
                call.argument<ByteArray>("value") ?: ByteArray(0),
                call.argument<Boolean>("withoutResponse") ?: false,
                timeoutMs, result,
            )
            "setNotify" -> s.setNotify(
                call.target(),
                call.argument<Boolean>("enable") ?: true,
                call.argument<Boolean>("forceIndications") ?: false,
                timeoutMs, result,
            )
            "readDescriptor" -> s.readDescriptor(call.target(), call.argument<String>("descriptor") ?: "", timeoutMs, result)
            "writeDescriptor" -> s.writeDescriptor(
                call.target(),
                call.argument<String>("descriptor") ?: "",
                call.argument<ByteArray>("value") ?: ByteArray(0),
                timeoutMs, result,
            )
            "requestMtu" -> s.requestMtu(call.int("mtu") ?: 517, timeoutMs, result)
            "readRssi" -> s.readRssi(timeoutMs, result)
            "requestConnectionPriority" -> s.requestConnectionPriority(call.int("priority") ?: 0, result)
            "clearGattCache" -> s.clearGattCache(timeoutMs, result)
            "setPreferredPhy" -> s.setPreferredPhy(
                call.int("txPhy") ?: 1, call.int("rxPhy") ?: 1, call.int("codedOption") ?: 0, result,
            )
            else -> result.notImplemented()
        }
    }

    // MAC addresses are upper-case on Android; rule 1 accepts any case on input.
    private val MethodCall.id: String get() = argument<String>("id")?.uppercase() ?: ""

    // Dart ints arrive as Int or Long depending on magnitude.
    private fun MethodCall.long(key: String): Long? = argument<Number>(key)?.toLong()

    private fun MethodCall.int(key: String): Int? = argument<Number>(key)?.toInt()

    private fun MethodCall.target() = GattSession.Target(
        argument<String>("service") ?: "",
        int("serviceIndex") ?: 0,
        argument<String>("characteristic") ?: "",
        int("characteristicIndex") ?: 0,
    )

    // ---- adapter & permissions ----------------------------------------------

    private fun adapterStateName(): String {
        val a = adapter ?: return "unavailable"
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) return "unavailable"
        return try {
            when (a.state) {
                BluetoothAdapter.STATE_ON -> "on"
                BluetoothAdapter.STATE_OFF -> "off"
                BluetoothAdapter.STATE_TURNING_ON -> "turningOn"
                BluetoothAdapter.STATE_TURNING_OFF -> "turningOff"
                else -> "unknown"
            }
        } catch (_: SecurityException) {
            "unauthorized"
        }
    }

    private val systemReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            when (intent.action) {
                BluetoothAdapter.ACTION_STATE_CHANGED -> onAdapterStateChanged(intent)
                BluetoothDevice.ACTION_BOND_STATE_CHANGED -> {
                    val id = intent.bluetoothDevice()?.address ?: return
                    val state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
                    val previous = intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, BluetoothDevice.ERROR)
                    val reason = intent.getIntExtra(BondManager.EXTRA_REASON, -1)
                    log.log(BleLog.INFO) { "Bond state of $id: $previous -> $state" }
                    bondStateName(state)?.let { emit(mapOf("type" to "bondState", "id" to id, "state" to it)) }
                    sessions[id]?.onBondStateChanged(state)
                    bonds.onBondStateChanged(id, state, previous, reason)
                }
                BluetoothDevice.ACTION_NAME_CHANGED -> {
                    val id = intent.bluetoothDevice()?.address ?: return
                    val name = intent.getStringExtra(BluetoothDevice.EXTRA_NAME) ?: return
                    if (scanCallback != null) namesDuringScan[id] = name
                    emit(mapOf("type" to "name", "id" to id, "name" to name))
                }
            }
        }
    }

    private fun onAdapterStateChanged(intent: Intent) {
        val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
        if (state == BluetoothAdapter.STATE_TURNING_OFF || state == BluetoothAdapter.STATE_OFF) {
            scanCallback = null
            sessions.values.toList().forEach { it.close(null, "Bluetooth turned off") }
            bonds.failAll("not_connected", "Bluetooth turned off")
        }
        emit(mapOf("type" to "adapterState", "state" to adapterStateName()))
    }

    private fun requiredPermissions(fineLocation: Boolean): List<String> =
        if (Build.VERSION.SDK_INT >= 31) {
            listOfNotNull(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.ACCESS_FINE_LOCATION.takeIf { fineLocation },
            )
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun granted(permission: String) =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun hasScanPermission() =
        if (Build.VERSION.SDK_INT >= 31) granted(Manifest.permission.BLUETOOTH_SCAN)
        else granted(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun hasConnectPermission() =
        Build.VERSION.SDK_INT < 31 || granted(Manifest.permission.BLUETOOTH_CONNECT)

    /** Whether the app's merged manifest declares [permission]. */
    private fun declared(permission: String): Boolean = try {
        @Suppress("DEPRECATION")
        context.packageManager
            .getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
            .requestedPermissions?.contains(permission) == true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    private fun requestPermissions(fineLocation: Boolean, result: Result) {
        val required = requiredPermissions(fineLocation)
        val undeclared = required.filterNot { declared(it) }
        if (undeclared.isNotEmpty()) {
            // Requesting an undeclared permission is silently denied by Android.
            result.error(
                "permission_denied",
                "Declare ${undeclared.joinToString()} in the app's AndroidManifest.xml",
                null,
            )
            return
        }
        val missing = required.filterNot { granted(it) }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error("no_activity", "Permissions can only be requested with a foreground activity", null)
            return
        }
        if (pendingPermissions != null) {
            result.error("busy", "A permission request is already in progress", null)
            return
        }
        pendingPermissions = result
        pendingPermissionList = required
        try {
            activity.requestPermissions(missing.toTypedArray(), REQUEST_PERMISSIONS)
        } catch (e: RuntimeException) {
            pendingPermissions = null
            throw e
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_PERMISSIONS) return false
        val result = pendingPermissions ?: return true
        pendingPermissions = null
        result.success(pendingPermissionList.all { granted(it) })
        return true
    }

    private fun turnOn(result: Result) {
        val a = adapter
        if (a == null) {
            result.success(false)
            return
        }
        if (a.isEnabled) {
            result.success(true)
            return
        }
        if (!hasConnectPermission()) {
            result.error("permission_denied", "BLUETOOTH_CONNECT permission is required", null)
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error("no_activity", "turnOn requires a foreground activity", null)
            return
        }
        if (pendingTurnOn != null) {
            result.error("busy", "A turnOn request is already in progress", null)
            return
        }
        pendingTurnOn = result
        try {
            activity.startActivityForResult(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE), REQUEST_ENABLE)
        } catch (e: RuntimeException) {
            pendingTurnOn = null
            if (e is SecurityException) throw e
            result.error("gatt_error", "Cannot show the enable Bluetooth dialog: ${e.message}", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_ENABLE) return false
        pendingTurnOn?.success(resultCode == Activity.RESULT_OK)
        pendingTurnOn = null
        return true
    }

    private fun turnOff(result: Result) {
        val a = adapter
        // BluetoothAdapter.disable() is a no-op returning false for apps targeting 33+.
        if (a == null || Build.VERSION.SDK_INT >= 33) return result.success(false)
        if (!a.isEnabled) return result.success(true)
        if (!hasConnectPermission()) {
            return result.error("permission_denied", "BLUETOOTH_CONNECT permission is required", null)
        }
        @Suppress("DEPRECATION")
        result.success(a.disable())
    }

    private fun getAdapterName(result: Result) {
        val a = adapter ?: return result.success("")
        if (!hasConnectPermission()) {
            return result.error("permission_denied", "BLUETOOTH_CONNECT permission not granted", null)
        }
        result.success(a.name ?: "")
    }

    private fun getPhySupport(result: Result) {
        val a = adapter
        if (a == null || Build.VERSION.SDK_INT < 26) {
            return result.success(mapOf("le2M" to false, "leCoded" to false))
        }
        result.success(mapOf("le2M" to a.isLe2MPhySupported, "leCoded" to a.isLeCodedPhySupported))
    }

    /** Location toggle; only Android 11 and lower need it for scan results. */
    private fun locationServicesEnabled(): Boolean {
        if (Build.VERSION.SDK_INT >= 28) {
            val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return true
            return lm.isLocationEnabled
        }
        @Suppress("DEPRECATION")
        return Settings.Secure.getInt(context.contentResolver, Settings.Secure.LOCATION_MODE, Settings.Secure.LOCATION_MODE_OFF) !=
            Settings.Secure.LOCATION_MODE_OFF
    }

    // ---- scanning -----------------------------------------------------------

    private fun startScan(call: MethodCall, result: Result) {
        if (!hasScanPermission()) {
            result.error("permission_denied", "Scan permission not granted (call requestPermissions first)", null)
            return
        }
        val a = adapter
        if (a == null || !a.isEnabled) {
            result.error("adapter_off", "Bluetooth is off", null)
            return
        }
        val scanner = a.bluetoothLeScanner
        if (scanner == null) {
            result.error("adapter_off", "Bluetooth LE scanner unavailable", null)
            return
        }
        // Built first: invalid filters fail without stopping the running scan.
        val matcher = ScanMatcher(
            services = call.argument<List<String>>("services").orEmpty(),
            names = call.argument<List<String>>("names").orEmpty(),
            keywords = call.argument<List<String>>("keywords").orEmpty(),
            remoteIds = call.argument<List<String>>("remoteIds").orEmpty(),
            manufacturerData = call.argument<List<Map<*, *>>>("manufacturerData").orEmpty(),
            serviceData = call.argument<List<Map<*, *>>>("serviceData").orEmpty(),
            namePrefix = call.argument<String>("namePrefix"),
        )
        stopScanInternal()
        throttleDelayMs()?.let { wait ->
            result.error(
                "busy",
                "Android allows only $MAX_SCAN_STARTS scan starts per ${SCAN_WINDOW_MS / 1000} s per app; " +
                    "a new scan now would silently return no results. Retry in ${(wait + 999) / 1000} s.",
                null,
            )
            return
        }

        if (Build.VERSION.SDK_INT <= 30 && call.argument<Boolean>("androidCheckLocationServices") == true &&
            !locationServicesEnabled()
        ) {
            result.error("location_services_off", "Location services are off: Android 11 and lower return no scan results", null)
            return
        }

        val allowDuplicates = call.argument<Boolean>("allowDuplicates") ?: false
        val divisor = if (allowDuplicates) (call.int("continuousDivisor") ?: 1).coerceAtLeast(1) else 1
        val mode = call.int("androidScanMode") ?: ScanSettings.SCAN_MODE_LOW_LATENCY
        val legacy = call.argument<Boolean>("androidLegacy") ?: false

        val filters = matcher.nativeFilters()
        val settings = ScanSettings.Builder().setScanMode(mode).apply {
            // Extended advertising is only reported with legacy off; not every controller has it.
            if (Build.VERSION.SDK_INT >= 26) {
                if (!legacy && a.isLeExtendedAdvertisingSupported) {
                    setLegacy(false)
                    setPhy(ScanSettings.PHY_LE_ALL_SUPPORTED)
                } else {
                    setLegacy(true)
                }
            }
        }.build()

        seenDuringScan.clear()
        countsDuringScan.clear()
        namesDuringScan.clear()
        // Without BLUETOOTH_CONNECT getName() throws: skip it instead of paying for an exception per result.
        val canReadName = hasConnectPermission()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, r: ScanResult) {
                if (scanCallback !== this) return
                val address = r.device.address
                if (!allowDuplicates && address in seenDuringScan) return
                val record = r.scanRecord
                val localName = record?.deviceName
                val name = if (canReadName) deviceName(r, address) else null
                // Filtered before de-duplicating: otherwise a first advertisement without a
                // name (or manufacturer data) would mark the device as seen and hide it.
                if (!matcher.matches(address, name, localName, record)) return
                if (!allowDuplicates) {
                    seenDuringScan.add(address)
                } else if (divisor > 1) {
                    val n = countsDuringScan[address] ?: 0
                    countsDuringScan[address] = n + 1
                    if (n % divisor != 0) return
                }
                emit(serializeScanResult(r, address, name, localName))
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach { onScanResult(ScanSettings.CALLBACK_TYPE_ALL_MATCHES, it) }
            }

            override fun onScanFailed(errorCode: Int) {
                if (scanCallback !== this) return
                scanCallback = null
                log.log(BleLog.WARNING) { "Scan failed: ${scanFailureReason(errorCode)} (code $errorCode)" }
                emit(mapOf("type" to "scanFailed", "code" to errorCode))
            }
        }
        scanCallback = cb
        try {
            scanner.startScan(filters, settings, cb)
        } catch (e: RuntimeException) {
            scanCallback = null
            if (e !is IllegalStateException) throw e
            // Thrown when the adapter turns off between the check above and the call.
            result.error("adapter_off", e.message ?: "Bluetooth is off", null)
            return
        }
        scanStarts.addLast(SystemClock.elapsedRealtime())
        log.log(BleLog.DEBUG) { "Scan started (${filters?.size ?: 0} native filters, legacy=$legacy)" }
        result.success(null)
    }

    /**
     * Android silently downgrades the 6th scan started within 30 s to an
     * opportunistic scan (no results, no error; only API 33+ may report
     * SCAN_FAILED_SCANNING_TOO_FREQUENTLY). Returns how long to wait, or null.
     */
    private fun throttleDelayMs(): Long? {
        val now = SystemClock.elapsedRealtime()
        while (scanStarts.isNotEmpty() && now - scanStarts.first() >= SCAN_WINDOW_MS) scanStarts.removeFirst()
        if (scanStarts.size < MAX_SCAN_STARTS) return null
        return SCAN_WINDOW_MS - (now - scanStarts.first())
    }

    private fun scanFailureReason(code: Int) = when (code) {
        ScanCallback.SCAN_FAILED_ALREADY_STARTED -> "a scan with the same settings is already running"
        ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED -> "the app could not be registered with the scanner"
        ScanCallback.SCAN_FAILED_INTERNAL_ERROR -> "internal Bluetooth error"
        ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED -> "scan feature not supported by this device"
        SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES -> "out of hardware resources"
        SCAN_FAILED_SCANNING_TOO_FREQUENTLY ->
            "scanning too frequently: Android allows $MAX_SCAN_STARTS scan starts per ${SCAN_WINDOW_MS / 1000} s per app"
        else -> "unknown error"
    }

    private fun stopScanInternal() {
        val cb = scanCallback ?: return
        scanCallback = null
        try {
            adapter?.takeIf { it.isEnabled }?.bluetoothLeScanner?.stopScan(cb)
        } catch (_: SecurityException) {
        } catch (_: IllegalStateException) {
        }
    }

    private fun deviceName(r: ScanResult, address: String): String? {
        namesDuringScan[address]?.let { return it }
        val name = try {
            r.device.name
        } catch (_: SecurityException) {
            null
        }
        if (name != null) namesDuringScan[address] = name
        return name
    }

    /** Hot path: built without intermediate pairs and with shared empty collections. */
    @SuppressLint("UseKtx") // platform SparseArray API; no androidx.core dependency
    private fun serializeScanResult(r: ScanResult, address: String, name: String?, localName: String?): Map<String, Any?> {
        val record = r.scanRecord
        val sparse = record?.manufacturerSpecificData
        val count = sparse?.size() ?: 0
        val manufacturer: Map<Int, ByteArray> =
            if (sparse == null || count == 0) emptyMap()
            else HashMap<Int, ByteArray>(count * 2).also { m ->
                for (i in 0 until count) m[sparse.keyAt(i)] = sparse.valueAt(i)
            }
        val rawServiceData = record?.serviceData
        val serviceData: Map<String, ByteArray> =
            if (rawServiceData.isNullOrEmpty()) emptyMap()
            else HashMap<String, ByteArray>(rawServiceData.size * 2).also { m ->
                for ((k, v) in rawServiceData) m[k.uuid.toString()] = v
            }
        val uuids = record?.serviceUuids
        val serviceUuids: List<String> =
            if (uuids.isNullOrEmpty()) emptyList() else uuids.map { it.uuid.toString() }
        val tx = record?.txPowerLevel ?: Int.MIN_VALUE
        return HashMap<String, Any?>(16).apply {
            put("type", "scanResult")
            put("id", address)
            put("name", name)
            put("rssi", r.rssi)
            put("connectable", Build.VERSION.SDK_INT < 26 || r.isConnectable)
            put("localName", localName)
            put("txPowerLevel", if (tx == Int.MIN_VALUE) null else tx)
            put("manufacturerData", manufacturer)
            put("serviceData", serviceData)
            put("serviceUuids", serviceUuids)
        }
    }

    // ---- connections --------------------------------------------------------

    private fun connect(call: MethodCall, result: Result) {
        if (!hasConnectPermission()) {
            result.error("permission_denied", "BLUETOOTH_CONNECT permission not granted", null)
            return
        }
        val a = adapter
        if (a == null || !a.isEnabled) {
            result.error("adapter_off", "Bluetooth is off", null)
            return
        }
        val id = call.id
        if (!BluetoothAdapter.checkBluetoothAddress(id)) {
            result.error("invalid_argument", "Invalid device address: $id", null)
            return
        }
        val session = sessions.getOrPut(id) {
            GattSession(context, a.getRemoteDevice(id), handler, ::emit, log) { closed ->
                if (sessions[closed.id] === closed) sessions.remove(closed.id)
            }
        }
        session.connect(call.argument<Boolean>("autoConnect") ?: false, result)
    }

    // ---- bonding ------------------------------------------------------------

    private fun bond(call: MethodCall, result: Result) {
        if (!hasConnectPermission()) {
            result.error("permission_denied", "BLUETOOTH_CONNECT permission not granted", null)
            return
        }
        val a = adapter
        if (a == null || !a.isEnabled) {
            result.error("adapter_off", "Bluetooth is off", null)
            return
        }
        val id = call.id
        if (!BluetoothAdapter.checkBluetoothAddress(id)) {
            result.error("invalid_argument", "Invalid device address: $id", null)
            return
        }
        val device = a.getRemoteDevice(id)
        if (call.method == "createBond") {
            bonds.createBond(device, call.argument<String>("pin"), call.long("timeoutMs") ?: BOND_TIMEOUT_MS, result)
        } else {
            bonds.removeBond(device, call.long("timeoutMs") ?: BOND_TIMEOUT_MS, result)
        }
    }

    private fun getSystemDevices(result: Result) {
        if (!hasConnectPermission()) {
            result.error("permission_denied", "BLUETOOTH_CONNECT permission not granted", null)
            return
        }
        val m = manager
        if (m == null || adapter?.isEnabled != true) {
            result.success(emptyList<Any>())
            return
        }
        result.success(m.getConnectedDevices(BluetoothProfile.GATT).map { mapOf("id" to it.address, "name" to it.name) })
    }

    private fun getBondedDevices(result: Result) {
        if (!hasConnectPermission()) {
            result.error("permission_denied", "BLUETOOTH_CONNECT permission not granted", null)
            return
        }
        val a = adapter
        if (a == null) {
            result.success(emptyList<Any>())
            return
        }
        // Classic-only devices cannot be reached over GATT, so they are left out.
        result.success(
            a.bondedDevices.orEmpty()
                .filter { it.type != BluetoothDevice.DEVICE_TYPE_CLASSIC }
                .map { mapOf("id" to it.address, "name" to it.name) }
        )
    }

    private fun getBondState(call: MethodCall, result: Result) {
        if (!hasConnectPermission()) {
            result.error("permission_denied", "BLUETOOTH_CONNECT permission not granted", null)
            return
        }
        val a = adapter
        val id = call.id
        if (a == null || !BluetoothAdapter.checkBluetoothAddress(id)) {
            result.success("unknown")
            return
        }
        result.success(bondStateName(a.getRemoteDevice(id).bondState) ?: "none")
    }

    private fun bondStateName(state: Int) = when (state) {
        BluetoothDevice.BOND_BONDED -> "bonded"
        BluetoothDevice.BOND_BONDING -> "bonding"
        BluetoothDevice.BOND_NONE -> "none"
        else -> null
    }

    private fun safeName(s: GattSession): String? = try {
        s.device.name
    } catch (_: SecurityException) {
        null
    }

    companion object {
        private const val BOND_TIMEOUT_MS = 30_000L
        private const val MAX_SCAN_STARTS = 5
        private const val SCAN_WINDOW_MS = 30_000L
        // ScanCallback constants added after minSdk (API 26 / 33).
        private const val SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES = 5
        private const val SCAN_FAILED_SCANNING_TOO_FREQUENTLY = 6
        private const val REQUEST_PERMISSIONS = 0x4250
        private const val REQUEST_ENABLE = 0x4251
        private val GATT_METHODS = setOf(
            "discoverServices", "read", "write", "setNotify", "readDescriptor",
            "writeDescriptor", "requestMtu", "readRssi", "requestConnectionPriority",
            "clearGattCache", "setPreferredPhy",
        )
    }
}
