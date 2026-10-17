package com.riccimobile.open_blue_plus

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import io.flutter.plugin.common.MethodChannel.Result
import java.lang.reflect.InvocationTargetException

/**
 * createBond / removeBond. Bond state broadcasts are received by the plugin
 * for its whole lifetime and forwarded to [onBondStateChanged]; this class
 * only owns the per-request pairing receivers and timeouts. Main thread only.
 */
@SuppressLint("MissingPermission")
internal class BondManager(
    private val context: Context,
    private val handler: Handler,
    private val log: BleLog,
) {
    private class Waiter(val id: String, val target: Int, val result: Result) {
        var timeout: Runnable? = null
        var pairingReceiver: BroadcastReceiver? = null
    }

    private val waiters = ArrayList<Waiter>()

    fun createBond(device: BluetoothDevice, pin: String?, timeoutMs: Long, result: Result) {
        // Read before add(): a throw after it would leave a waiter whose result the caller already completed.
        val current = device.bondState
        if (current == BluetoothDevice.BOND_BONDED) return result.success(null)
        val id = device.address
        // A second createBond while one is starting would return false: just wait for the same bond.
        val alreadyStarted = waiters.any { it.id == id && it.target == BluetoothDevice.BOND_BONDED }
        val w = add(id, BluetoothDevice.BOND_BONDED, timeoutMs, result)
        if (pin != null) w.pairingReceiver = registerPairing(id, pin)
        if (alreadyStarted || current == BluetoothDevice.BOND_BONDING) return
        val ok = try {
            device.createBond()
        } catch (e: SecurityException) {
            return finish(w) { it.error("permission_denied", e.message ?: "BLUETOOTH_CONNECT permission not granted", null) }
        }
        if (!ok) {
            when (device.bondState) {
                BluetoothDevice.BOND_BONDED -> finish(w) { it.success(null) }
                BluetoothDevice.BOND_BONDING -> Unit
                else -> finish(w) { it.error("bond_failed", "createBond failed to start", null) }
            }
        }
    }

    fun removeBond(device: BluetoothDevice, timeoutMs: Long, result: Result) {
        if (device.bondState == BluetoothDevice.BOND_NONE) return result.success(null)
        val w = add(device.address, BluetoothDevice.BOND_NONE, timeoutMs, result)
        val ok = try {
            device.javaClass.getMethod("removeBond").invoke(device) as? Boolean ?: false
        } catch (e: InvocationTargetException) {
            // BLUETOOTH_CONNECT was checked by the caller: a SecurityException here means a privileged API.
            return finish(w) { it.error("not_supported", "removeBond is not available: ${e.targetException?.message}", null) }
        } catch (e: ReflectiveOperationException) {
            return finish(w) { it.error("not_supported", "removeBond is blocked on this device (${e.javaClass.simpleName})", null) }
        } catch (e: SecurityException) {
            return finish(w) { it.error("not_supported", "removeBond is not available: ${e.message}", null) }
        }
        if (!ok) {
            if (device.bondState == BluetoothDevice.BOND_NONE) finish(w) { it.success(null) }
            else finish(w) { it.error("bond_failed", "removeBond failed", null) }
        }
    }

    fun onBondStateChanged(id: String, state: Int, previous: Int, reason: Int) {
        for (w in waiters.filter { it.id == id }) {
            when {
                state == w.target -> finish(w) { it.success(null) }
                w.target == BluetoothDevice.BOND_BONDED && state == BluetoothDevice.BOND_NONE &&
                    previous == BluetoothDevice.BOND_BONDING ->
                    finish(w) { it.error("bond_failed", "Bonding failed: ${reasonText(reason)}", reason.takeIf { r -> r >= 0 }) }
            }
        }
    }

    /** Adapter off or plugin detached. */
    fun failAll(code: String, message: String) {
        for (w in waiters.toList()) finish(w) { it.error(code, message, null) }
    }

    private fun add(id: String, target: Int, timeoutMs: Long, result: Result): Waiter {
        val w = Waiter(id, target, result)
        waiters += w
        val t = Runnable {
            val what = if (target == BluetoothDevice.BOND_BONDED) "createBond" else "removeBond"
            finish(w) { it.error("timeout", "$what timed out", null) }
        }
        w.timeout = t
        handler.postDelayed(t, timeoutMs)
        return w
    }

    /** Completes [w] exactly once and releases its timeout and receiver. */
    private fun finish(w: Waiter, complete: (Result) -> Unit) {
        if (!waiters.remove(w)) return
        w.timeout?.let { handler.removeCallbacks(it) }
        w.pairingReceiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
            }
        }
        complete(w.result)
    }

    private fun registerPairing(id: String, pin: String): BroadcastReceiver? {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                val device = intent.bluetoothDevice() ?: return
                if (device.address != id) return
                val variant = intent.getIntExtra(BluetoothDevice.EXTRA_PAIRING_VARIANT, -1)
                if (variant != BluetoothDevice.PAIRING_VARIANT_PIN && variant != PAIRING_VARIANT_PIN_16_DIGITS) {
                    log.log(BleLog.INFO) { "Pairing variant $variant for $id needs the system dialog" }
                    return
                }
                val ok = try {
                    device.setPin(pin.toByteArray(Charsets.UTF_8))
                } catch (e: SecurityException) {
                    log.log(BleLog.WARNING) { "setPin rejected: ${e.message}" }
                    false
                }
                // Hides the system PIN dialog once the PIN was supplied.
                if (ok && isOrderedBroadcast) abortBroadcast()
            }
        }
        val filter = IntentFilter(BluetoothDevice.ACTION_PAIRING_REQUEST).apply {
            priority = IntentFilter.SYSTEM_HIGH_PRIORITY - 1
        }
        return try {
            registerSystemReceiver(context, receiver, filter)
            receiver
        } catch (e: RuntimeException) {
            log.log(BleLog.WARNING) { "Cannot listen for pairing requests: ${e.message}" }
            null
        }
    }

    companion object {
        // Hidden constants of BluetoothDevice.
        private const val PAIRING_VARIANT_PIN_16_DIGITS = 5
        const val EXTRA_REASON = "android.bluetooth.device.extra.REASON"

        fun reasonText(reason: Int) = when (reason) {
            1 -> "authentication failed"
            2 -> "authentication rejected"
            3 -> "authentication canceled"
            4 -> "remote device down"
            5 -> "discovery in progress"
            6 -> "authentication timeout"
            7 -> "too many repeated attempts"
            8 -> "remote device canceled authentication"
            9 -> "bond removed"
            else -> "unknown reason ($reason)"
        }
    }
}
