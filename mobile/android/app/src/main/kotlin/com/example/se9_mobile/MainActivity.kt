package com.example.se9_mobile

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var pendingExport: MethodChannel.Result? = null
    private var exportSource: File? = null
    private val exportRequest = 7301

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "se9/file_export").setMethodCallHandler { call, result ->
            if (call.method != "export") { result.notImplemented(); return@setMethodCallHandler }
            if (pendingExport != null) { result.error("EXPORT_BUSY", "Another export is active", null); return@setMethodCallHandler }
            val source = call.argument<String>("path")?.let { File(it).canonicalFile }
            val roots = listOf(filesDir.canonicalPath + File.separator, cacheDir.canonicalPath + File.separator)
            if (source == null || !source.isFile || roots.none { source.path.startsWith(it) }) {
                result.error("INVALID_PATH", "Export source unavailable", null); return@setMethodCallHandler
            }
            pendingExport = result
            exportSource = source
            val name = call.argument<String>("name")?.substringAfterLast('/') ?: source.name
            try {
                startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/octet-stream"
                    putExtra(Intent.EXTRA_TITLE, name)
                }, exportRequest)
            } catch (error: Exception) {
                pendingExport = null; exportSource = null
                result.error("EXPORT_FAILED", error.message, null)
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != exportRequest) return
        val result = pendingExport ?: return
        val source = exportSource
        val uri = data?.data
        pendingExport = null; exportSource = null
        if (resultCode != Activity.RESULT_OK || uri == null || source == null) { result.success(null); return }
        Thread {
            try {
                source.inputStream().use { input ->
                    val output = contentResolver.openOutputStream(uri, "wt") ?: error("Destination unavailable")
                    output.use { input.copyTo(it, 64 * 1024) }
                }
                runOnUiThread { result.success(uri.toString()) }
            } catch (error: Exception) {
                runOnUiThread { result.error("EXPORT_FAILED", error.message, null) }
            }
        }.start()
    }
}
