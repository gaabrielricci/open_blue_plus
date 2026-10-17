package com.riccimobile.open_blue_plus

import android.util.Log

/**
 * Logs to logcat and emits `log` events up to [level]
 * (0 none, 1 error, 2 warning, 3 info, 4 debug, 5 verbose).
 * Messages are lambdas so hot paths build no strings while logging is off.
 */
internal class BleLog(private val emit: (Map<String, Any?>) -> Unit) {
    @Volatile
    var level = 0

    inline fun log(level: Int, message: () -> String) {
        if (level <= this.level) write(level, message())
    }

    fun write(level: Int, message: String) {
        val priority = when (level) {
            ERROR -> Log.ERROR
            WARNING -> Log.WARN
            INFO -> Log.INFO
            DEBUG -> Log.DEBUG
            else -> Log.VERBOSE
        }
        Log.println(priority, TAG, message)
        emit(mapOf("type" to "log", "level" to level, "message" to message))
    }

    companion object {
        const val TAG = "OpenBluePlus"
        const val ERROR = 1
        const val WARNING = 2
        const val INFO = 3
        const val DEBUG = 4
        const val VERBOSE = 5
    }
}
