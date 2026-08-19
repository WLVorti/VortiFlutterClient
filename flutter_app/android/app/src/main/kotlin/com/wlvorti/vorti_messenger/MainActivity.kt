package com.wlvorti.vorti_messenger

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.wlvorti.vorti_messenger/share"
    }

    private var pendingShare: String? = null
    private var flutterEngine: FlutterEngine? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        this.flutterEngine = flutterEngine
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSharedData" -> result.success(pendingShare)
                "clearSharedData" -> {
                    pendingShare = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        pendingShare?.let { sendToFlutter(it) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        processIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        processIntent(intent)
    }

    private fun processIntent(intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return
        val payload = buildPayload(intent) ?: return
        pendingShare = payload
        sendToFlutter(payload)
    }

    private fun buildPayload(intent: Intent): String? {
        val type = intent.type ?: "*/*"
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        val obj = JSONObject()
        obj.put("mimeType", type)
        if (!text.isNullOrBlank()) obj.put("text", text)
        if (!subject.isNullOrBlank()) obj.put("subject", subject)

        val files = JSONArray()
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            val streams = getStreams(intent)
            for (uri in streams) {
                copyToCache(uri)?.let { files.put(it) }
            }
        } else {
            getStream(intent)?.let { uri ->
                copyToCache(uri)?.let { files.put(it) }
            }
        }

        if (obj.has("text") || files.length() > 0) {
            if (files.length() > 0) obj.put("files", files)
            return obj.toString()
        }
        return null
    }

    private fun getStream(intent: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        }
    }

    private fun getStreams(intent: Intent): List<Uri> {
        return if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) ?: emptyList()
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
        }
    }

    private fun copyToCache(uri: Uri): JSONObject? {
        return try {
            val dir = File(cacheDir, "shared").apply { mkdirs() }
            val displayName = queryDisplayName(uri) ?: "shared_${System.currentTimeMillis()}"
            val target = File(dir, "${System.currentTimeMillis()}_$displayName")
            val stream = contentResolver.openInputStream(uri) ?: return null
            stream.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            }
            if (!target.exists() || target.length() == 0L) return null
            val mime = contentResolver.getType(uri) ?: "*/*"
            JSONObject()
                .put("path", target.absolutePath)
                .put("mimeType", mime)
                .put("name", displayName)
                .put("size", target.length())
        } catch (e: Exception) {
            null
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) cursor.getString(idx) else null
                } else {
                    null
                }
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun sendToFlutter(payload: String) {
        flutterEngine?.let { engine ->
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .invokeMethod("onSharedData", payload)
        }
    }
}
