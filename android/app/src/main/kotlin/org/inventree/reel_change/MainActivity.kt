package org.inventree.reel_change

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Native bridge for the few device features the app needs
 * (avoids adding plugin packages). See lib/core/device.dart.
 *
 * Zebra DataWedge: scans are delivered as a broadcast intent
 * ([ACTION_SCAN]) by a DataWedge profile for this app, and forwarded to Dart
 * on the scans event channel. The receiver is only registered while the app
 * is in the foreground AND the Dart side is listening (scanner set to
 * DataWedge in the settings).
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val DEVICE_CHANNEL = "org.inventree.reel_change/device"
        private const val SCAN_CHANNEL = "org.inventree.reel_change/scans"

        const val ACTION_SCAN = "org.inventree.reel_change.SCAN"

        private const val DATAWEDGE_PACKAGE = "com.symbol.datawedge"
        private const val DATAWEDGE_PROFILE = "Reel Change"
        private const val DATAWEDGE_API_ACTION = "com.symbol.datawedge.api.ACTION"
        private const val DATAWEDGE_SET_CONFIG = "com.symbol.datawedge.api.SET_CONFIG"
        private const val DATAWEDGE_DATA = "com.symbol.datawedge.data_string"
        private const val DATAWEDGE_BROADCAST = "2"

        // Far longer than any part label; anything bigger is dropped
        private const val MAX_SCAN_LENGTH = 4096
    }

    private var scanSink: EventChannel.EventSink? = null
    private var resumed = false
    private var receiverRegistered = false

    private val scanReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != ACTION_SCAN) return
            val data = intent.getStringExtra(DATAWEDGE_DATA) ?: return
            if (data.isEmpty() || data.length > MAX_SCAN_LENGTH) return
            scanSink?.success(data)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SCAN_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    scanSink = events
                    updateReceiver()
                }

                override fun onCancel(arguments: Any?) {
                    scanSink = null
                    updateReceiver()
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Keep the screen on while a reel swap is in progress
                    "setKeepScreenOn" -> {
                        val on = call.arguments as? Boolean ?: false
                        runOnUiThread {
                            if (on) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            }
                        }
                        result.success(null)
                    }

                    "appInfo" -> {
                        try {
                            val info = packageManager.getPackageInfo(packageName, 0)
                            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                info.longVersionCode
                            } else {
                                @Suppress("DEPRECATION")
                                info.versionCode.toLong()
                            }
                            result.success(mapOf("versionName" to info.versionName, "versionCode" to code))
                        } catch (e: Exception) {
                            result.error("unavailable", e.message, null)
                        }
                    }

                    "dataWedgeInstalled" -> result.success(dataWedgeInstalled())

                    "configureDataWedge" -> {
                        if (!dataWedgeInstalled()) {
                            result.success(false)
                        } else {
                            try {
                                configureDataWedge()
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("datawedge", e.message, null)
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        scanSink = null
        updateReceiver()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        updateReceiver()
    }

    override fun onPause() {
        resumed = false
        updateReceiver()
        super.onPause()
    }

    /** Receive scans only while in the foreground and Dart is listening. */
    private fun updateReceiver() {
        val want = resumed && scanSink != null

        if (want && !receiverRegistered) {
            val filter = IntentFilter(ACTION_SCAN)
            // DataWedge is another app, so the receiver must be exported
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(scanReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(scanReceiver, filter)
            }
            receiverRegistered = true
        } else if (!want && receiverRegistered) {
            try {
                unregisterReceiver(scanReceiver)
            } catch (_: IllegalArgumentException) {
                // Not registered
            }
            receiverRegistered = false
        }
    }

    private fun dataWedgeInstalled(): Boolean = try {
        packageManager.getPackageInfo(DATAWEDGE_PACKAGE, 0)
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    /**
     * Create (if it does not exist) a DataWedge profile for this app which
     * sends scans as a broadcast intent, with keystroke output off.
     */
    private fun configureDataWedge() {
        val profile = Bundle().apply {
            putString("PROFILE_NAME", DATAWEDGE_PROFILE)
            putString("PROFILE_ENABLED", "true")
            putString("CONFIG_MODE", "CREATE_IF_NOT_EXIST")
            putParcelableArray(
                "APP_LIST",
                arrayOf(Bundle().apply {
                    putString("PACKAGE_NAME", packageName)
                    putStringArray("ACTIVITY_LIST", arrayOf("*"))
                }),
            )
        }

        fun plugin(name: String, params: Bundle) = Bundle().apply {
            putString("PLUGIN_NAME", name)
            putString("RESET_CONFIG", "true")
            putBundle("PARAM_LIST", params)
        }

        profile.putParcelableArrayList(
            "PLUGIN_CONFIG",
            arrayListOf(
                plugin("BARCODE", Bundle().apply {
                    putString("scanner_input_enabled", "true")
                    putString("scanner_selection", "auto")
                }),
                plugin("INTENT", Bundle().apply {
                    putString("intent_output_enabled", "true")
                    putString("intent_action", ACTION_SCAN)
                    putString("intent_delivery", DATAWEDGE_BROADCAST)
                }),
                plugin("KEYSTROKE", Bundle().apply {
                    putString("keystroke_output_enabled", "false")
                }),
            ),
        )

        sendBroadcast(
            Intent(DATAWEDGE_API_ACTION).apply {
                setPackage(DATAWEDGE_PACKAGE)
                putExtra(DATAWEDGE_SET_CONFIG, profile)
            },
        )
    }
}
