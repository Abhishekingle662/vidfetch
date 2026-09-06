"""yt-dlp bridge for VidFetch Android.

Runs inside the Chaquopy-embedded CPython. Called from MainActivity on a
background thread; progress is reported back through the Java `callback`
proxy object (ProgressCallback interface).
"""

import json
import os
import pathlib
import tempfile

import yt_dlp

# Ensure JS runtime registry is populated (side-effect of package import).
try:
    from yt_dlp.globals import supported_js_runtimes  # noqa: F401
except Exception:  # noqa: BLE001
    pass


def _patch_quickjs_runtime():
    """Make QuickJS usable on Android.

    yt-dlp treats any stderr from qjs as a hard failure. Some Android builds
    emit harmless stderr (or locale noise), which aborts YouTube challenge
    solving and surfaces as "Requested format is not available".
    """
    try:
        from yt_dlp.extractor.youtube.jsc._builtin import quickjs as qjs_mod
        from yt_dlp.extractor.youtube.jsc.provider import JsChallengeProviderError
        from yt_dlp.utils import Popen
        import shlex
        import subprocess
    except ImportError:
        return
    if getattr(qjs_mod.QuickJSJCP, "_vidfetch_stderr_patch", False):
        return

    def _run_js_runtime(self, stdin: str, /) -> str:
        min_recommended_version = self._QJS_MIN_RECOMMENDED[self.runtime_info.name]
        if self.runtime_info.version_tuple < min_recommended_version:
            self.logger.warning(self._QJS_WARNING_TMPL.format(
                name=self.runtime_info.name,
                version=".".join(map(str, min_recommended_version))))

        # Prefer an app-writable temp dir (Android /tmp is unreliable).
        tmp_dir = os.environ.get("TMPDIR") or None
        temp_file = tempfile.NamedTemporaryFile(
            mode="w",
            suffix=".js",
            delete=False,
            encoding="utf-8",
            dir=tmp_dir,
        )
        try:
            temp_file.write(stdin)
            temp_file.close()
            cmd = [self.runtime_info.path, "--script", temp_file.name]
            self.logger.debug(f"Running QuickJS: {shlex.join(cmd)}")
            with Popen(
                cmd,
                text=True,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            ) as proc:
                stdout, stderr = proc.communicate_or_kill()
                # Only fail on non-zero exit. Ignore stderr when RC==0.
                if proc.returncode:
                    msg = f"Error running QuickJS process (returncode: {proc.returncode})"
                    if stderr:
                        msg = f"{msg}: {stderr.strip()}"
                    raise JsChallengeProviderError(msg)
        finally:
            pathlib.Path(temp_file.name).unlink(missing_ok=True)

        return stdout

    qjs_mod.QuickJSJCP._run_js_runtime = _run_js_runtime
    qjs_mod.QuickJSJCP._vidfetch_stderr_patch = True


_patch_quickjs_runtime()


def _install_ejs_asset_fallback(ejs_dir):
    """Load challenge scripts from extracted Android assets if needed.

    Chaquopy sometimes fails ``importlib.resources`` reads for package data;
    that makes yt-dlp skip EJS and YouTube returns no formats.
    """
    if not ejs_dir or not os.path.isdir(ejs_dir):
        return False
    lib_path = os.path.join(ejs_dir, "lib.min.js")
    core_path = os.path.join(ejs_dir, "core.min.js")
    if not (os.path.isfile(lib_path) and os.path.isfile(core_path)):
        return False
    try:
        from yt_dlp.extractor.youtube.jsc._builtin import ejs as ejs_mod
        from yt_dlp.extractor.youtube.jsc._builtin.ejs import (
            Script,
            ScriptSource,
            ScriptType,
            ScriptVariant,
        )
    except ImportError:
        return False
    if getattr(ejs_mod.EJSBaseJCP, "_vidfetch_ejs_asset_patch", False):
        return True

    lib_code = pathlib.Path(lib_path).read_text(encoding="utf-8")
    core_code = pathlib.Path(core_path).read_text(encoding="utf-8")
    version = "0.8.0"
    try:
        import yt_dlp_ejs
        version = yt_dlp_ejs.version
    except Exception:  # noqa: BLE001
        pass

    def _pypackage_source(self, script_type, /):
        if script_type is ScriptType.CORE:
            return Script(
                script_type,
                ScriptVariant.MINIFIED,
                ScriptSource.PYPACKAGE,
                version,
                core_code,
            )
        return Script(
            script_type,
            ScriptVariant.MINIFIED,
            ScriptSource.PYPACKAGE,
            version,
            lib_code,
        )

    ejs_mod.EJSBaseJCP._pypackage_source = _pypackage_source
    ejs_mod.EJSBaseJCP._vidfetch_ejs_asset_patch = True
    return True


