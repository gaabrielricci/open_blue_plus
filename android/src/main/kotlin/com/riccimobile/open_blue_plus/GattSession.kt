package com.riccimobile.open_blue_plus

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.Context
import android.os.Build
import android.os.Handler
import io.flutter.plugin.common.MethodChannel.Result
import java.lang.reflect.InvocationTargetException
import java.util.IdentityHashMap
import java.util.UUID

/**
 * One GATT connection to a peripheral.
 *
 * Android only allows one outstanding GATT request per connection, so every
 * request goes through a FIFO queue and the next one starts when the callback
 * of the previous one arrives (or it times out). All state is touched only on
 * the main thread: GATT callbacks are re-posted to [handler].
 *
 * A session lives for exactly one BluetoothGatt: once [close] runs it is
 * removed by the plugin and a later connect creates a new session.
 */
@SuppressLint("MissingPermission")
internal class GattSession(
    private val context: Context,
    val device: BluetoothDevice,
    private val handler: Handler,
    private val emit: (Map<String, Any?>) -> Unit,
    private val log: BleLog,
    private val onClosed: (GattSession) -> Unit,
) {
    private enum class State { IDLE, CONNECTING, CONNECTED, DISCONNECTING, CLOSED }

    private sealed class Start {
        /** Waiting for a callback; [target] identifies the attribute it must be about. */
        class Pending(val target: String? = null) : Start()
        class Done(val value: Any?) : Start()
        class Fail(val code: String, val message: String, val status: Int? = null) : Start()
    }

    private class Op(val kind: String, val result: Result, val timeoutMs: Long, val start: (BluetoothGatt) -> Start)

    /** Protocol address of a characteristic, precomputed at discovery for `value` events. */
    private class Address(val service: String, val serviceIndex: Int, val characteristic: String, val characteristicIndex: Int)

    /** Characteristic/descriptor/service coordinates sent by Dart. */
    class Target(
        val service: String,
        val serviceIndex: Int,
        val characteristic: String,
        val characteristicIndex: Int,
    )

    private var state = State.IDLE
    private var gatt: BluetoothGatt? = null
    private var connectResult: Result? = null
    private val disconnectResults = mutableListOf<Result>()
    private val queue = ArrayDeque<Op>()
    private var current: Op? = null
    private var currentTarget: String? = null
    private var currentTimeout: Runnable? = null
    // Requests started during SMP pairing are lost or fail with 133 on many stacks:
    // the queue holds them until bonding ends (fed by the plugin's bond receiver).
    private var bonding = false

    // Services in the order returned by the last discoverServices, and the address of
    // each characteristic by object identity (callbacks hand back the same objects).
    private var services: List<BluetoothGattService> = emptyList()
    private var addresses = IdentityHashMap<BluetoothGattCharacteristic, Address>()

    val connected: Boolean get() = state == State.CONNECTED

    val id: String get() = device.address

    // ---- connection ---------------------------------------------------------

    fun connect(autoConnect: Boolean, result: Result) {
        when (state) {
            State.CONNECTED -> return result.success(null)
            State.CONNECTING -> return result.error("busy", "A connection attempt is already in progress", null)
            State.DISCONNECTING -> return result.error("busy", "A disconnection is in progress", null)
            State.CLOSED -> return result.error("connect_failed", "Session closed", null)
            State.IDLE -> Unit
        }
        val g = try {
            device.connectGatt(context, autoConnect, callback, BluetoothDevice.TRANSPORT_LE)
        } catch (e: SecurityException) {
            result.error("permission_denied", e.message ?: "BLUETOOTH_CONNECT permission not granted", null)
            close(null, "connectGatt failed")
            return
        }
        connectResult = result
        if (g == null) {
            close(null, "connectGatt returned null")
            return
        }
        gatt = g
        state = State.CONNECTING
    }

    fun disconnect(result: Result) {
        val g = gatt
        when (state) {
            State.IDLE, State.CLOSED -> result.success(null)
            // No disconnect callback comes for a pending connection: cancel now.
            State.CONNECTING -> {
                result.success(null)
                close(null, "Connection attempt cancelled")
            }
            State.DISCONNECTING -> disconnectResults.add(result)
            State.CONNECTED -> {
                state = State.DISCONNECTING
                failPending("Disconnecting", null)
                disconnectResults.add(result)
                try {
                    g?.disconnect()
                } catch (_: SecurityException) {
                    close(null, "Disconnected")
                    return
                }
                // Some stacks never report the disconnect: close anyway after a grace period.
                handler.postDelayed({ if (gatt === g) close(null, "Disconnected") }, DISCONNECT_GRACE_MS)
            }
        }
    }

    /** Releases the BluetoothGatt and completes every pending request. */
    fun close(status: Int?, reason: String) {
        if (state == State.CLOSED) return
        val wasConnected = state == State.CONNECTED || state == State.DISCONNECTING
        state = State.CLOSED
        failPending(reason, status)
        connectResult?.error("connect_failed", reason, status)
        connectResult = null
        disconnectResults.forEach { it.success(null) }
        disconnectResults.clear()
        gatt?.let { g ->
            gatt = null
            try {
                // disconnect() first also cancels a pending (auto)connect.
                g.disconnect()
                g.close()
            } catch (_: SecurityException) {
            }
        }
        if (wasConnected) {
            log.log(BleLog.INFO) { "Disconnected from $id: $reason" }
            emit(
                if (status == null) mapOf("type" to "connectionState", "id" to id, "connected" to false)
                else mapOf(
                    "type" to "connectionState", "id" to id, "connected" to false,
                    "reason" to status, "reasonText" to reasonText(status),
                )
            )
        }
        onClosed(this)
    }

    private fun failPending(reason: String, status: Int?) {
        cancelTimeout()
        current?.result?.error("not_connected", reason, status)
        current = null
        currentTarget = null
        while (queue.isNotEmpty()) queue.removeFirst().result.error("not_connected", reason, status)
    }

    // ---- GATT requests ------------------------------------------------------

    fun discoverServices(timeoutMs: Long?, result: Result) = enqueue("discover", timeoutMs, result) { g ->
        if (g.discoverServices()) Start.Pending() else Start.Fail("gatt_error", "discoverServices failed to start")
    }

    fun read(t: Target, timeoutMs: Long?, result: Result) = enqueue("read", timeoutMs, result) { g ->
        val c = findCharacteristic(g, t) ?: return@enqueue notFound("characteristic", t.characteristic)
        if (g.readCharacteristic(c)) Start.Pending(key(c)) else Start.Fail("gatt_error", "readCharacteristic failed to start")
    }

    fun write(t: Target, value: ByteArray, withoutResponse: Boolean, timeoutMs: Long?, result: Result) =
        enqueue("write", timeoutMs, result) { g ->
            val c = findCharacteristic(g, t) ?: return@enqueue notFound("characteristic", t.characteristic)
            val type = if (withoutResponse) BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            else BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            // onCharacteristicWrite also fires for writes without response, which
            // keeps the queue flow-controlled.
            if (Build.VERSION.SDK_INT >= 33) {
                startStatus("writeCharacteristic", g.writeCharacteristic(c, value, type), key(c))
            } else {
                @Suppress("DEPRECATION")
                c.writeType = type
                @Suppress("DEPRECATION")
                c.value = value
                @Suppress("DEPRECATION")
                val ok = g.writeCharacteristic(c)
                if (ok) Start.Pending(key(c)) else Start.Fail("gatt_error", "writeCharacteristic failed to start")
            }
        }

    fun setNotify(t: Target, enable: Boolean, forceIndications: Boolean, timeoutMs: Long?, result: Result) =
        enqueue("descriptorWrite", timeoutMs, result) { g ->
            val c = findCharacteristic(g, t) ?: return@enqueue notFound("characteristic", t.characteristic)
            startNotify(g, c, enable, forceIndications)
        }

    /** Shared by setNotify and CCCD writes: also registers the local listener. */
    private fun startNotify(g: BluetoothGatt, c: BluetoothGattCharacteristic, enable: Boolean, indicate: Boolean): Start {
        val props = c.properties
        val canNotify = props and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0
        val canIndicate = props and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0
        val value = when {
            // Disabling something that cannot notify is a no-op.
            !enable && !canNotify && !canIndicate -> return Start.Done(null)
            !enable -> BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
            indicate && !canIndicate -> return Start.Fail("not_supported", "Characteristic does not support indications")
            indicate -> BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
            canNotify -> BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            canIndicate -> BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
            else -> return Start.Fail("not_supported", "Characteristic supports neither notify nor indicate")
        }
        if (!g.setCharacteristicNotification(c, enable)) {
            return Start.Fail("gatt_error", "setCharacteristicNotification failed")
        }
        val cccd = c.getDescriptor(CCCD) ?: return Start.Done(null)
        return writeDescriptorCompat(g, cccd, value)
    }

    fun readDescriptor(t: Target, descriptor: String, timeoutMs: Long?, result: Result) =
        enqueue("descriptorRead", timeoutMs, result) { g ->
            val d = findCharacteristic(g, t)?.getDescriptor(UUID.fromString(descriptor))
                ?: return@enqueue notFound("descriptor", descriptor)
            if (g.readDescriptor(d)) Start.Pending(key(d)) else Start.Fail("gatt_error", "readDescriptor failed to start")
        }

    fun writeDescriptor(t: Target, descriptor: String, value: ByteArray, timeoutMs: Long?, result: Result) =
        enqueue("descriptorWrite", timeoutMs, result) { g ->
            val d = findCharacteristic(g, t)?.getDescriptor(UUID.fromString(descriptor))
                ?: return@enqueue notFound("descriptor", descriptor)
            // A raw CCCD write would not register the local listener, so value events would never arrive.
            if (d.uuid == CCCD) {
                val indicate = value.size >= 2 && value[0] == 2.toByte() && value[1] == 0.toByte()
                startNotify(g, d.characteristic, value.any { it != 0.toByte() }, indicate)
            } else {
                writeDescriptorCompat(g, d, value)
            }
        }

    fun requestMtu(mtu: Int, timeoutMs: Long?, result: Result) = enqueue("mtu", timeoutMs, result) { g ->
        if (g.requestMtu(mtu)) Start.Pending() else Start.Fail("gatt_error", "requestMtu failed to start")
    }

    fun readRssi(timeoutMs: Long?, result: Result) = enqueue("rssi", timeoutMs, result) { g ->
        if (g.readRemoteRssi()) Start.Pending() else Start.Fail("gatt_error", "readRemoteRssi failed to start")
    }

    /**
     * Hidden BluetoothGatt.refresh(): drops the OS attribute cache so the next
     * discoverServices reads the database from the peripheral again. Queued so it
     * never runs in the middle of another request.
     */
    fun clearGattCache(timeoutMs: Long?, result: Result) = enqueue("refresh", timeoutMs, result) { g ->
        val ok = try {
            g.javaClass.getMethod("refresh").invoke(g) as? Boolean ?: false
        } catch (e: InvocationTargetException) {
            return@enqueue Start.Fail("not_supported", "refresh() is not available: ${e.targetException?.message}")
        } catch (e: ReflectiveOperationException) {
            return@enqueue Start.Fail("not_supported", "refresh() is blocked on this device (${e.javaClass.simpleName})")
        }
        if (!ok) return@enqueue Start.Fail("gatt_error", "refresh() failed")
        resetServices()
        Start.Done(null)
    }

    /** Not queued: the result arrives later as onPhyUpdate (a `phy` event). */
    fun setPreferredPhy(tx: Int, rx: Int, codedOption: Int, result: Result) {
        val g = gatt
        if (g == null || !connected) return result.error("not_connected", "Device is not connected", null)
        if (Build.VERSION.SDK_INT < 26) return result.success(null)
        if (tx !in 1..7 || rx !in 1..7 || codedOption !in 0..2) {
            return result.error("invalid_argument", "Invalid PHY mask tx=$tx rx=$rx codedOption=$codedOption", null)
        }
        try {
            g.setPreferredPhy(tx, rx, codedOption)
        } catch (e: SecurityException) {
            return result.error("permission_denied", e.message ?: "Missing Bluetooth permission", null)
        }
        result.success(null)
    }

    /** Not queued: it has no callback and the stack accepts it alongside other requests. */
    fun requestConnectionPriority(priority: Int, result: Result) {
        val g = gatt
        if (g == null || !connected) return result.error("not_connected", "Device is not connected", null)
        if (priority !in 0..2) return result.error("invalid_argument", "Unknown connection priority $priority", null)
        val ok = try {
            g.requestConnectionPriority(priority)
        } catch (e: SecurityException) {
            return result.error("permission_denied", e.message ?: "Missing Bluetooth permission", null)
        }
        if (ok) result.success(null) else result.error("gatt_error", "requestConnectionPriority failed", null)
    }

    // ---- queue --------------------------------------------------------------

    /**
     * [timeoutMs] is the Dart-side timeout. The native one runs a little longer so
     * Dart always reports the timeout first; it only frees the queue afterwards.
     */
    private fun enqueue(kind: String, timeoutMs: Long?, result: Result, start: (BluetoothGatt) -> Start) {
        if (!connected) return result.error("not_connected", "Device is not connected", null)
        val native = if (timeoutMs != null && timeoutMs > 0) timeoutMs + TIMEOUT_GRACE_MS else OP_TIMEOUT_MS
        queue.addLast(Op(kind, result, native, start))
        pump()
    }

    fun onBondStateChanged(bondState: Int) {
        bonding = bondState == BluetoothDevice.BOND_BONDING
        if (!bonding) pump()
    }

    private fun pump() {
        while (current == null && !bonding && queue.isNotEmpty()) {
            val op = queue.removeFirst()
            val g = gatt
            if (g == null || !connected) {
                op.result.error("not_connected", "Device is not connected", null)
                continue
            }
            log.log(BleLog.DEBUG) { "${op.kind} on $id" }
            val outcome = try {
                op.start(g)
            } catch (e: SecurityException) {
                Start.Fail("permission_denied", e.message ?: "Missing Bluetooth permission")
            } catch (e: IllegalArgumentException) {
                Start.Fail("invalid_argument", e.message ?: "Invalid argument")
            } catch (e: RuntimeException) {
                // Vendor stacks throw (NPE, DeadObjectException wrappers...); pump also runs
                // from GATT callbacks, where an escaping exception would crash the app.
                Start.Fail("gatt_error", "${op.kind} failed: $e")
            }
            when (outcome) {
                is Start.Pending -> {
                    current = op
                    currentTarget = outcome.target
                    val t = Runnable {
                        if (current === op) finish(op.kind, null) { it.error("timeout", "${op.kind} timed out", null) }
                    }
                    currentTimeout = t
                    handler.postDelayed(t, op.timeoutMs)
                }
                is Start.Done -> op.result.success(outcome.value)
                is Start.Fail -> op.result.error(outcome.code, outcome.message, outcome.status)
            }
        }
    }

    /**
     * Completes the running request if it is of [kind] and, when [target] is
     * given, about that attribute. This drops late callbacks of a request that
     * already timed out instead of completing the next request with them.
     */
    private fun finish(kind: String, target: String?, complete: (Result) -> Unit) {
        val op = current ?: return
        if (op.kind != kind) return
        if (target != null && currentTarget != null && target != currentTarget) return
        current = null
        currentTarget = null
        cancelTimeout()
        complete(op.result)
        pump()
    }

    private fun cancelTimeout() {
        currentTimeout?.let { handler.removeCallbacks(it) }
        currentTimeout = null
    }

    private fun finishStatus(kind: String, target: String?, status: Int, value: Any?) = finish(kind, target) {
        if (status == BluetoothGatt.GATT_SUCCESS) {
            it.success(value)
        } else {
            log.log(BleLog.WARNING) { "$kind on $id failed (status $status)" }
            it.error("gatt_error", "$kind failed (status $status)", status)
        }
    }

    // ---- callbacks (binder thread -> main thread) ---------------------------

    /** Runs [block] on the main thread if [g] is still this session's connection. */
    private fun onMain(g: BluetoothGatt, block: () -> Unit) {
        handler.post { if (g === gatt) block() }
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) = onMain(g) {
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                if (state != State.CONNECTING) return@onMain
                state = State.CONNECTED
                bonding = try {
                    device.bondState == BluetoothDevice.BOND_BONDING
                } catch (_: SecurityException) {
                    false
                }
                log.log(BleLog.INFO) { "Connected to $id" }
                emit(mapOf("type" to "connectionState", "id" to id, "connected" to true))
                connectResult?.success(null)
                connectResult = null
                // Reports the initial PHY as a `phy` event; not a queued ATT request.
                if (Build.VERSION.SDK_INT >= 26) {
                    try {
                        g.readPhy()
                    } catch (_: SecurityException) {
                    }
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
                // Includes the infamous status 133 (GATT_ERROR) on failed connects.
                close(status, "Disconnected (status $status)")
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = onMain(g) {
            finishStatus("discover", null, status, if (status == BluetoothGatt.GATT_SUCCESS) serializeServices(g.services) else null)
        }

        override fun onServiceChanged(g: BluetoothGatt) = onMain(g) {
            log.log(BleLog.INFO) { "Services changed on $id" }
            resetServices()
        }

        override fun onPhyUpdate(g: BluetoothGatt, txPhy: Int, rxPhy: Int, status: Int) = onMain(g) { onPhy(txPhy, rxPhy, status) }

        override fun onPhyRead(g: BluetoothGatt, txPhy: Int, rxPhy: Int, status: Int) = onMain(g) { onPhy(txPhy, rxPhy, status) }

        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int) =
            onMain(g) { onRead(c, value, status) }

        @Deprecated("Used below Android 13")
        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            // The shared value buffer may be overwritten before the post runs.
            @Suppress("DEPRECATION")
            val value = c.value?.copyOf() ?: ByteArray(0)
            onMain(g) { onRead(c, value, status) }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) =
            onMain(g) { finishStatus("write", key(c), status, null) }

        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) =
            onMain(g) { emitValue(c, value) }

        @Deprecated("Used below Android 13")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION")
            val value = c.value?.copyOf() ?: ByteArray(0)
            onMain(g) { emitValue(c, value) }
        }

        override fun onDescriptorRead(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int, value: ByteArray) =
            onMain(g) { finishStatus("descriptorRead", key(d), status, value) }

        @Deprecated("Used below Android 13")
        override fun onDescriptorRead(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) {
            @Suppress("DEPRECATION")
            val value = d.value?.copyOf() ?: ByteArray(0)
            onMain(g) { finishStatus("descriptorRead", key(d), status, value) }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) =
            onMain(g) { finishStatus("descriptorWrite", key(d), status, null) }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) = onMain(g) {
            // Also fires unsolicited (peripheral-initiated exchange, Android 14+ auto MTU).
            if (status == BluetoothGatt.GATT_SUCCESS) {
                emit(mapOf("type" to "mtu", "id" to id, "mtu" to mtu))
            }
            finishStatus("mtu", null, status, mtu)
        }

        override fun onReadRemoteRssi(g: BluetoothGatt, rssi: Int, status: Int) =
            onMain(g) { finishStatus("rssi", null, status, rssi) }
    }

    private fun onRead(c: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
        if (status == BluetoothGatt.GATT_SUCCESS) emitValue(c, value)
        finishStatus("read", key(c), status, value)
    }

    private fun onPhy(tx: Int, rx: Int, status: Int) {
        if (status != BluetoothGatt.GATT_SUCCESS) {
            log.log(BleLog.WARNING) { "PHY update on $id failed (status $status)" }
            return
        }
        emit(mapOf("type" to "phy", "id" to id, "tx" to tx, "rx" to rx))
    }

    /** Hot path (notifications): strings and indices come precomputed from discovery. */
    private fun emitValue(c: BluetoothGattCharacteristic, value: ByteArray) {
        val a = addresses[c]
        log.log(BleLog.VERBOSE) { "Value from $id ${c.uuid}: ${value.size} bytes" }
        emit(
            HashMap<String, Any?>(12).apply {
                put("type", "value")
                put("id", id)
                put("service", a?.service ?: c.service?.uuid?.toString())
                put("serviceIndex", a?.serviceIndex ?: 0)
                put("characteristic", a?.characteristic ?: c.uuid.toString())
                put("characteristicIndex", a?.characteristicIndex ?: 0)
                put("value", value)
            }
        )
    }

    /** The peripheral's database changed (or the cache was dropped): attributes are stale. */
    private fun resetServices() {
        services = emptyList()
        addresses = IdentityHashMap()
        emit(mapOf("type" to "servicesReset", "id" to id))
    }

    // ---- helpers ------------------------------------------------------------

    private fun writeDescriptorCompat(g: BluetoothGatt, d: BluetoothGattDescriptor, value: ByteArray): Start {
        if (Build.VERSION.SDK_INT >= 33) return startStatus("writeDescriptor", g.writeDescriptor(d, value), key(d))
        @Suppress("DEPRECATION")
        d.value = value
        @Suppress("DEPRECATION")
        val ok = g.writeDescriptor(d)
        return if (ok) Start.Pending(key(d)) else Start.Fail("gatt_error", "writeDescriptor failed to start")
    }

    /** Maps the Android 13+ status code returned when starting a write. */
    private fun startStatus(what: String, status: Int, target: String): Start = when (status) {
        BluetoothStatusCodes.SUCCESS -> Start.Pending(target)
        BluetoothStatusCodes.ERROR_GATT_WRITE_REQUEST_BUSY ->
            Start.Fail("busy", "$what rejected: the GATT stack is busy", status)
        BluetoothStatusCodes.ERROR_MISSING_BLUETOOTH_CONNECT_PERMISSION ->
            Start.Fail("permission_denied", "$what requires BLUETOOTH_CONNECT", status)
        else -> Start.Fail("gatt_error", "$what failed to start (status $status)", status)
    }

    /** Resolves the Dart address against the order returned by the last discovery. */
    private fun findCharacteristic(g: BluetoothGatt, t: Target): BluetoothGattCharacteristic? {
        val su = UUID.fromString(t.service)
        val cu = UUID.fromString(t.characteristic)
        val s = services.ifEmpty { g.services }.nth(t.serviceIndex) { it.uuid == su } ?: return null
        return s.characteristics.nth(t.characteristicIndex) { it.uuid == cu }
    }

    private inline fun <T> List<T>.nth(index: Int, match: (T) -> Boolean): T? {
        var n = 0
        for (x in this) if (match(x) && n++ == index) return x
        return null
    }

    private fun notFound(what: String, uuid: String) =
        Start.Fail("not_found", "No $what $uuid (did you call discoverServices?)")

    private fun key(c: BluetoothGattCharacteristic) = "${c.uuid}#${c.instanceId}"

    private fun key(d: BluetoothGattDescriptor) = "${key(d.characteristic)}/${d.uuid}"

    /**
     * Flattens primary and secondary services once each (an included service is
     * referenced by position) and records every characteristic's address.
     */
    private fun serializeServices(roots: List<BluetoothGattService>): List<Map<String, Any?>> {
        val flat = ArrayList<BluetoothGattService>(roots.size)
        val positions = IdentityHashMap<BluetoothGattService, Int>()
        // Included services are normally the same objects; match by handle otherwise.
        fun indexOf(s: BluetoothGattService): Int =
            positions[s] ?: flat.indexOfFirst { it.uuid == s.uuid && it.instanceId == s.instanceId }
        fun add(s: BluetoothGattService) {
            if (indexOf(s) >= 0) return
            positions[s] = flat.size
            flat += s
        }
        roots.forEach(::add)
        var i = 0
        while (i < flat.size) flat[i++].includedServices.forEach(::add)

        val newAddresses = IdentityHashMap<BluetoothGattCharacteristic, Address>()
        val serviceCounts = HashMap<UUID, Int>()
        val out = flat.map { s ->
            val sUuid = s.uuid.toString()
            val sIndex = serviceCounts.merge(s.uuid, 1, Int::plus)!! - 1
            val charCounts = HashMap<UUID, Int>()
            mapOf(
                "uuid" to sUuid,
                "primary" to (s.type == BluetoothGattService.SERVICE_TYPE_PRIMARY),
                "included" to s.includedServices.map(::indexOf).filter { it >= 0 },
                "characteristics" to s.characteristics.map { c ->
                    val cUuid = c.uuid.toString()
                    val cIndex = charCounts.merge(c.uuid, 1, Int::plus)!! - 1
                    newAddresses[c] = Address(sUuid, sIndex, cUuid, cIndex)
                    mapOf(
                        "uuid" to cUuid,
                        "properties" to c.properties,
                        "descriptors" to c.descriptors.map { it.uuid.toString() },
                    )
                },
            )
        }
        services = flat
        addresses = newAddresses
        return out
    }

    companion object {
        /** onConnectionStateChange status: GATT status or HCI disconnect reason. */
        fun reasonText(status: Int): String = when (status) {
            0x00 -> "success"
            0x05 -> "insufficient authentication"
            0x08 -> "connection timeout (supervision timeout)"
            0x13 -> "remote device terminated the connection"
            0x14 -> "remote device terminated: low resources"
            0x15 -> "remote device terminated: power off"
            0x16 -> "connection terminated by the local host"
            0x22 -> "LMP/LL response timeout"
            0x28 -> "instant passed"
            0x3B -> "unacceptable connection parameters"
            0x3D -> "connection terminated: MIC failure"
            0x3E -> "connection failed to be established"
            0x85 -> "GATT_ERROR (generic failure, often a failed or dropped connection)"
            0x100 -> "connection canceled"
            0x101 -> "GATT_FAILURE"
            else -> "unknown (0x${Integer.toHexString(status)})"
        }

        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val OP_TIMEOUT_MS = 15_000L
        private const val TIMEOUT_GRACE_MS = 1_000L
        private const val DISCONNECT_GRACE_MS = 5_000L
    }
}
