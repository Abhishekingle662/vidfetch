# VidFetch (Flutter)

A clean, dark-themed Material 3 video downloader for Windows and Android,
powered by [yt-dlp](https://github.com/yt-dlp/yt-dlp). Supports YouTube,
Instagram, TikTok, X/Twitter, Facebook, Vimeo and 1000+ other sites.

## Features

- **Single URL download** — paste a video or playlist URL, pick quality
  (Best / 1080p / 720p), watch live progress (% · speed · ETA).
- **Batch download** — load a `.txt` file with one URL per line
  (`#` comments allowed); each link gets its own progress row.
- **Download management** — active + finished lists, pause / resume
  (via yt-dlp `--continue`), cancel, retry, open file, show in folder.
- **Background downloads** — on Android a foreground service keeps
  downloads alive with a progress notification; on desktop the yt-dlp
  child processes keep running while the app is open/minimized.
- **Settings** — download folder, default quality, notification toggle,
  and an optional explicit yt-dlp path.
- **Torrents** — paste a magnet or pick a `.torrent` file. The phone
  downloads on-device into the same queue and `Downloads/VidFetch`.
  No PC, qBittorrent, or gateway. Download only: when the file finishes
  (or you pause/cancel) the torrent is removed and the session is shut
  down — no background seeding. Your IP is still visible to trackers
  and peers **while downloading**. On Android (libtorrent4j): DHT, PEX,
  and an incoming TCP/uTP listen port run only during an active
  download. UPnP, NAT-PMP, and local discovery stay off (no router
  punch / LAN announce). Windows uses `dtorrent_task_v2`, which may
  enable LSD/UPnP for the duration of a download; we stop that task
  as soon as the file is done.

## Platform support

| Platform | UI | Downloads |
|----------|----|-----------|
| Windows  | ✅ | ✅ `yt-dlp` as a process; magnets/.torrent via `dtorrent_task_v2` |
| Android  | ✅ | ✅ yt-dlp in Chaquopy + bundled **ffmpeg** + **QuickJS**. Torrents via libtorrent4j. Files export to `Downloads/VidFetch`. |

## Requirements (Windows)

`yt-dlp` must be available. Any one of:

1. On `PATH` — `winget install yt-dlp` or `pip install yt-dlp`
2. `yt-dlp.exe` placed next to `vidfetch.exe`
3. An explicit path set in **Settings → Advanced → yt-dlp path**

For merged bestvideo+bestaudio formats, `ffmpeg` should also be on PATH.

## Building

```powershell
flutter pub get
flutter build windows --release   # needs VS "Desktop development with C++"
flutter build apk --release
```

### Build gotchas on this machine

- `~/.gradle/gradle.properties` sets
  `systemProp.javax.net.ssl.trustStoreType=Windows-ROOT` because Norton AV
  intercepts TLS; without it all Gradle dependency downloads fail with PKIX
  errors.
- `android/gradle.properties` sets `kotlin.incremental=false` — Kotlin
  incremental compilation corrupts caches when the pub cache (C:) and the
  project (D:) are on different drives.
- `file_picker` is pinned to 10.x: v11+ requires AGP built-in Kotlin, which
  conflicts with plugins that still apply the standalone Kotlin plugin
  (`flutter_background_service`, `flutter_local_notifications`).
- Chaquopy needs a host Python matching the embedded version:
  `chaquopy { defaultConfig { version = "3.12"; buildPython("C:/Python312/python.exe") } }`
  and ABIs limited to `arm64-v8a` + `x86_64`.
- If downloads fail with SSL certificate errors (Norton and similar AV
  intercept HTTPS), enable **Settings → Advanced → Ignore SSL certificate
  errors**.

## Code layout

```
lib/
├── main.dart                     # app shell, theme, navigation
├── models/download_task.dart     # task model + status enum
├── services/
│   ├── download_engine.dart      # engine interface (handle/result/progress)
│   ├── ytdlp_engine.dart         # desktop: yt-dlp process wrapper
│   ├── android_ytdlp_engine.dart # Android: platform channel to Chaquopy
│   ├── download_manager.dart     # queue, concurrency, pause/resume/cancel
│   ├── local_torrent_engine.dart # on-device magnets / .torrent files
│   ├── settings_service.dart     # shared_preferences-backed settings
│   ├── notification_service.dart # progress/completion notifications
│   └── background_service.dart   # Android foreground service keeper
├── screens/                      # home, downloads, settings
└── widgets/download_tile.dart    # per-download card with actions

android/app/src/main/
├── python/downloader.py          # yt-dlp API (progress hooks, cancel)
└── kotlin/...                    # yt-dlp channel, libtorrent session, MediaStore
```

On-device torrents need only the existing `INTERNET` permission plus the
download foreground service. VidFetch does not scrape other apps.

Only download content you have the right to save.