def youtube_selftest(log_path, qjs_location=None, ffmpeg_location=None,
                     cookiefile=None, ejs_dir=None):
    """Write YouTube/JS diagnostics to log_path. Called from MainActivity."""
    lines = []

    def log(msg):
        lines.append(str(msg))

    ejs_patched = _install_ejs_asset_fallback(ejs_dir)
    log(f"ejs_asset_patch={ejs_patched} ejs_dir={ejs_dir}")

    try:
        import yt_dlp as ytdlp_mod
        log(f"yt_dlp={getattr(ytdlp_mod.version, '__version__', '?')}")
        from yt_dlp.globals import supported_js_runtimes
        log(f"js_runtimes_registered={list(supported_js_runtimes.value.keys())}")
    except Exception as e:  # noqa: BLE001
        log(f"yt_dlp_import_FAIL={e}")

    try:
        import yt_dlp_ejs
        from yt_dlp_ejs.yt import solver
        log(f"ejs_version={yt_dlp_ejs.version}")
        lib = solver.lib()
        core = solver.core()
        log(f"ejs_lib_len={len(lib)} ejs_core_len={len(core)}")
    except Exception as e:  # noqa: BLE001
        log(f"ejs_load_FAIL={e!r}")

    log(f"qjs_path={qjs_location} exists={bool(qjs_location and os.path.isfile(qjs_location))}")
    log(f"ffmpeg_path={ffmpeg_location} usable={_ffmpeg_usable(ffmpeg_location)}")

    # nativeLibraryDir is not writable — keep scripts under files/ (ejs parent).
    tmp_base = os.path.dirname(ejs_dir) if ejs_dir else None
    if qjs_location and os.path.isfile(qjs_location) and tmp_base:
        tmp = os.path.join(tmp_base, "ytdlp_tmp")
        os.makedirs(tmp, exist_ok=True)
        os.environ["TMPDIR"] = tmp
        os.environ["TEMP"] = tmp
        os.environ["TMP"] = tmp
        script = os.path.join(tmp, "selftest.js")
        with open(script, "w", encoding="utf-8") as f:
            f.write('console.log("qjs-ok")\n')
        try:
            import subprocess
            proc = subprocess.run(
                [qjs_location, "--script", script],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            log(f"qjs_rc={proc.returncode} out={proc.stdout!r} err={proc.stderr!r}")
        except Exception as e:  # noqa: BLE001
            log(f"qjs_run_FAIL={e!r}")

    url = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
    opts = {
        "quiet": False,
        "no_warnings": False,
        "skip_download": True,
        "ignore_no_formats_error": True,
        "nocheckcertificate": True,
        "check_formats": False,
        "js_runtimes": {"quickjs": {"path": qjs_location}} if qjs_location else {},
        "remote_components": ["ejs:github"],
        "extractor_args": {"youtube": {"player_client": ["android", "web"]}},
    }
    if cookiefile and os.path.isfile(cookiefile):
        opts["cookiefile"] = cookiefile
    # Pass the binary path (libffmpeg.so). dirname alone looks for a file named "ffmpeg".
    if ffmpeg_location and os.path.isfile(ffmpeg_location):
        opts["ffmpeg_location"] = ffmpeg_location

    class _Logger:
        def debug(self, msg):
            if isinstance(msg, bytes):
                msg = msg.decode("utf-8", "replace")
            if msg.startswith("[debug] "):
                log(msg)

        def info(self, msg):
            log(f"INFO {msg}")

        def warning(self, msg):
            log(f"WARN {msg}")

        def error(self, msg):
            log(f"ERROR {msg}")

    opts["logger"] = _Logger()
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False) or {}
        formats = info.get("formats") or []
        usable = [
            f for f in formats
            if f.get("url") and f.get("protocol") != "mhtml"
        ]
        log(f"extract_ok title={info.get('title')!r} formats={len(formats)} usable={len(usable)}")
        for f in usable[:8]:
            log(
                f"  fmt {f.get('format_id')} {f.get('ext')} "
                f"{f.get('resolution')} v={f.get('vcodec')} a={f.get('acodec')}"
            )
    except Exception as e:  # noqa: BLE001
        log(f"extract_FAIL={e!r}")

    pathlib.Path(log_path).write_text("\n".join(lines) + "\n", encoding="utf-8")
    return log_path


