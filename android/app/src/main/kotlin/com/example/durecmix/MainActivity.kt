package com.example.durecmix

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
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
    private val pickTreeRequest = 41003

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
                    // Folder access for the in-app WAV browser: pick a tree
                    // once (persisted grant, READ|WRITE — write is what phone
                    // batch export will need), then list its .wav children.
                    "pickDirectory" -> {
                        pendingResult = result
                        startActivityForResult(
                            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE),
                            pickTreeRequest,
                        )
                    }
                    "listDirectory" -> {
                        val treeUri = Uri.parse(call.argument<String>("uri"))
                        val main = Handler(Looper.getMainLooper())
                        // USB-OTG providers can take a second to answer —
                        // keep the platform thread free.
                        Thread {
                            try {
                                val entries = listWavChildren(treeUri)
                                main.post { result.success(entries) }
                            } catch (e: Exception) {
                                main.post { result.error("list_failed", e.message, null) }
                            }
                        }.start()
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
                    // Foreground service around a render so Android keeps the
                    // process alive when the app is backgrounded mid-export.
                    "exportStarted", "exportProgress" -> {
                        val intent = Intent(this, ExportService::class.java).apply {
                            action = if (call.method == "exportStarted") {
                                ExportService.ACTION_START
                            } else {
                                ExportService.ACTION_UPDATE
                            }
                            putExtra(
                                ExportService.EXTRA_PROGRESS,
                                call.argument<Int>("progress") ?: 0,
                            )
                            putExtra(ExportService.EXTRA_NAME, call.argument<String>("name"))
                        }
                        startForegroundService(intent)
                        result.success(null)
                    }
                    "exportStopped" -> {
                        startService(
                            Intent(this, ExportService::class.java).apply {
                                action = ExportService.ACTION_STOP
                            },
                        )
                        result.success(null)
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
        if (requestCode != pickRequest && requestCode != createRequest &&
            requestCode != pickTreeRequest
        ) {
            return
        }
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
        if (uri != null && requestCode == pickTreeRequest) {
            // Folder grant survives restarts; WRITE is included so the phone
            // batch export can render into the same folder later.
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            } catch (_: Exception) {}
        }
        res.success(uri?.toString())
    }

    // The tree's direct children that look like WAV files, by NAME — USB
    // sticks report application/octet-stream, so MIME is useless here.
    private fun listWavChildren(treeUri: Uri): List<Map<String, Any?>> {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )
        val entries = mutableListOf<Map<String, Any?>>()
        contentResolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            ),
            null, null, null,
        )?.use { c ->
            while (c.moveToNext()) {
                val name = c.getString(1) ?: continue
                if (!name.lowercase().endsWith(".wav")) continue
                val docUri = DocumentsContract.buildDocumentUriUsingTree(
                    treeUri,
                    c.getString(0),
                )
                entries.add(
                    mapOf(
                        "uri" to docUri.toString(),
                        "name" to name,
                        "size" to c.getLong(2),
                        "modified" to c.getLong(3),
                    ),
                )
            }
        }
        return entries
    }
}
