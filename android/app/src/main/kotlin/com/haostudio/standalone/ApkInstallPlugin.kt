package com.haostudio.standalone

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * APK self-update installer — the native half of
 * lib/services/apk_update_installer.dart.
 *
 * Dart downloads the APK into the app cache (`updates/`, covered by
 * the FileProvider paths in res/xml/file_paths.xml) and calls
 * `installApk` with its absolute path. This side fires ACTION_VIEW
 * with a FileProvider content URI
 * (application/vnd.android.package-archive) so the system installer
 * takes over; the user confirms the install there. The system checks
 * REQUEST_INSTALL_PACKAGES itself — if the app is not yet allowed to
 * install unknown apps, the system shows the allow-once settings
 * screen instead of the installer, and the user enables it there.
 *
 * No new dependencies: framework Intent + androidx FileProvider only.
 * The provider is declared in AndroidManifest.xml (authorities
 * "${applicationId}.fileprovider", paths in res/xml/file_paths.xml).
 * ActivityAware: the install intent must start from the Activity.
 */
class ApkInstallPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    ActivityAware {

    companion object {
        const val CHANNEL = "com.haostudio.standalone/apk_install"
        private const val TAG = "HaoApkInstall"
    }

    private var channel: MethodChannel? = null
    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(
        binding: ActivityPluginBinding,
    ) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "installApk") {
            result.notImplemented()
            return
        }
        val args = call.arguments as? Map<*, *>
        val path = args?.get("path") as? String
        if (path.isNullOrEmpty()) {
            result.error("bad_args", "installApk needs a path", null)
            return
        }
        result.success(installApk(path))
    }

    private fun installApk(path: String): Boolean {
        val activity = activity ?: return false
        val file = File(path)
        if (!file.exists()) return false
        return try {
            val uri: Uri = FileProvider.getUriForFile(
                activity,
                "${activity.packageName}.fileprovider",
                file,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "no installer activity", e)
            false
        } catch (e: Exception) {
            Log.w(TAG, "installApk failed", e)
            false
        }
    }
}
