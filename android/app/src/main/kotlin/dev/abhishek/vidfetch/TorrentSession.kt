package dev.abhishek.vidfetch

import android.content.Context
import org.libtorrent4j.SessionHandle
import org.libtorrent4j.SessionManager
import org.libtorrent4j.SessionParams
import org.libtorrent4j.SettingsPack
import org.libtorrent4j.Sha1Hash
import org.libtorrent4j.TorrentFlags
import org.libtorrent4j.TorrentHandle
import org.libtorrent4j.TorrentInfo
import org.libtorrent4j.swig.settings_pack
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * On-device BitTorrent via libtorrent4j. Download only — no seeding.
 *
 * While a torrent is active: DHT and PEX find the swarm; incoming
 * TCP/uTP listen on a random high port. UPnP, NAT-PMP, and LSD stay
 * off (no router punch / LAN announce).
 *
 * On finish, pause, or cancel the torrent is paused and removed and
 * upload stops immediately. If nothing else is downloading, the
 * session is torn down (listen port closed, DHT stopped). The phone
 * IP is still visible to trackers and peers during an active download.
 */
class TorrentSession(
    private val context: Context,
    private val emit: (String, Map<String, Any?>) -> Unit,
) {
    private val executor = Executors.newFixedThreadPool(2)
    private val killed = ConcurrentHashMap<String, AtomicBoolean>()
    private val taskHashes = ConcurrentHashMap<String, Sha1Hash>()
    private val sourceHashes = ConcurrentHashMap<String, Sha1Hash>()
    private val lock = Any()
    private var session: SessionManager? = null

    fun start(id: String, source: String) {
        val flag = AtomicBoolean(false)
        killed[id] = flag
        executor.execute {
            try {
                val path = runDownload(id, source, flag)
                if (flag.get()) {
                    emit("complete", mapOf("id" to id, "success" to false))
                    return@execute
                }
                emit(
                    "complete",
                    mapOf(
                        "id" to id,
                        "success" to true,
                        "filePath" to path.first,
                        "title" to path.second,
                    ),
                )
            } catch (e: Exception) {
                if (flag.get()) {
                    emit("complete", mapOf("id" to id, "success" to false))
                } else {
                    emit(
                        "complete",
                        mapOf(
                            "id" to id,
                            "success" to false,
                            "error" to (e.message ?: "Torrent failed"),
                        ),
                    )
                }
            } finally {
                killed.remove(id)
            }
        }
    }

    fun kill(id: String) {
        killed[id]?.set(true)
        val hash = taskHashes[id] ?: return
        // Drop the torrent now so pause/cancel cannot keep uploading.
        // Keep files so a later resume can continue.
        removeTorrent(hash, deleteFiles = false)
        executor.execute { maybeStopSession() }
    }

    fun abandon(source: String) {
        val hash = try {
            sourceHashes[source] ?: hashFor(source)
        } catch (_: Exception) {
            return
        }
        removeTorrent(hash, deleteFiles = true)
        hashDir(hash).deleteRecursively()
        executor.execute { maybeStopSession() }
    }

    private fun runDownload(
        id: String,
        source: String,
        flag: AtomicBoolean,
    ): Pair<String, String> {
        val magnet = source.trim().startsWith("magnet:", ignoreCase = true)
        ensureSession()
        val sm = session ?: throw IllegalStateException("Torrent session failed to start")

        var hash: Sha1Hash? = null
        try {
            val attached: Sha1Hash
            val saveDir: File
            synchronized(lock) {
                attached = if (magnet) addMagnet(sm, source) else addTorrentFile(sm, source)
                hash = attached
                taskHashes[id] = attached
                sourceHashes[source] = attached
                saveDir = hashDir(attached)
                saveDir.mkdirs()
                val handle = waitForHandle(sm, attached)
                    ?: throw IllegalStateException("Could not add that torrent.")
                applyTorrentFlags(handle)
                forceAnnounce(handle)
            }

            var lastName: String? = null
            var elapsedSec = 0
            var lastAnnounceSec = 0
            while (!flag.get()) {
                val handle = synchronized(lock) { sm.find(attached) }
                if (handle == null || !handle.isValid) {
                    throw IllegalStateException("Torrent was removed.")
                }
                val status = handle.status()
                val err = status.errorCode()
                if (err != null && err.isError) {
                    throw IllegalStateException(err.message)
                }
                val peers = status.numPeers()
                if (peers == 0 && elapsedSec - lastAnnounceSec >= ANNOUNCE_INTERVAL_SEC) {
                    forceAnnounce(handle)
                    lastAnnounceSec = elapsedSec
                }
                if (!status.hasMetadata() && elapsedSec >= METADATA_TIMEOUT_SEC) {
                    throw IllegalStateException(
                        "Could not fetch torrent metadata. Try a magnet that includes " +
                            "trackers, or try again.",
                    )
                }
                val name = status.name()
                if (!name.isNullOrEmpty() && name != lastName) {
                    lastName = name
                    emit("title", mapOf("id" to id, "title" to name))
                }
                val progress = status.progress().toDouble().coerceIn(0.0, 1.0)
                val rate = status.downloadPayloadRate().toDouble()
                val wanted = status.totalWanted()
                val done = status.totalWantedDone()
                val remain = (wanted - done).coerceAtLeast(0)
                val eta = if (rate > 0) (remain / rate).toInt() else -1
                emit(
                    "progress",
                    mapOf(
                        "id" to id,
                        "progress" to progress,
                        "speed" to rate,
                        "eta" to eta,
                        "name" to name,
                        "peers" to peers,
                        "dhtNodes" to sm.stats().dhtNodes(),
                    ),
                )
                if (status.hasMetadata() && (status.isFinished || status.isSeeding || progress >= 1.0)) {
                    // Pause and drop the torrent before the file copy so
                    // we never seed, and the listen/DHT session can die
                    // even if export takes a few seconds.
                    stopUploading(handle)
                    val staged = pickPrimarySource(handle, saveDir)
                    removeTorrent(attached, deleteFiles = false)
                    maybeStopSession()
                    val primary = exportPrimary(staged)
                    hashDir(attached).deleteRecursively()
                    return primary
                }
                Thread.sleep(1000)
                elapsedSec++
            }
            throw InterruptedException("killed")
        } finally {
            val attached = hash
            if (attached != null) {
                removeTorrent(attached, deleteFiles = false)
            }
            taskHashes.remove(id)
            maybeStopSession()
        }
    }

    private fun addMagnet(sm: SessionManager, magnet: String): Sha1Hash {
        val existing = hashFromMagnet(magnet)
        val found = sm.find(existing)
        if (found != null && found.isValid) {
            applyTorrentFlags(found)
            return existing
        }
        val saveDir = hashDir(existing)
        saveDir.mkdirs()
        sm.download(magnet, saveDir, TorrentFlags.DISABLE_LSD)
        return existing
    }

    private fun addTorrentFile(sm: SessionManager, path: String): Sha1Hash {
        val file = File(path)
        if (!file.isFile) {
            throw IllegalArgumentException("Could not read that .torrent file.")
        }
        val info = TorrentInfo(file)
        if (!info.isValid) {
            throw IllegalArgumentException("That .torrent file is not valid.")
        }
        val hash = info.infoHashes().getBest()
        val found = sm.find(hash)
        if (found != null && found.isValid) {
            applyTorrentFlags(found)
            return hash
        }
        val saveDir = hashDir(hash)
        saveDir.mkdirs()
        sm.download(info, saveDir)
        return hash
    }

    private fun applyTorrentFlags(handle: TorrentHandle) {
        handle.unsetFlags(TorrentFlags.AUTO_MANAGED)
        handle.unsetFlags(TorrentFlags.SUPER_SEEDING)
        handle.unsetFlags(TorrentFlags.SEED_MODE)
        handle.unsetFlags(TorrentFlags.SHARE_MODE)
        handle.unsetFlags(TorrentFlags.UPLOAD_MODE)
        handle.setFlags(TorrentFlags.DISABLE_LSD)
        handle.unsetFlags(TorrentFlags.DISABLE_PEX)
        handle.unsetFlags(TorrentFlags.DISABLE_DHT)
        handle.resume()
    }

    private fun forceAnnounce(handle: TorrentHandle) {
        if (!handle.isValid) return
        handle.forceReannounce()
        handle.forceDHTAnnounce()
    }

    private fun stopUploading(handle: TorrentHandle) {
        if (!handle.isValid) return
        handle.unsetFlags(TorrentFlags.AUTO_MANAGED)
        handle.pause()
    }

    private fun removeTorrent(hash: Sha1Hash, deleteFiles: Boolean) {
        synchronized(lock) {
            val sm = session
            val handle = sm?.find(hash)
            if (handle != null && handle.isValid) {
                stopUploading(handle)
                if (deleteFiles) {
                    sm.remove(handle, SessionHandle.DELETE_FILES)
                } else {
                    sm.remove(handle)
                }
            }
            taskHashes.entries.removeIf { it.value.toHex() == hash.toHex() }
            sourceHashes.entries.removeIf { it.value.toHex() == hash.toHex() }
        }
    }

    /**
     * Tear down libtorrent when nothing is downloading: close the listen
     * port and stop DHT. Must not run on the UI thread ([SessionManager.stop]
     * blocks).
     */
    private fun maybeStopSession() {
        val sm: SessionManager
        synchronized(lock) {
            if (taskHashes.isNotEmpty()) return
            sm = session ?: return
            session = null
            sourceHashes.clear()
        }
        try {
            val pack = SettingsPack()
            pack.setEnableDht(false)
            pack.setBoolean(settings_pack.bool_types.enable_incoming_tcp.swigValue(), false)
            pack.setBoolean(settings_pack.bool_types.enable_incoming_utp.swigValue(), false)
            pack.setBoolean(settings_pack.bool_types.enable_outgoing_tcp.swigValue(), false)
            pack.setBoolean(settings_pack.bool_types.enable_outgoing_utp.swigValue(), false)
            sm.applySettings(pack)
            sm.pause()
        } catch (_: Exception) {
            // Still destroy the native session below.
        }
        try {
            sm.stop()
        } catch (_: Exception) {
        }
    }

    private fun waitForHandle(sm: SessionManager, hash: Sha1Hash): TorrentHandle? {
        repeat(50) {
            val handle = sm.find(hash)
            if (handle != null && handle.isValid) return handle
            Thread.sleep(100)
        }
        return sm.find(hash)
    }

    private fun pickPrimarySource(handle: TorrentHandle, saveDir: File): Pair<File, String> {
        val info = handle.torrentFile()
            ?: throw IllegalStateException("Torrent metadata is missing.")
        val files = info.files()
        var bestPath: String? = null
        var bestName = info.name()
        var bestSize = -1L
        var bestVideo = false
        for (i in 0 until files.numFiles()) {
            if (files.padFileAt(i)) continue
            val size = files.fileSize(i)
            if (size <= 0) continue
            val rel = files.filePath(i)
            val video = isVideoName(rel)
            val better = if (bestPath == null) {
                true
            } else if (video && !bestVideo) {
                true
            } else if (video == bestVideo && size > bestSize) {
                true
            } else {
                false
            }
            if (better) {
                bestPath = files.filePath(i, saveDir.absolutePath)
                bestName = files.fileName(i)
                bestSize = size
                bestVideo = video
            }
        }
        val source = File(bestPath ?: throw IllegalStateException("Torrent has no files."))
        if (!source.isFile) {
            throw IllegalStateException("Downloaded file is missing.")
        }
        return source to bestName.ifEmpty { source.name }
    }

    private fun exportPrimary(staged: Pair<File, String>): Pair<String, String> {
        val source = staged.first
        val exportDir = File(context.getExternalFilesDir(null), "torrent_export").apply { mkdirs() }
        val dest = File(exportDir, safeName(staged.second))
        source.copyTo(dest, overwrite = true)
        return dest.absolutePath to dest.nameWithoutExtension.replace('_', ' ')
    }

    private fun ensureSession() {
        synchronized(lock) {
            if (session != null) return
            val sm = SessionManager(false)
            sm.start(SessionParams(sessionSettings()))
            session = sm
        }
    }

    private fun sessionSettings(): SettingsPack {
        val pack = SettingsPack.defaultSettings()
        pack.setEnableDht(true)
        pack.setEnableLsd(false)
        pack.setBoolean(settings_pack.bool_types.enable_upnp.swigValue(), false)
        pack.setBoolean(settings_pack.bool_types.enable_natpmp.swigValue(), false)
        pack.setBoolean(settings_pack.bool_types.enable_incoming_tcp.swigValue(), true)
        pack.setBoolean(settings_pack.bool_types.enable_incoming_utp.swigValue(), true)
        pack.setBoolean(settings_pack.bool_types.enable_outgoing_tcp.swigValue(), true)
        pack.setBoolean(settings_pack.bool_types.enable_outgoing_utp.swigValue(), true)
        pack.seedingOutgoingConnections(false)
        pack.setBoolean(settings_pack.bool_types.announce_to_all_trackers.swigValue(), true)
        pack.setBoolean(settings_pack.bool_types.announce_to_all_tiers.swigValue(), true)
        // Explicit routers: defaultSettings() already sets dht_bootstrap_nodes
        // to a single host, which skips SessionManager's extra-router path.
        pack.setDhtBootstrapNodes(
            "dht.libtorrent.org:25401,router.bittorrent.com:6881," +
                "router.utorrent.com:6881,dht.transmissionbt.com:6881," +
                "router.silotis.us:6881",
        )
        // IPv4 only. Port 0 = OS-assigned high port. Incoming does not need UPnP.
        pack.listenInterfaces("0.0.0.0:0")
        pack.connectionsLimit(100)
        pack.activeDownloads(4)
        pack.activeLimit(4)
        pack.activeSeeds(0)
        // libtorrent upload_rate_limit 0 means unlimited, so do not set 0.
        // Share/seed limits are 0 so auto-manage never prioritizes seeding.
        pack.setInteger(settings_pack.int_types.share_ratio_limit.swigValue(), 0)
        pack.setInteger(settings_pack.int_types.seed_time_limit.swigValue(), 0)
        pack.setInteger(settings_pack.int_types.seed_time_ratio_limit.swigValue(), 0)
        pack.setInteger(settings_pack.int_types.unchoke_slots_limit.swigValue(), 8)
        pack.setInteger(settings_pack.int_types.connection_speed.swigValue(), 30)
        return pack
    }

    private fun hashFromMagnet(magnet: String): Sha1Hash {
        val match = XT_REGEX.find(magnet)
            ?: throw IllegalArgumentException("That magnet link is missing a valid BitTorrent infohash.")
        val raw = match.groupValues[1]
        return when (raw.length) {
            40 -> Sha1Hash.parseHex(raw)
            32 -> Sha1Hash.fromBytes(decodeBase32(raw))
            else -> throw IllegalArgumentException("That magnet link is missing a valid BitTorrent infohash.")
        }
    }

    private fun decodeBase32(value: String): ByteArray {
        val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        val cleaned = value.uppercase().trimEnd('=')
        var buffer = 0
        var bits = 0
        val out = ArrayList<Byte>(20)
        for (ch in cleaned) {
            val idx = alphabet.indexOf(ch)
            if (idx < 0) {
                throw IllegalArgumentException("That magnet link is missing a valid BitTorrent infohash.")
            }
            buffer = (buffer shl 5) or idx
            bits += 5
            if (bits >= 8) {
                bits -= 8
                out.add(((buffer shr bits) and 0xFF).toByte())
            }
        }
        if (out.size != 20) {
            throw IllegalArgumentException("That magnet link is missing a valid BitTorrent infohash.")
        }
        return out.toByteArray()
    }

    private fun hashFor(source: String): Sha1Hash {
        return if (source.trim().startsWith("magnet:", ignoreCase = true)) {
            hashFromMagnet(source)
        } else {
            TorrentInfo(File(source)).infoHashes().getBest()
        }
    }

    private fun hashDir(hash: Sha1Hash): File {
        val root = File(context.getExternalFilesDir(null), "torrents")
        return File(root, hash.toHex())
    }

    private fun isVideoName(path: String): Boolean {
        val name = path.substringAfterLast('/').substringAfterLast('\\').lowercase()
        return VIDEO_EXT.any { name.endsWith(it) }
    }

    private fun safeName(raw: String): String {
        var name = raw.substringAfterLast('/').substringAfterLast('\\').trim()
        name = name.replace(Regex("[\\x00-\\x1f]"), "")
        if (name.isEmpty() || name == "." || name == "..") return "download"
        return name
    }

    companion object {
        private const val METADATA_TIMEOUT_SEC = 120
        private const val ANNOUNCE_INTERVAL_SEC = 30
        private val XT_REGEX = Regex("xt=urn:btih:([A-Za-z0-9]+)", RegexOption.IGNORE_CASE)
        private val VIDEO_EXT = listOf(
            ".mp4", ".mkv", ".webm", ".avi", ".mov", ".m4v", ".ts",
            ".wmv", ".flv", ".mpeg", ".mpg", ".m2ts",
        )
    }
}
