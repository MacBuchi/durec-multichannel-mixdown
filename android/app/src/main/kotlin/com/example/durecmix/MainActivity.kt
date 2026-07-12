package com.example.durecmix

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Storage Access Framework bridge: DUREC recordings are multi-GB, so they
// are never copied — the picker returns a content URI and the Rust engine
// reads/writes through raw file descriptors opened per call.
class MainActivity : FlutterActivity() {
    private val channelName = "durecmix/saf"
    private var pendingResult: MethodChannel.Result? = null
    private val pickRequest = 41001
    private val createRequest = 41002

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickWav" -> {
                        pendingResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(
                                Intent.EXTRA_MIME_TYPES,
                                arrayOf(
                                    "audio/x-wav",
                                    "audio/wav",
                                    "audio/vnd.wave",
                                    "application/octet-stream",
                                ),
                            )
                        }
                        startActivityForResult(intent, pickRequest)
                    }
                    "createDocument" -> {
                        pendingResult = result
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = call.argument<String>("mime") ?: "audio/x-wav"
                            putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "mix.wav")
                        }
                        startActivityForResult(intent, createRequest)
                    }
                    "openFd" -> {
                        try {
                            val uri = Uri.parse(call.argument<String>("uri"))
                            val mode = call.argument<String>("mode") ?: "r"
                            val pfd = contentResolver.openFileDescriptor(uri, mode)
                            if (pfd == null) {
                                result.error("open_failed", "no file descriptor for $uri", null)
                            } else {
                                // Ownership moves to the Rust side, which
                                // closes it when its File is dropped.
                                result.success(pfd.detachFd())
                            }
                        } catch (e: Exception) {
                            result.error("open_failed", e.message, null)
                        }
                    }
                    "displayName" -> {
                        var name: String? = null
                        try {
                            val uri = Uri.parse(call.argument<String>("uri"))
                            contentResolver.query(uri, null, null, null, null)?.use { c ->
                                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                                if (c.moveToFirst() && idx >= 0) name = c.getString(idx)
                            }
                        } catch (_: Exception) {}
                        result.success(name)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickRequest && requestCode != createRequest) return
        val res = pendingResult ?: return
        pendingResult = null
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri != null && requestCode == pickRequest) {
            // Keep read access across app restarts (session re-open).
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            } catch (_: Exception) {}
        }
        res.success(uri?.toString())
    }
}