def _install_instagram_image_support():
    """Teach yt-dlp to download Instagram photo posts/carousel slides.

    yt-dlp only extracts video_versions as formats; image_versions2 is kept as
    thumbnails (or discarded entirely on some versions). Photo-only posts then
    fail with "No video formats found!". Promote the best image candidate to a
    real format so normal selectors like ``best`` can download it.
    """
    try:
        from yt_dlp.extractor.instagram import InstagramBaseIE
    except ImportError:
        return
    if getattr(InstagramBaseIE, "_vidfetch_image_patch", False):
        return

    original = InstagramBaseIE._extract_product_media

    def _patched(self, product_media):
        result = original(self, product_media) or {}
        if result.get("formats"):
            return result

        candidates = []
        try:
            from yt_dlp.utils import traverse_obj

            candidates = (
                traverse_obj(product_media, ("image_versions2", "candidates"))
                or []
            )
        except Exception:  # noqa: BLE001
            iv = product_media.get("image_versions2") or {}
            if isinstance(iv, dict):
                candidates = iv.get("candidates") or []

        formats = []
        for i, candidate in enumerate(candidates):
            if not isinstance(candidate, dict):
                continue
            url = candidate.get("url")
            if not url:
                continue
            formats.append({
                "format_id": f"img{i}",
                "url": url,
                "width": candidate.get("width"),
                "height": candidate.get("height"),
                "ext": "jpg",
                # Leave vcodec/acodec unset. yt-dlp's best/best* selectors
                # explicitly exclude formats where both are the string "none".
            })
        if not formats:
            return result

        out = dict(result)
        if not out.get("id"):
            try:
                from yt_dlp.extractor.instagram import _pk_to_id

                out["id"] = product_media.get("code") or _pk_to_id(
                    product_media.get("pk")
                )
            except Exception:  # noqa: BLE001
                out["id"] = str(
                    product_media.get("pk") or product_media.get("id") or "image"
                )
        out["formats"] = formats
        if not out.get("thumbnails"):
            out["thumbnails"] = [
                {
                    "url": f["url"],
                    "width": f.get("width"),
                    "height": f.get("height"),
                }
                for f in formats
            ]
        return out

    InstagramBaseIE._extract_product_media = _patched
    InstagramBaseIE._vidfetch_image_patch = True


_install_instagram_image_support()


# Cap how many posts a profile download pulls. Huge accounts can be tens of
# thousands of items; raise this if you intentionally want more.
_INSTAGRAM_PROFILE_PLAYLIST_END = 50


