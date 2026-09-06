package dev.abhishek.vidfetch

import android.content.Context
import java.io.File

/** Extracts bundled yt-dlp-ejs solver scripts into app storage. */
object EjsHelper {
    private const val ASSET_DIR = "ejs"

    fun ensureScriptsDir(context: Context): String? {
        return try {
            val outDir = File(context.filesDir, "ejs").apply { mkdirs() }
            for (name in listOf("lib.min.js", "core.min.js")) {
                val out = File(outDir, name)
                context.assets.open("$ASSET_DIR/$name").use { input ->
                    out.outputStream().use { output -> input.copyTo(output) }
                }
            }
            outDir.absolutePath
        } catch (_: Exception) {
            null
        }
    }
}
