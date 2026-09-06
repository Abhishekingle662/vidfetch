package dev.abhishek.vidfetch

import android.content.Context
import java.io.File

/**
 * Bundled ffmpeg for yt-dlp A/V merges.
 *
 * Must live in nativeLibraryDir — Android 10+ blocks exec from filesDir.
 */
object FfmpegHelper {
    private const val NATIVE_LIB_NAME = "libffmpeg.so"

    @Volatile
    private var cachedPath: String? = null

    @Synchronized
    fun ensureFfmpeg(context: Context): String? {
        cachedPath?.let { path ->
            if (File(path).isFile) return path
        }
        val native = File(context.applicationInfo.nativeLibraryDir, NATIVE_LIB_NAME)
        if (!native.isFile) return null
        cachedPath = native.absolutePath
        return cachedPath
    }
}