def _install_instagram_profile_support():
    """Replace broken InstagramUserIE with topsearch + feed/user pagination.

    Stock yt-dlp still scrapes window._sharedData (marked _WORKING=False).
    Logged-in cookies can resolve the user via web/search/topsearch and page
    posts from i.instagram.com/api/v1/feed/user/{id}/, yielding /p/ URLs so
    InstagramIE (plus our image patch) handles each post.
    """
    try:
        from yt_dlp.extractor.instagram import InstagramIE, InstagramUserIE
        from yt_dlp.utils import ExtractorError, traverse_obj
    except ImportError:
        return
    if getattr(InstagramUserIE, "_vidfetch_profile_patch", False):
        return

    def _resolve_user_id(self, username):
        search = self._download_json(
            "https://www.instagram.com/web/search/topsearch/",
            username,
            "Searching for user",
            fatal=False,
            headers=self._api_headers,
            query={"query": username, "context": "blended", "count": 5},
        ) or {}
        for entry in search.get("users") or []:
            user = entry.get("user") or {}
            if (user.get("username") or "").lower() == username.lower():
                user_id = str(user.get("pk") or user.get("id") or "")
                if user_id:
                    return user_id

        info = self._download_json(
            f"{self._API_BASE_URL}/users/web_profile_info/",
            username,
            "Downloading user info",
            headers=self._api_headers,
            query={"username": username},
        )
        user_id = traverse_obj(info, ("data", "user", "id"), expected_type=str)
        if not user_id:
            raise ExtractorError(
                f"Unable to resolve Instagram user id for {username}",
                expected=True,
            )
        return user_id

    def _real_extract(self, url):
        # Stock _VALID_URL uses [^/]+ so ?igsh=… is swallowed into the id.
        username = self._match_id(url).split("?", 1)[0].split("#", 1)[0]
        if not self._get_cookies("https://www.instagram.com/").get("sessionid"):
            self.raise_login_required(
                "Instagram profile downloads require a logged-in session. "
                "Sign in or import cookies in Settings."
            )

        user_id = _resolve_user_id(self, username)

        def entries():
            max_id = None
            page = 0
            while True:
                page += 1
                query = {"count": 12}
                if max_id:
                    query["max_id"] = max_id
                feed = self._download_json(
                    f"{self._API_BASE_URL}/feed/user/{user_id}/",
                    username,
                    f"Downloading feed page {page}",
                    headers=self._api_headers,
                    query=query,
                )
                for item in feed.get("items") or []:
                    code = item.get("code")
                    if not code:
                        continue
                    yield self.url_result(
                        f"https://www.instagram.com/p/{code}/",
                        ie=InstagramIE.ie_key(),
                        video_id=code,
                    )
                if not feed.get("more_available"):
                    break
                max_id = feed.get("next_max_id")
                if not max_id:
                    break

        return self.playlist_result(
            entries(), username, f"Posts by {username}"
        )

    InstagramUserIE._WORKING = True
    # Stop query/fragment from becoming part of the username capture group.
    InstagramUserIE._VALID_URL = (
        r"https?://(?:www\.)?instagram\.com/(?P<id>[^/?#]{2,})/?(?:$|[?#])"
    )
    InstagramUserIE._real_extract = _real_extract
    InstagramUserIE._vidfetch_profile_patch = True


_install_instagram_profile_support()


def _is_instagram_profile_url(url):
    """True for https://instagram.com/<user>/ style URLs (not /p/, /reel/, …)."""
    try:
        from urllib.parse import urlparse
    except ImportError:
        return False
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    if "instagram.com" not in host and host != "instagr.am":
        return False
    parts = [p for p in (parsed.path or "").split("/") if p]
    if len(parts) != 1:
        return False
    reserved = {
        "p", "tv", "reel", "reels", "stories", "explore", "accounts",
        "about", "legal", "direct", "share", "developer", "ids",
    }
    return parts[0].lower() not in reserved


def _collect_filepaths(info):
    """Gather every downloaded filepath from a video or playlist info dict."""
    paths = []
    if not info:
        return paths

    for req in info.get("requested_downloads") or []:
        fp = req.get("filepath")
        if fp:
            paths.append(fp)

    for entry in info.get("entries") or []:
        if not entry:
            continue
        if entry.get("_type") in ("playlist", "multi_video"):
            paths.extend(_collect_filepaths(entry))
            continue
        reqs = entry.get("requested_downloads") or []
        if reqs:
            for req in reqs:
                fp = req.get("filepath")
                if fp:
                    paths.append(fp)
        elif entry.get("filepath"):
            paths.append(entry["filepath"])

    seen = set()
    out = []
    for path in paths:
        if path not in seen:
            seen.add(path)
            out.append(path)
    return out


def _is_youtube_url(url):
    try:
        from urllib.parse import urlparse
    except ImportError:
        return False
    host = (urlparse(url).hostname or "").lower()
    return (
        "youtube.com" in host
        or host == "youtu.be"
        or host.endswith(".youtube.com")
    )


