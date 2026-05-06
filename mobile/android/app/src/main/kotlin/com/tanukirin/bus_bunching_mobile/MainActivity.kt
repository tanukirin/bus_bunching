package com.tanukirin.bus_bunching_mobile

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.FileNotFoundException
import java.nio.charset.StandardCharsets
import java.util.UUID

class MainActivity : FlutterActivity() {
    private val channelName = "bus_bunching_mobile/files"
    private val saveRequest = 7301
    private val exportPrefsName = "bus_bunching_exports"
    private val exportRecordsKey = "records"
    private val maxExportRecords = 100
    private var pendingSave: PendingSave? = null

    private class PendingSave(
        val result: MethodChannel.Result,
        val kind: String,
        val fileName: String,
        val mimeType: String,
        val content: String,
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveText" -> {
                    val kind = call.argument<String>("kind") ?: "comparisonResults"
                    val fileName = call.argument<String>("fileName") ?: "bus-bunching-export.txt"
                    val mimeType = call.argument<String>("mimeType") ?: "text/plain"
                    val content = call.argument<String>("content") ?: ""
                    saveText(kind, fileName, mimeType, content, result)
                }
                "listExports" -> result.success(recordsToList(loadRecords()))
                "readExport" -> {
                    val recordId = call.argument<String>("recordId")
                    readExport(recordId, result)
                }
                "forgetExport" -> {
                    val recordId = call.argument<String>("recordId")
                    forgetExport(recordId)
                    result.success(null)
                }
                "deleteExport" -> {
                    val recordId = call.argument<String>("recordId")
                    deleteExport(recordId, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun saveText(kind: String, fileName: String, mimeType: String, content: String, result: MethodChannel.Result) {
        if (pendingSave != null) {
            result.error("busy", "Another save request is already active", null)
            return
        }
        pendingSave = PendingSave(result, kind, fileName, mimeType, content)
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        startActivityForResult(intent, saveRequest)
    }

    @Deprecated("Deprecated in Android API, retained for a small no-dependency bridge.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            saveRequest -> finishSave(resultCode, data)
        }
    }

    private fun finishSave(resultCode: Int, data: Intent?) {
        val save = pendingSave ?: return
        pendingSave = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            save.result.success(null)
            return
        }
        try {
            contentResolver.openOutputStream(uri)?.use { stream ->
                stream.write(save.content.toByteArray(StandardCharsets.UTF_8))
            } ?: throw IllegalStateException("Could not open output stream")
            persistFilePermission(uri, data)
            val record = JSONObject()
                .put("id", UUID.randomUUID().toString())
                .put("kind", save.kind)
                .put("fileName", save.fileName)
                .put("mimeType", save.mimeType)
                .put("uri", uri.toString())
                .put("savedAtMillis", System.currentTimeMillis())
            addRecord(record)
            save.result.success(recordToMap(record))
        } catch (error: Exception) {
            save.result.error("save_failed", error.message, null)
        }
    }

    private fun readExport(recordId: String?, result: MethodChannel.Result) {
        val record = findRecord(recordId)
        if (record == null) {
            result.error("export_not_found", "Saved file history entry was not found", null)
            return
        }
        try {
            val uri = Uri.parse(record.optString("uri"))
            val text = contentResolver.openInputStream(uri)?.use { stream ->
                stream.readBytes().toString(StandardCharsets.UTF_8)
            } ?: throw IllegalStateException("Could not open input stream")
            result.success(text)
        } catch (error: Exception) {
            result.error("read_failed", error.message, null)
        }
    }

    private fun persistFilePermission(uri: Uri, data: Intent) {
        val requestedFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        val grantedFlags = data.flags and requestedFlags
        val flags = if (grantedFlags != 0) grantedFlags else requestedFlags
        try {
            contentResolver.takePersistableUriPermission(uri, flags)
        } catch (_: SecurityException) {
        } catch (_: IllegalArgumentException) {
        }
    }

    private fun loadRecords(): JSONArray {
        val raw = getSharedPreferences(exportPrefsName, Context.MODE_PRIVATE)
            .getString(exportRecordsKey, "[]") ?: "[]"
        return try {
            JSONArray(raw)
        } catch (_: Exception) {
            JSONArray()
        }
    }

    private fun saveRecords(records: JSONArray) {
        getSharedPreferences(exportPrefsName, Context.MODE_PRIVATE)
            .edit()
            .putString(exportRecordsKey, records.toString())
            .apply()
    }

    private fun addRecord(record: JSONObject) {
        val current = loadRecords()
        val next = JSONArray().put(record)
        for (index in 0 until current.length()) {
            if (next.length() >= maxExportRecords) break
            val existing = current.optJSONObject(index) ?: continue
            next.put(existing)
        }
        saveRecords(next)
    }

    private fun findRecord(recordId: String?): JSONObject? {
        if (recordId == null) return null
        val records = loadRecords()
        for (index in 0 until records.length()) {
            val record = records.optJSONObject(index) ?: continue
            if (record.optString("id") == recordId) return record
        }
        return null
    }

    private fun forgetExport(recordId: String?) {
        if (recordId == null) return
        val records = loadRecords()
        val next = JSONArray()
        for (index in 0 until records.length()) {
            val record = records.optJSONObject(index) ?: continue
            if (record.optString("id") != recordId) next.put(record)
        }
        saveRecords(next)
    }

    private fun deleteExport(recordId: String?, result: MethodChannel.Result) {
        val record = findRecord(recordId)
        if (record == null) {
            result.success(false)
            return
        }
        val uri = Uri.parse(record.optString("uri"))
        try {
            val deleted = DocumentsContract.deleteDocument(contentResolver, uri)
            if (!deleted) {
                result.error("delete_failed", "The file provider did not delete this document", null)
                return
            }
            releaseFilePermission(uri)
            forgetExport(recordId)
            result.success(true)
        } catch (_: FileNotFoundException) {
            forgetExport(recordId)
            result.success(false)
        } catch (error: Exception) {
            result.error("delete_failed", error.message, null)
        }
    }

    private fun releaseFilePermission(uri: Uri) {
        try {
            contentResolver.releasePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        } catch (_: SecurityException) {
        } catch (_: IllegalArgumentException) {
        }
    }

    private fun recordsToList(records: JSONArray): List<Map<String, Any>> =
        List(records.length()) { index -> records.optJSONObject(index) }
            .filterNotNull()
            .map { recordToMap(it) }

    private fun recordToMap(record: JSONObject): Map<String, Any> = mapOf(
        "id" to record.optString("id"),
        "kind" to record.optString("kind"),
        "fileName" to record.optString("fileName"),
        "mimeType" to record.optString("mimeType"),
        "savedAtMillis" to record.optLong("savedAtMillis"),
    )
}
