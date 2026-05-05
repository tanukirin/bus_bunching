package com.tanukirin.bus_bunching_mobile

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.StandardCharsets

class MainActivity : FlutterActivity() {
    private val channelName = "bus_bunching_mobile/files"
    private val saveRequest = 7301
    private val openRequest = 7302
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingOpenResult: MethodChannel.Result? = null
    private var pendingSaveContent: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveText" -> {
                    val fileName = call.argument<String>("fileName") ?: "bus-bunching-export.txt"
                    val mimeType = call.argument<String>("mimeType") ?: "text/plain"
                    val content = call.argument<String>("content") ?: ""
                    saveText(fileName, mimeType, content, result)
                }
                "openText" -> openText(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun saveText(fileName: String, mimeType: String, content: String, result: MethodChannel.Result) {
        if (pendingSaveResult != null) {
            result.error("busy", "Another save request is already active", null)
            return
        }
        pendingSaveResult = result
        pendingSaveContent = content
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        startActivityForResult(intent, saveRequest)
    }

    private fun openText(result: MethodChannel.Result) {
        if (pendingOpenResult != null) {
            result.error("busy", "Another open request is already active", null)
            return
        }
        pendingOpenResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        startActivityForResult(intent, openRequest)
    }

    @Deprecated("Deprecated in Android API, retained for a small no-dependency bridge.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            saveRequest -> finishSave(resultCode, data?.data)
            openRequest -> finishOpen(resultCode, data?.data)
        }
    }

    private fun finishSave(resultCode: Int, uri: Uri?) {
        val result = pendingSaveResult ?: return
        val content = pendingSaveContent ?: ""
        pendingSaveResult = null
        pendingSaveContent = null
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(false)
            return
        }
        try {
            contentResolver.openOutputStream(uri)?.use { stream ->
                stream.write(content.toByteArray(StandardCharsets.UTF_8))
            }
            result.success(true)
        } catch (error: Exception) {
            result.error("save_failed", error.message, null)
        }
    }

    private fun finishOpen(resultCode: Int, uri: Uri?) {
        val result = pendingOpenResult ?: return
        pendingOpenResult = null
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            val text = contentResolver.openInputStream(uri)?.use { stream ->
                stream.readBytes().toString(StandardCharsets.UTF_8)
            }
            result.success(text)
        } catch (error: Exception) {
            result.error("open_failed", error.message, null)
        }
    }
}
