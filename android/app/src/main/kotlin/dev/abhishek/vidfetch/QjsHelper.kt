package dev.abhishek.vidfetch

import android.content.Context
import java.io.File

/**
 * QuickJS for yt-dlp YouTube JS challenges.
 *
 * Must live in [Context.getApplicationInfo.nativeLibraryDir] — Android 10+
 * W^X forbids executing binaries written to filesDir (PermissionError 13).
 */
object QjsHelper {
    private const val NATIVE_LIB_NAME = "libqjs.so"

    @Volatile
    private var cachedPath: String? = null

    @Synchronized
    fun ensureQjs(context: Context): String? {
        cachedPath?.let { path ->
            if (File(path).isFile) return path
        }
        val native = File(context.applicationInfo.nativeLibraryDir, NATIVE_LIB_NAME)
        if (!native.isFile) return null
        cachedPath = native.absolutePath
        return cachedPath
    }
}
