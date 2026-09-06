package dev.abhishek.vidfetch

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import com.chaquo.python.PyObject
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/** Java-side progress interface; Python calls `callback.onProgress(...)`. */
interface ProgressCallback {
    fun onProgress(taskId: String, payloadJson: String)
}

class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private val executor = Executors.newFixedThreadPool(2)
    private val cancelEvents = ConcurrentHashMap<String, PyObject>()
    private var loginResult: MethodChannel.Result? = null

    companion object {
        private const val IG_LOGIN_REQUEST_CODE = 4242
        private const val YT_LOGIN_REQUEST_CODE = 4243
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(this))
        }

        // One-shot YouTube diagnostics → files/yt_selftest.log (adb pullable).
        executor.execute {
            try {
                val ejsDir = EjsHelper.ensureScriptsDir(this)
                val logFile = File(filesDir, "yt_selftest.log")
                Python.getInstance().getModule("downloader").callAttr(
                    "youtube_selftest",
                    logFile.absolutePath,
                    QjsHelper.ensureQjs(this),
                    FfmpegHelper.ensureFfmpeg(this),
                    CookieJar.cookieFile(this).takeIf { it.exists() }?.absolutePath,
                    ejsDir,
                )
            } catch (_: Exception) {
                // Best-effort diagnostics only.
            }
        }

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vidfetch/ytdlp")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val id = call.argument<String>("id")!!
                    val url = call.argument<String>("url")!!
                    val format = call.argument<String>("format")!!
                    val insecure = call.argument<Boolean>("insecure") ?: false
                    val cookies = call.argument<String>("cookies")
                    startDownload(id, url, format, insecure, cookies)
                    result.success(null)
                }
                "instagramLogin" -> {
                    if (loginResult != null) {
                        result.error("busy", "Login already in progress", null)
                    } else {
                        loginResult = result
                        startActivityForResult(
                            Intent(this, InstagramLoginActivity::class.java),
                            IG_LOGIN_REQUEST_CODE
                        )
                    }
                }
                "youtubeLogin" -> {
                    if (loginResult != null) {
                        result.error("busy", "Login already in progress", null)
                    } else {
                        loginResult = result
                        startActivityForResult(
                            Intent(this, YouTubeLoginActivity::class.java),
                            YT_LOGIN_REQUEST_CODE
                        )
                    }
                }
                "cancel" -> {
                    cancelEvents[call.argument<String>("id")]?.callAttr("set")
                    result.success(null)
                }
                "openUri" -> {
                    result.success(openUri(call.argument<String>("uri")!!))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun stagingDir(): File =
        File(getExternalFilesDir(null), "downloads").apply { mkdirs() }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == IG_LOGIN_REQUEST_CODE ||
            requestCode == YT_LOGIN_REQUEST_CODE
        ) {
            val extra = if (requestCode == IG_LOGIN_REQUEST_CODE) {
                InstagramLoginActivity.EXTRA_COOKIE_PATH
            } else {
                YouTubeLoginActivity.EXTRA_COOKIE_PATH
            }
            val path = if (resultCode == RESULT_OK) {
                data?.getStringExtra(extra)
            } else null
            loginResult?.success(path)
            loginResult = null
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun startDownload(
        id: String,
        url: String,
        format: String,
        insecure: Boolean,
        cookies: String?,
    ) {
        val py = Python.getInstance()
        val cancelEvent = py.getModule("threading").callAttr("Event")
        cancelEvents[id] = cancelEvent

        val progressCallback = object : ProgressCallback {
            override fun onProgress(taskId: String, payloadJson: String) {
                runOnUiThread {
                    channel.invokeMethod(
                        "progress",
                        mapOf("id" to taskId, "payload" to payloadJson)
                    )
                }
            }
        }

        executor.execute {
            val ffmpegPath = FfmpegHelper.ensureFfmpeg(this)
            val qjsPath = QjsHelper.ensureQjs(this)
            val ejsDir = EjsHelper.ensureScriptsDir(this)
            val resultJson = try {
                py.getModule("downloader")
                    .callAttr(
                        "download",
                        id,
                        url,
                        stagingDir().absolutePath,
                        format,
                        cancelEvent,
                        progressCallback,
                        insecure,
                        cookies,
                        ffmpegPath,
                        qjsPath,
                        ejsDir,
                    )
                    .toString()
            } catch (e: Exception) {
                JSONObject()
                    .put("success", false)
                    .put("error", e.message ?: "Python error")
                    .toString()
            }
            cancelEvents.remove(id)

            val parsed = JSONObject(resultJson)
            // Move finished files into the public Downloads/VidFetch folder so
            // the user can see them outside the app (app dir is not browsable
            // on Android 11+). Profile/playlist downloads may stage many files.
            if (parsed.optBoolean("success")) {
                val stagedPaths = mutableListOf<String>()
                val arr = parsed.optJSONArray("filePaths")
                if (arr != null) {
                    for (i in 0 until arr.length()) {
                        val p = arr.optString(i, "")
                        if (p.isNotEmpty()) stagedPaths.add(p)
                    }
                }
                if (stagedPaths.isEmpty()) {
                    val single = parsed.optString("filePath", "")
                    if (single.isNotEmpty()) stagedPaths.add(single)
                }

                val exportedPaths = JSONArray()
                val exportedUris = JSONArray()
                var firstDisplay: String? = null
                var firstUri: String? = null
                var lastExportError: String? = null

                for (staged in stagedPaths) {
                    try {
                        val source = File(staged)
                        val uri = exportToDownloads(source)
                        val display =
                            "${Environment.DIRECTORY_DOWNLOADS}/VidFetch/${source.name}"
                        exportedPaths.put(display)
                        exportedUris.put(uri.toString())
                        if (firstDisplay == null) {
                            firstDisplay = display
                            firstUri = uri.toString()
                        }
                    } catch (e: Exception) {
                        lastExportError = e.message ?: "export failed"
                    }
                }

                if (firstDisplay != null) {
                    parsed.put("filePath", firstDisplay)
                    parsed.put("uri", firstUri)
                    parsed.put("filePaths", exportedPaths)
                    parsed.put("uris", exportedUris)
                    parsed.put("fileCount", exportedPaths.length())
                }
                if (lastExportError != null && exportedPaths.length() == 0) {
                    parsed.put("success", false)
                    parsed.put("error", lastExportError)
                } else if (lastExportError != null) {
                    parsed.put("exportError", lastExportError)
                }
            }

            runOnUiThread {
                channel.invokeMethod(
                    "complete",
                    mapOf("id" to id, "payload" to parsed.toString())
                )
            }
        }
    }

    /** Copies a staged file into MediaStore Downloads/VidFetch and deletes the original. */
    private fun exportToDownloads(source: File): Uri {
        val ext = source.extension.lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "application/octet-stream"
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, source.name)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/VidFetch")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val resolver = contentResolver
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("MediaStore insert failed")
        resolver.openOutputStream(uri).use { out ->
            source.inputStream().use { it.copyTo(out!!) }
        }
        values.clear()
        values.put(MediaStore.Downloads.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        source.delete()
        return uri
    }

    private fun openUri(uriString: String): Boolean {
        return try {
            val uri = Uri.parse(uriString)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, contentResolver.getType(uri) ?: "video/*")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
