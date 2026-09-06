package dev.abhishek.vidfetch

import android.content.Context
import android.webkit.CookieManager
import java.io.File

/**
 * Shared Netscape cookies.txt used by yt-dlp for all sites.
 * Instagram and YouTube WebView logins merge into this one file so a single
 * `--cookies` path covers both.
 */
object CookieJar {
    const val EXTRA_COOKIE_PATH = "cookie_path"

    /** Domains whose cookies should be replaced when refreshing Instagram. */
    private val INSTAGRAM_DOMAINS = setOf(".instagram.com", "instagram.com")

    /** Domains whose cookies should be replaced when refreshing YouTube/Google. */
    private val YOUTUBE_DOMAINS = setOf(
        ".youtube.com", "youtube.com",
        ".google.com", "google.com",
        ".googleapis.com", "googleapis.com",
        ".gstatic.com", "gstatic.com",
        ".youtube-nocookie.com", "youtube-nocookie.com",
        "accounts.google.com", ".accounts.google.com",
    )

    fun cookieFile(context: Context): File =
        File(File(context.filesDir, "cookies").apply { mkdirs() }, "cookies.txt")

    /**
     * Writes [cookieHeader] pairs for [domain] into the shared jar, replacing
     * any existing rows for [replaceDomains] and keeping everything else.
     */
    fun mergeCookieHeader(
        context: Context,
        cookieHeader: String,
        domain: String,
        replaceDomains: Set<String>,
    ): String {
        val expiry = System.currentTimeMillis() / 1000 + 365L * 24 * 3600
        val newLines = mutableListOf<String>()
        for (pair in cookieHeader.split(";")) {
            val idx = pair.indexOf('=')
            if (idx <= 0) continue
            val name = pair.substring(0, idx).trim()
            val value = pair.substring(idx + 1).trim()
            if (name.isEmpty()) continue
            // Netscape: domain, includeSubdomains, path, secure, expiry, name, value
            newLines.add("$domain\tTRUE\t/\tTRUE\t$expiry\t$name\t$value")
        }
        return mergeLines(context, newLines, replaceDomains)
    }

    /**
     * Collects cookies from several URLs via CookieManager and merges them,
     * replacing rows whose domain is in [replaceDomains].
     */
    fun mergeFromUrls(
        context: Context,
        urls: List<Pair<String, String>>, // url -> netscape domain
        replaceDomains: Set<String>,
    ): String {
        val expiry = System.currentTimeMillis() / 1000 + 365L * 24 * 3600
        val newLines = mutableListOf<String>()
        val seen = mutableSetOf<String>() // domain\tname
        for ((url, domain) in urls) {
            val header = CookieManager.getInstance().getCookie(url) ?: continue
            for (pair in header.split(";")) {
                val idx = pair.indexOf('=')
                if (idx <= 0) continue
                val name = pair.substring(0, idx).trim()
                val value = pair.substring(idx + 1).trim()
                if (name.isEmpty()) continue
                val key = "$domain\t$name"
                if (!seen.add(key)) continue
                newLines.add("$domain\tTRUE\t/\tTRUE\t$expiry\t$name\t$value")
            }
        }
        return mergeLines(context, newLines, replaceDomains)
    }

    fun instagramReplaceDomains(): Set<String> = INSTAGRAM_DOMAINS

    fun youtubeReplaceDomains(): Set<String> = YOUTUBE_DOMAINS

    private fun mergeLines(
        context: Context,
        newLines: List<String>,
        replaceDomains: Set<String>,
    ): String {
        val file = cookieFile(context)
        val kept = mutableListOf<String>()
        if (file.exists()) {
            for (line in file.readLines()) {
                val trimmed = line.trim()
                if (trimmed.isEmpty() || trimmed.startsWith("#")) continue
                val parts = trimmed.split('\t')
                if (parts.size < 7) continue
                val domain = parts[0]
                if (replaceDomains.any { domainEquals(domain, it) }) continue
                kept.add(trimmed)
            }
        }
        val sb = StringBuilder("# Netscape HTTP Cookie File\n")
        for (line in kept) sb.append(line).append('\n')
        for (line in newLines) sb.append(line).append('\n')
        file.writeText(sb.toString())
        return file.absolutePath
    }

    private fun domainEquals(a: String, b: String): Boolean {
        val na = a.removePrefix(".").lowercase()
        val nb = b.removePrefix(".").lowercase()
        return na == nb
    }
}
