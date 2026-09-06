package dev.abhishek.vidfetch

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.FrameLayout
import android.webkit.CookieManager
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient

/**
 * In-app YouTube / Google sign-in. Captures youtube.com + google.com cookies
 * into the shared Netscape cookies.txt once a logged-in session is detected
 * (or when the user taps Done).
 */
class YouTubeLoginActivity : Activity() {
    companion object {
        const val EXTRA_COOKIE_PATH = CookieJar.EXTRA_COOKIE_PATH
        private const val YT_URL = "https://www.youtube.com"
        private const val LOGIN_URL =
            "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com"
        private const val CHROME_UA =
            "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
    }

    private lateinit var webView: WebView
    private var captured = false

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "Sign in to YouTube"

        val root = FrameLayout(this)
        webView = WebView(this)
        val doneHeight = (48 * resources.displayMetrics.density).toInt()
        root.addView(
            webView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ).apply { bottomMargin = doneHeight + 16 },
        )

        val done = Button(this).apply {
            text = "Done — save cookies"
            setOnClickListener { captureAndFinish(force = true) }
        }
        val lp = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM,
        )
        root.addView(done, lp)
        setContentView(root)

        webView.settings.javaScriptEnabled = true
        webView.settings.domStorageEnabled = true
        webView.settings.userAgentString = CHROME_UA
        webView.settings.mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)
        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView?, url: String?) {
                captureAndFinish(force = false)
            }
        }
        webView.loadUrl(LOGIN_URL)
    }

    /**
     * Saves cookies when a logged-in marker is present, or always when
     * [force] is true (user tapped Done).
     */
    private fun captureAndFinish(force: Boolean) {
        if (captured) return
        CookieManager.getInstance().flush()
        val ytCookies = CookieManager.getInstance().getCookie(YT_URL).orEmpty()
        val googleCookies =
            CookieManager.getInstance().getCookie("https://www.google.com").orEmpty()
        val loggedIn = ytCookies.contains("SAPISID=") ||
            ytCookies.contains("LOGIN_INFO=") ||
            ytCookies.contains("__Secure-1PSID=") ||
            googleCookies.contains("SAPISID=") ||
            googleCookies.contains("__Secure-1PSID=")
        if (!force && !loggedIn) return

        captured = true
        val path = CookieJar.mergeFromUrls(
            this,
            listOf(
                YT_URL to ".youtube.com",
                "https://m.youtube.com" to ".youtube.com",
                "https://www.google.com" to ".google.com",
                "https://accounts.google.com" to ".google.com",
            ),
            CookieJar.youtubeReplaceDomains(),
        )
        setResult(Activity.RESULT_OK, Intent().putExtra(EXTRA_COOKIE_PATH, path))
        finish()
    }
}
