package com.riccimobile.open_blue_plus

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.os.Handler
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel.Result
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * One Serial Port Profile (RFCOMM) connection over Bluetooth Classic.
 *
 * Many thermal printers (and other serial accessories) have no LE radio at all,
 * so GATT can never reach them. This session presents the serial link as a
 * single GATT-like service, [SERVICE] with one characteristic [CHARACTERISTIC]:
 * `write` sends bytes to the socket, `setNotify(true)` turns the bytes the
 * device sends back into `value` events. The Dart API stays the same, so an
 * app written for LE printers prints on Classic ones unchanged.
 *
 * State lives on the main thread, like [GattSession]. The blocking socket
 * work runs on [io], one task at a time and in order (connect, then writes,
 * then the drain before disconnecting); reading runs on its own thread.
 */
@SuppressLint("MissingPermission")
internal class SppSession(
    private val adapter: BluetoothAdapter,
    override val device: BluetoothDevice,
    private val handler: Handler,
    private val emit: (Map<String, Any?>) -> Unit,
    private val log: BleLog,
    private val onClosed: (DeviceSession) -> Unit,
) : DeviceSession {
    private enum class State { IDLE, CONNECTING, CONNECTED, DISCONNECTING, CLOSED }

    @Volatile
    private var state = State.IDLE

    // Written from the io thread while connecting (so close() can abort a blocking
    // connect), owned by the main thread afterwards.
    @Volatile
    private var socket: BluetoothSocket? = null
    private var output: OutputStream? = null

    @Volatile
    private var notifying = false

    private var connectResult: Result? = null
    private val disconnectResults = mutableListOf<Result>()

    private val io: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "open_blue_plus-spp").apply { isDaemon = true }
    }

    // Touched only on the io thread: how long to wait before closing the socket.
    private var lastWriteAt = 0L
    private var burstBytes = 0L

    override val id: String get() = device.address

    override val connected: Boolean get() = state == State.CONNECTED

    override val transport: String get() = "classic"

    // ---- connection ---------------------------------------------------------

    override fun connect(autoConnect: Boolean, result: Result) {
        when (state) {
            State.CONNECTED -> return result.success(transport)
            State.CONNECTING -> return result.error("busy", "A connection attempt is already in progress", null)
            State.DISCONNECTING -> return result.error("busy", "A disconnection is in progress", null)
            State.CLOSED -> return result.error("connect_failed", "Session closed", null)
            State.IDLE -> Unit
        }
        state = State.CONNECTING
        connectResult = result
        io.execute {
            val outcome = open()
            handler.post { onOpened(outcome) }
        }
    }

    private class Opened(val socket: BluetoothSocket?, val error: String?)

    /**
     * Runs on [io]. Tries the socket kinds that printers in the field need, in
     * order: secure (the standard SDP lookup), insecure (devices that refuse an
     * authenticated link), and RFCOMM channel 1 directly (devices whose SDP
     * record is missing or broken: "read failed, socket might closed").
     */
    private fun open(): Opened {
        // An inquiry in progress makes RFCOMM connects fail or crawl.
        try {
            if (adapter.isDiscovering) adapter.cancelDiscovery()
        } catch (_: SecurityException) {
            // BLUETOOTH_SCAN not granted: connect anyway.
        }
        var lastError = "no socket could be created"
        for ((label, create) in strategies) {
            if (state != State.CONNECTING) return Opened(null, "Connection attempt cancelled")
            val s = try {
                create()
            } catch (e: SecurityException) {
                return Opened(null, e.message ?: "BLUETOOTH_CONNECT permission not granted")
            } catch (e: Exception) {
                lastError = "$label socket: ${e.cause?.message ?: e.message ?: e.javaClass.simpleName}"
                continue
            }
            socket = s
            try {
                log.log(BleLog.DEBUG) { "SPP connect to $id ($label)" }
                s.connect()
                return Opened(s, null)
            } catch (e: IOException) {
                lastError = "$label socket: ${e.message ?: "IOException"}"
                log.log(BleLog.INFO) { "SPP $label connect to $id failed: ${e.message}" }
                closeQuietly(s)
                if (socket === s) socket = null
            } catch (e: SecurityException) {
                closeQuietly(s)
                return Opened(null, e.message ?: "BLUETOOTH_CONNECT permission not granted")
            }
        }
        return Opened(null, lastError)
    }

    private val strategies: List<Pair<String, () -> BluetoothSocket>> = listOf(
        "secure" to { device.createRfcommSocketToServiceRecord(SPP_UUID) },
        "insecure" to { device.createInsecureRfcommSocketToServiceRecord(SPP_UUID) },
        "channel 1" to {
            device.javaClass.getMethod("createRfcommSocket", Int::class.javaPrimitiveType)
                .invoke(device, 1) as BluetoothSocket
        },
    )

    private fun onOpened(o: Opened) {
        val s = o.socket
        if (state != State.CONNECTING) {
            // Cancelled by disconnect() / close() while the socket was opening.
            s?.let(::closeQuietly)
            return
        }
        if (s == null) {
            close(null, "SPP connect failed: ${o.error}")
            return
        }
        val input: InputStream
        try {
            output = s.outputStream
            input = s.inputStream
        } catch (e: IOException) {
            close(null, "SPP streams unavailable: ${e.message}")
            return
        }
        socket = s
        state = State.CONNECTED
        log.log(BleLog.INFO) { "Connected to $id over Classic SPP" }
        // RFCOMM has no ATT MTU; report one so writes without response may carry
        // MTU - 3 = 512 bytes (Dart rejects longer ones).
        emit(mapOf("type" to "mtu", "id" to id, "mtu" to MTU))
        emit(mapOf("type" to "connectionState", "id" to id, "connected" to true))
        connectResult?.success(transport)
        connectResult = null
        startReader(s, input)
    }

    private fun startReader(s: BluetoothSocket, input: InputStream) {
        Thread({
            val buffer = ByteArray(1024)
            var reason = "Connection lost"
            try {
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    if (n > 0 && notifying) {
                        val value = buffer.copyOf(n)
                        handler.post { if (socket === s && connected) emitValue(value) }
                    }
                }
            } catch (e: IOException) {
                reason = "Connection lost: ${e.message}"
            }
            // Also reached when close() shuts the socket: then the session is gone.
            handler.post { if (socket === s && connected) close(null, reason) }
        }, "open_blue_plus-spp-read").apply { isDaemon = true }.start()
    }

    override fun disconnect(result: Result) {
        when (state) {
            State.IDLE, State.CLOSED -> result.success(null)
            State.CONNECTING -> {
                result.success(null)
                close(null, "Connection attempt cancelled")
            }
            State.DISCONNECTING -> disconnectResults.add(result)
            State.CONNECTED -> {
                state = State.DISCONNECTING
                disconnectResults.add(result)
                val s = socket
                // Queued behind the writes already accepted: they all reach the
                // socket first, then the drain wait lets the device take them in.
                io.execute {
                    val wait = drainMs()
                    if (wait > 0) SystemClock.sleep(wait)
                    handler.post { if (socket === s) close(null, "Disconnected") }
                }
                // A write blocked on a device that stopped reading must not hang us.
                handler.postDelayed({ if (socket === s && state == State.DISCONNECTING) close(null, "Disconnected") }, DISCONNECT_GRACE_MS)
            }
        }
    }

    /**
     * write() returns once the bytes are in the stack's buffer, not once the
     * device has them, and closing the socket drops what is still queued: the
     * end of a receipt is lost. Wait in proportion to the bytes just written.
     */
    private fun drainMs(): Long {
        if (lastWriteAt == 0L) return 0
        val elapsed = SystemClock.elapsedRealtime() - lastWriteAt
        val needed = (DRAIN_BASE_MS + burstBytes / DRAIN_BYTES_PER_MS).coerceAtMost(DRAIN_MAX_MS)
        return (needed - elapsed).coerceAtLeast(0)
    }

    override fun close(status: Int?, reason: String) {
        if (state == State.CLOSED) return
        val wasConnected = state == State.CONNECTED || state == State.DISCONNECTING
        state = State.CLOSED
        connectResult?.error("connect_failed", reason, status)
        connectResult = null
        disconnectResults.forEach { it.success(null) }
        disconnectResults.clear()
        notifying = false
        output = null
        socket?.let { s ->
            socket = null
            // Unblocks a pending connect(), read() or write() on the other threads.
            closeQuietly(s)
        }
        io.shutdown()
        if (wasConnected) {
            log.log(BleLog.INFO) { "Disconnected from $id: $reason" }
            emit(mapOf("type" to "connectionState", "id" to id, "connected" to false))
        }
        onClosed(this)
    }

    override fun onBondStateChanged(bondState: Int) = Unit

    // ---- the serial link as one GATT service --------------------------------

    override fun discoverServices(timeoutMs: Long?, result: Result) {
        if (!connected) return notConnected(result)
        result.success(
            listOf(
                mapOf(
                    "uuid" to SERVICE,
                    "primary" to true,
                    "included" to emptyList<Int>(),
                    "characteristics" to listOf(
                        mapOf(
                            "uuid" to CHARACTERISTIC,
                            "properties" to PROPERTIES,
                            "descriptors" to listOf(GattSession.CCCD.toString()),
                        ),
                    ),
                ),
            ),
        )
    }

    override fun write(t: GattSession.Target, value: ByteArray, withoutResponse: Boolean, timeoutMs: Long?, result: Result) {
        if (!connected) return notConnected(result)
        if (!isSerial(t)) return notFound(result, t)
        val out = output ?: return notConnected(result)
        val s = socket
        io.execute {
            val error = try {
                out.write(value)
                out.flush()
                val now = SystemClock.elapsedRealtime()
                // A pause longer than a drain starts a new burst.
                if (now - lastWriteAt > DRAIN_MAX_MS) burstBytes = 0
                burstBytes += value.size
                lastWriteAt = now
                null
            } catch (e: IOException) {
                e.message ?: "IOException"
            }
            handler.post {
                if (error == null) {
                    result.success(null)
                } else {
                    result.error(if (socket === s) "gatt_error" else "not_connected", "SPP write failed: $error", null)
                    if (socket === s && connected) close(null, "Connection lost: $error")
                }
            }
        }
    }

    override fun setNotify(t: GattSession.Target, enable: Boolean, forceIndications: Boolean, timeoutMs: Long?, result: Result) {
        if (!connected) return notConnected(result)
        if (!isSerial(t)) return notFound(result, t)
        if (forceIndications && enable) {
            return result.error("not_supported", "The serial characteristic does not support indications", null)
        }
        notifying = enable
        result.success(null)
    }

    override fun readDescriptor(t: GattSession.Target, descriptor: String, timeoutMs: Long?, result: Result) {
        if (!connected) return notConnected(result)
        if (!isSerial(t) || !isCccd(descriptor)) return notFound(result, t)
        result.success(byteArrayOf(if (notifying) 1 else 0, 0))
    }

    override fun writeDescriptor(t: GattSession.Target, descriptor: String, value: ByteArray, timeoutMs: Long?, result: Result) {
        if (!connected) return notConnected(result)
        if (!isSerial(t) || !isCccd(descriptor)) return notFound(result, t)
        // Rule 3: a CCCD write is setNotify.
        val indicate = value.size >= 2 && value[0] == 2.toByte() && value[1] == 0.toByte()
        setNotify(t, value.any { it != 0.toByte() }, indicate, timeoutMs, result)
    }

    override fun read(t: GattSession.Target, timeoutMs: Long?, result: Result) {
        if (!connected) return notConnected(result)
        result.error("not_supported", "A serial link cannot be read on demand: use setNotify to receive its bytes", null)
    }

    override fun requestMtu(mtu: Int, timeoutMs: Long?, result: Result) {
        if (!connected) return notConnected(result)
        result.success(MTU)
    }

    override fun readRssi(timeoutMs: Long?, result: Result) {
        if (!connected) return notConnected(result)
        result.error("not_supported", "RSSI is not available on a Classic SPP connection", null)
    }

    // Rule 9 and the cache/PHY calls: LE-only concepts, no-ops here.
    override fun requestConnectionPriority(priority: Int, result: Result) {
        if (!connected) return notConnected(result)
        result.success(null)
    }

    override fun clearGattCache(timeoutMs: Long?, result: Result) {
        if (!connected) return notConnected(result)
        result.success(null)
    }

    override fun setPreferredPhy(tx: Int, rx: Int, codedOption: Int, result: Result) {
        if (!connected) return notConnected(result)
        result.success(null)
    }

    // ---- helpers ------------------------------------------------------------

    private fun emitValue(value: ByteArray) {
        log.log(BleLog.VERBOSE) { "Value from $id (SPP): ${value.size} bytes" }
        emit(
            mapOf(
                "type" to "value",
                "id" to id,
                "service" to SERVICE,
                "serviceIndex" to 0,
                "characteristic" to CHARACTERISTIC,
                "characteristicIndex" to 0,
                "value" to value,
            ),
        )
    }

    private fun isSerial(t: GattSession.Target) =
        t.service.equals(SERVICE, ignoreCase = true) && t.serviceIndex == 0 &&
            t.characteristic.equals(CHARACTERISTIC, ignoreCase = true) && t.characteristicIndex == 0

    private fun isCccd(descriptor: String) = descriptor.equals(GattSession.CCCD.toString(), ignoreCase = true)

    private fun notConnected(result: Result) = result.error("not_connected", "Device $id is not connected", null)

    private fun notFound(result: Result, t: GattSession.Target) =
        result.error("not_found", "No characteristic ${t.characteristic} (a Classic SPP device exposes only $CHARACTERISTIC)", null)

    private fun closeQuietly(s: BluetoothSocket) {
        try {
            s.close()
        } catch (_: IOException) {
        }
    }

    companion object {
        /** Serial Port Profile (SDP service class 0x1101). */
        val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805f9b34fb")

        /** The serial link as seen from Dart: service and characteristic 0x1101. */
        const val SERVICE = "00001101-0000-1000-8000-00805f9b34fb"
        const val CHARACTERISTIC = "00001101-0000-1000-8000-00805f9b34fb"

        /** writeWithoutResponse | write | notify. */
        const val PROPERTIES = 0x04 or 0x08 or 0x10

        const val MTU = 515

        private const val DISCONNECT_GRACE_MS = 8_000L
        private const val DRAIN_BASE_MS = 300L
        private const val DRAIN_MAX_MS = 3_000L

        // ~8 KB/s: below what a 115200-baud printer takes in, so the wait errs long.
        private const val DRAIN_BYTES_PER_MS = 8L
    }
}