def _ffmpeg_usable(ffmpeg_location):
    """True if the bundled ffmpeg binary actually runs (not just exists)."""
    if not ffmpeg_location or not os.path.isfile(ffmpeg_location):
        return False
    try:
        import subprocess
        proc = subprocess.run(
            [ffmpeg_location, "-version"],
            capture_output=True,
            timeout=8,
            check=False,
        )
        return proc.returncode == 0
    except Exception:  # noqa: BLE001
        return False


# Progressive / single-file first — correct for Instagram and as a safe default.
_ANDROID_FORMAT_FALLBACKS_PROGRESSIVE = (
    "best[vcodec!=none][acodec!=none]/"
    "best/"
    "bestvideo[ext=mp4]/bestvideo"
)

# YouTube adaptive merge when a working ffmpeg is available.
_ANDROID_FORMAT_FALLBACKS_MERGE = (
    "bestvideo+bestaudio/"
    "best[vcodec!=none][acodec!=none]/"
    "best"
)


def _android_format_selector(url, requested, can_merge):
    """Merge the UI preference with site-appropriate Android fallbacks.

    Instagram (and most non-YouTube sites) ship progressive A+V files — leading
    with ``bestvideo+bestaudio`` forces a merge that fails if ffmpeg isn't
    detected. Only prefer merge for YouTube when ffmpeg actually runs.
    """
    requested = (requested or "").strip() or "best"
    if not can_merge and "+" in requested:
        requested = requested.split("+", 1)[0].strip() or "best"

    use_merge = can_merge and _is_youtube_url(url)
    if not use_merge and "+" in requested:
        requested = requested.split("+", 1)[0].strip() or "best"

    fallbacks = (
        _ANDROID_FORMAT_FALLBACKS_MERGE
        if use_merge
        else _ANDROID_FORMAT_FALLBACKS_PROGRESSIVE
    )
    if requested.endswith(fallbacks):
        return requested
    return f"{requested}/{fallbacks}"


