package com.haostudio.standalone

import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Device info shell — the native half of lib/services/android_abi.dart.
 *
 * One method: `getSupportedAbis` returns Build.SUPPORTED_ABIS so the
 * in-app updater can download the per-ABI APK matching the device
 * (P1-A1: `flutter build apk --split-per-abi` ships one APK per ABI).
 * No new dependencies: framework Build only.
 */
class DeviceInfoPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.haostudio.standalone/device_info"
    }

    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "getSupportedAbis") {
            result.notImplemented()
            return
        }
        result.success(Build.SUPPORTED_ABIS.toList())
    }
}
