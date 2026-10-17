package com.riccimobile.open_blue_plus

import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanRecord
import android.os.ParcelUuid

/**
 * The `startScan` filters of PROTOCOL.md: six OR-combined lists, then
 * `namePrefix` AND-ed on top. Always checked in software; [nativeFilters]
 * is only a pre-filter for the controller.
 */
internal class ScanMatcher(
    services: List<String>,
    names: List<String>,
    private val keywords: List<String>,
    remoteIds: List<String>,
    manufacturerData: List<Map<*, *>>,
    serviceData: List<Map<*, *>>,
    private val namePrefix: String?,
) {
    private class Masked(val data: ByteArray, val mask: ByteArray?) {
        init {
            require(mask == null || mask.size == data.size) { "mask and data must have the same length" }
        }

        fun matches(payload: ByteArray?): Boolean {
            if (payload == null || payload.size < data.size) return false
            for (i in data.indices) {
                val m = if (mask == null) 0xFF else mask[i].toInt()
                if ((payload[i].toInt() and m) != (data[i].toInt() and m)) return false
            }
            return true
        }
    }

    private val services: Set<ParcelUuid> = services.mapTo(HashSet()) { ParcelUuid.fromString(it) }
    private val names: Set<String> = names.toHashSet()
    private val remoteIds: Set<String> = remoteIds.mapTo(HashSet()) { it.uppercase() }
    private val manufacturer: List<Pair<Int, Masked>> = manufacturerData.map {
        val id = (it["id"] as? Number)?.toInt() ?: throw IllegalArgumentException("manufacturerData needs an id")
        id to masked(it)
    }
    private val serviceData: List<Pair<ParcelUuid, Masked>> = serviceData.map {
        val uuid = it["service"] as? String ?: throw IllegalArgumentException("serviceData needs a service")
        ParcelUuid.fromString(uuid) to masked(it)
    }

    private val anyList = this.services.isNotEmpty() || this.names.isNotEmpty() || keywords.isNotEmpty() ||
        this.remoteIds.isNotEmpty() || manufacturer.isNotEmpty() || this.serviceData.isNotEmpty()

    fun matches(address: String, name: String?, localName: String?, record: ScanRecord?): Boolean {
        val n = name ?: localName
        if (namePrefix != null && (n == null || !n.startsWith(namePrefix))) return false
        if (!anyList) return true
        if (address in remoteIds) return true
        if (n != null) {
            if (n in names) return true
            for (k in keywords) if (n.contains(k)) return true
        }
        if (record == null) return false
        if (services.isNotEmpty()) record.serviceUuids?.let { uuids -> for (u in uuids) if (u in services) return true }
        for ((id, m) in manufacturer) if (m.matches(record.getManufacturerSpecificData(id))) return true
        for ((uuid, m) in serviceData) if (m.matches(record.getServiceData(uuid))) return true
        return false
    }

    /**
     * Equivalent native filters (one per list entry; Android ORs them), or null
     * when none apply. A keyword (substring) cannot be expressed natively, and
     * setDeviceName only sees the advertised name, not the cached `name`.
     */
    fun nativeFilters(): List<ScanFilter>? {
        if (!anyList || keywords.isNotEmpty() || names.isNotEmpty()) return null
        val filters = ArrayList<ScanFilter>()
        services.forEach { filters += ScanFilter.Builder().setServiceUuid(it).build() }
        // An invalid MAC can never match on Android, so it is simply left out.
        remoteIds.filter { BluetoothAdapter.checkBluetoothAddress(it) }
            .forEach { filters += ScanFilter.Builder().setDeviceAddress(it).build() }
        manufacturer.forEach { (id, m) ->
            filters += ScanFilter.Builder().setManufacturerData(id, m.data, m.mask).build()
        }
        serviceData.forEach { (uuid, m) ->
            filters += ScanFilter.Builder().setServiceData(uuid, m.data, m.mask).build()
        }
        return filters.ifEmpty { null }
    }

    private companion object {
        fun masked(m: Map<*, *>) = Masked(m["data"] as? ByteArray ?: ByteArray(0), m["mask"] as? ByteArray)
    }
}