def download(task_id, url, output_dir, format_selector, cancel_event, callback,
             insecure=False, cookiefile=None, ffmpeg_location=None,
             qjs_location=None, ejs_dir=None):
    """Download `url` into `output_dir`. Returns a JSON string result.

    `cancel_event` is a threading.Event created on the Java side; setting it
    aborts the download at the next progress tick (partial file is kept so
    --continue semantics work on resume).
    """

    def hook(d):
        if cancel_event.is_set():
            raise yt_dlp.utils.DownloadCancelled()
        status = d.get("status")
        if status == "downloading":
            total = d.get("total_bytes") or d.get("total_bytes_estimate")
            payload = {
                "downloaded": d.get("downloaded_bytes"),
                "total": total,
                "speed": d.get("speed"),
                "eta": d.get("eta"),
                "filename": d.get("filename"),
            }
            callback.onProgress(task_id, json.dumps(payload))

    is_profile = _is_instagram_profile_url(url)
    can_merge = _ffmpeg_usable(ffmpeg_location)
    has_qjs = bool(qjs_location and os.path.isfile(qjs_location))
    _install_ejs_asset_fallback(ejs_dir)

    # Writable tmp under files/ — nativeLibraryDir (libqjs.so) is not writable.
    writable_base = None
    if ejs_dir:
        writable_base = os.path.dirname(ejs_dir)
    elif output_dir:
        writable_base = os.path.dirname(output_dir)
    if writable_base:
        tmp = os.path.join(writable_base, "ytdlp_tmp")
        try:
            os.makedirs(tmp, exist_ok=True)
            os.environ["TMPDIR"] = tmp
            os.environ["TEMP"] = tmp
            os.environ["TMP"] = tmp
        except OSError:
            pass

    resolved_format = _android_format_selector(url, format_selector, can_merge)
    opts = {
        "format": resolved_format,
        # Include id so carousel slides (same title) don't overwrite each other.
        "outtmpl": f"{output_dir}/%(title)s_%(id)s.%(ext)s",
        "restrictfilenames": True,
        "continuedl": True,
        "overwrites": False,
        "progress_hooks": [hook],
        "noprogress": True,
        "quiet": True,
        "no_warnings": True,
        "noplaylist": False,
        "retries": 3,
        # Opt-in for users behind TLS-intercepting antivirus/proxies.
        "nocheckcertificate": insecure,
        # Don't discard formats whose URLs fail a preflight HEAD (common on
        # mobile networks / flaky YouTube CDN checks).
        "check_formats": False,
        "merge_output_format": "mp4",
    }
    if can_merge:
        # Full path to libffmpeg.so — yt-dlp matches "ffmpeg" inside the name.
        opts["ffmpeg_location"] = ffmpeg_location
    # YouTube requires an external JS runtime for challenge solving. Android
    # has no Deno/Node; we ship QuickJS and point yt-dlp at it.
    if has_qjs:
        opts["js_runtimes"] = {"quickjs": {"path": qjs_location}}
        # Prefer packaged yt-dlp-ejs; allow GitHub fetch as fallback.
        opts["remote_components"] = ["ejs:github"]
    else:
        # Explicitly empty so we don't pretend Deno exists on-device.
        opts["js_runtimes"] = {}
    if cookiefile and os.path.exists(cookiefile):
        opts["cookiefile"] = cookiefile
    if is_profile:
        opts["playlistend"] = _INSTAGRAM_PROFILE_PLAYLIST_END
        # One bad/deleted/429 post must not abort the rest of the profile.
        opts["ignoreerrors"] = True
    if _is_youtube_url(url):
        # android + web covers most videos; tv often needs extra PO tokens.
        opts["extractor_args"] = {
            "youtube": {"player_client": ["android", "web"]},
        }
        # Helpful when diagnosing challenge / format failures.
        opts["verbose"] = False

    def _run(format_override=None):
        run_opts = dict(opts)
        if format_override:
            run_opts["format"] = format_override
        with yt_dlp.YoutubeDL(run_opts) as ydl:
            return ydl.extract_info(url, download=True)

    def _youtube_diag():
        try:
            import yt_dlp_ejs  # noqa: F401
            ejs = "yes"
        except Exception:  # noqa: BLE001
            ejs = "no"
        try:
            diag_opts = dict(opts)
            diag_opts.pop("format", None)
            diag_opts["skip_download"] = True
            diag_opts["ignore_no_formats_error"] = True
            with yt_dlp.YoutubeDL(diag_opts) as ydl:
                info = ydl.extract_info(url, download=False) or {}
            formats = info.get("formats") or []
            usable = [
                f for f in formats
                if f.get("url") and f.get("protocol") != "mhtml"
            ]
            return (
                f"qjs={'yes' if has_qjs else 'no'} ejs={ejs} "
                f"ffmpeg_merge={'yes' if can_merge else 'no'} "
                f"formats={len(formats)} usable={len(usable)}"
            )
        except Exception as diag_err:  # noqa: BLE001
            return (
                f"qjs={'yes' if has_qjs else 'no'} ejs={ejs} "
                f"diag_error={diag_err}"
            )

    try:
        try:
            info = _run()
        except Exception as first:  # noqa: BLE001
            msg = str(first).lower()
            retryable = (
                "format is not available" in msg
                or "requested format" in msg
                or "ffmpeg is not installed" in msg
                or "merging of multiple formats" in msg
            )
            if not retryable:
                raise
            # Progressive / video-only — never requires a merge.
            info = _run("best/bestvideo/worst/bv*/b")
        paths = _collect_filepaths(info)
        title = (info or {}).get("title")
        if not title:
            for entry in (info or {}).get("entries") or []:
                if entry and entry.get("title"):
                    title = entry["title"]
                    break
        if not paths:
            err = "Download finished but no files were saved"
            if _is_youtube_url(url):
                err += f" ({_youtube_diag()})"
            return json.dumps({
                "success": False,
                "error": err,
                "title": title,
            })
        return json.dumps({
            "success": True,
            "filePath": paths[0],
            "filePaths": paths,
            "fileCount": len(paths),
            "title": title,
        })
    except yt_dlp.utils.DownloadCancelled:
        return json.dumps({"success": False, "cancelled": True})
    except Exception as e:  # noqa: BLE001 - surfaced to the UI as a message
        err = str(e)
        if _is_youtube_url(url):
            err = f"{err} [{_youtube_diag()}]"
        return json.dumps({"success": False, "error": err})
