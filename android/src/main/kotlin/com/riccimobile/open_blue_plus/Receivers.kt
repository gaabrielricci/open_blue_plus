package com.riccimobile.open_blue_plus

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build

/**
 * Bluetooth broadcasts are protected (only the system can send them) but are sent
 * by the Bluetooth process, not system_server, so a RECEIVER_NOT_EXPORTED receiver
 * never gets them (documented in the Android broadcasts guide). Exporting is safe
 * because no app can spoof them.
 */
@SuppressLint("UnspecifiedRegisterReceiverFlag") // the flags only exist from API 33
internal fun registerSystemReceiver(context: Context, receiver: BroadcastReceiver, filter: IntentFilter) {
    if (Build.VERSION.SDK_INT >= 33) {
        context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
    } else {
        context.registerReceiver(receiver, filter)
    }
}

// The typed getParcelableExtra is unreliable on API 33 (fixed in 34).
internal fun Intent.bluetoothDevice(): BluetoothDevice? =
    if (Build.VERSION.SDK_INT >= 34) {
        getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
    } else {
        @Suppress("DEPRECATION")
        getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
    }
