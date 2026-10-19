package com.riccimobile.open_blue_plus

import android.bluetooth.BluetoothDevice
import io.flutter.plugin.common.MethodChannel.Result

/**
 * One connection to a peripheral, whatever the transport.
 *
 * [GattSession] talks GATT over LE. [SppSession] talks the Serial Port Profile
 * over Bluetooth Classic (RFCOMM) and presents it as one GATT-like service, so
 * the Dart API is the same for both (see PROTOCOL.md, "Classic SPP on Android").
 * Every method is called on the main thread.
 */
internal interface DeviceSession {
    val device: BluetoothDevice
    val id: String
    val connected: Boolean

    /** `"le"` or `"classic"`: returned by `connect`. */
    val transport: String

    fun connect(autoConnect: Boolean, result: Result)
    fun disconnect(result: Result)

    /** Releases the connection and completes every pending request. */
    fun close(status: Int?, reason: String)

    fun onBondStateChanged(bondState: Int)

    fun discoverServices(timeoutMs: Long?, result: Result)
    fun read(t: GattSession.Target, timeoutMs: Long?, result: Result)
    fun write(t: GattSession.Target, value: ByteArray, withoutResponse: Boolean, timeoutMs: Long?, result: Result)
    fun setNotify(t: GattSession.Target, enable: Boolean, forceIndications: Boolean, timeoutMs: Long?, result: Result)
    fun readDescriptor(t: GattSession.Target, descriptor: String, timeoutMs: Long?, result: Result)
    fun writeDescriptor(t: GattSession.Target, descriptor: String, value: ByteArray, timeoutMs: Long?, result: Result)
    fun requestMtu(mtu: Int, timeoutMs: Long?, result: Result)
    fun readRssi(timeoutMs: Long?, result: Result)
    fun requestConnectionPriority(priority: Int, result: Result)
    fun clearGattCache(timeoutMs: Long?, result: Result)
    fun setPreferredPhy(tx: Int, rx: Int, codedOption: Int, result: Result)
}
