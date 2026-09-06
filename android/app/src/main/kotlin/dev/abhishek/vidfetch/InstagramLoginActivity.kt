package dev.abhishek.vidfetch

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient

/**
 * In-app Instagram sign-in. When a `sessionid` cookie appears (login
 * succeeded), cookies are merged into the shared Netscape cookies.txt for
 * yt-dlp and the activity finishes with the file path as its result.
 */
class InstagramLoginActivity : Activity() {
    companion object {
        const val EXTRA_COOKIE_PATH = CookieJar.EXTRA_COOKIE_PATH
        private const val IG_URL = "https://www.instagram.com"
        private const val LOGIN_URL = "$IG_URL/accounts/login/"
    }

    private lateinit var webView: WebView
    private var captured = false

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "Sign in to Instagram"
        webView = WebView(this)
        setContentView(webView)
        webView.settings.javaScriptEnabled = true
        webView.settings.domStorageEnabled = true
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)
        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView?, url: String?) {
                maybeCapture()
            }
        }
        webView.loadUrl(LOGIN_URL)
    }

    /** Finishes with the cookie file once the session cookie shows up. */
    private fun maybeCapture() {
        if (captured) return
        val cookies = CookieManager.getInstance().getCookie(IG_URL) ?: return
        if (!cookies.contains("sessionid=")) return
        captured = true
        CookieManager.getInstance().flush()
        val path = CookieJar.mergeCookieHeader(
            this,
            cookies,
            ".instagram.com",
            CookieJar.instagramReplaceDomains(),
        )
        setResult(Activity.RESULT_OK, Intent().putExtra(EXTRA_COOKIE_PATH, path))
        finish()
    }
}
