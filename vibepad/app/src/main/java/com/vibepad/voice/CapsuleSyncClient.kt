package com.vibepad.voice

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import com.vibepad.capsule.Capsule
import com.vibepad.capsule.CapsuleStore
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 闪念胶囊同步通道。
 *
 * 和语音链路完全独立：语音走蓝牙时也照样用 Wi-Fi 把胶囊传到 Mac；
 * 语音自己走 Wi-Fi 时，两条 TCP 连接同时存在（Mac 端按首帧类型区分角色）。
 *
 * 帧格式与语音一致：
 *   [version][type][seq][flags][len lo][len hi][payload]
 *   type 5 = 胶囊（payload 首字节是 op），6 = 回执，7 = 转写文本。
 */
class CapsuleSyncClient(private val context: Context) {
    private val tag = "VibePadCapsuleSync"

    @Volatile private var running = false

    private val nsd: NsdManager? =
        context.getSystemService(Context.NSD_SERVICE) as? NsdManager

    @Volatile private var host: String? = null
    @Volatile private var port: Int = 0

    private var socket: Socket? = null
    private var output: OutputStream? = null
    private var worker: Thread? = null
    private var reader: Thread? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private var seq = 0
    private var needsQuery = false

    private class PendingAck {
        val latch = CountDownLatch(1)
        @Volatile var ok = false
    }

    @Volatile private var pendingAck: PendingAck? = null

    fun start() {
        if (running) return
        running = true
        discover()
        worker = Thread({ loop() }, "vibepad-capsule-sync").apply {
            isDaemon = true
            start()
        }
        Log.i(tag, "sync started")
    }

    fun shutdown() {
        running = false
        worker?.interrupt()
        worker = null
        reader?.interrupt()
        reader = null
        runCatching { discovery?.let { nsd?.stopServiceDiscovery(it) } }
        discovery = null
        closeSocket()
        Log.i(tag, "sync stopped")
    }

    // MARK: - Discovery

    private fun discover() {
        val manager = nsd ?: return
        if (discovery != null) return
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                if (info.serviceType.startsWith("_vibedeck._tcp")) {
                    resolve(manager, info)
                }
            }

            override fun onServiceLost(info: NsdServiceInfo) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(tag, "discovery failed $errorCode")
                discovery = null
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                discovery = null
            }
        }
        discovery = listener
        runCatching {
            manager.discoverServices("_vibedeck._tcp", NsdManager.PROTOCOL_DNS_SD, listener)
        }.onFailure {
            discovery = null
            Log.w(tag, "discover threw", it)
        }
    }

    private fun resolve(manager: NsdManager, info: NsdServiceInfo) {
        manager.resolveService(info, object : NsdManager.ResolveListener {
            override fun onServiceResolved(resolved: NsdServiceInfo) {
                val address = resolved.host?.hostAddress ?: return
                if (host != address || port != resolved.port) {
                    host = address
                    port = resolved.port
                    Log.i(tag, "resolved $address:${resolved.port}")
                    // 地址变了就断开重连，让新地址生效。
                    closeSocket()
                }
            }

            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(tag, "resolve failed $errorCode")
            }
        })
    }

    // MARK: - Worker

    private fun loop() {
        while (running) {
            val pending = runCatching { CapsuleStore.all() }.getOrDefault(emptyList())
                .filter { !it.synced }
            val wantText = runCatching { CapsuleStore.all() }.getOrDefault(emptyList())
                .filter { it.synced && it.text.isNullOrEmpty() }

            if (pending.isEmpty() && wantText.isEmpty()) {
                closeSocket()
                sleepQuietly(8000)
                continue
            }
            if (!ensureConnected()) {
                sleepQuietly(3000)
                continue
            }
            if (needsQuery) {
                queryTexts(wantText)
                needsQuery = false
            }
            for (capsule in pending) {
                if (!running) return
                if (!upload(capsule)) break
            }
            sleepQuietly(1500)
        }
    }

    private fun ensureConnected(): Boolean {
        if (socket?.isConnected == true && output != null) return true
        val address = host ?: return false
        if (port <= 0) return false
        return try {
            val candidate = Socket()
            candidate.tcpNoDelay = true
            candidate.connect(InetSocketAddress(address, port), 3000)
            socket = candidate
            output = candidate.getOutputStream()
            seq = 0
            needsQuery = true
            startReader(candidate)
            Log.i(tag, "connected $address:$port")
            true
        } catch (t: Throwable) {
            Log.w(tag, "connect failed", t)
            closeSocket()
            false
        }
    }

    private fun closeSocket() {
        runCatching { socket?.close() }
        socket = null
        output = null
    }

    // MARK: - Upload

    private fun upload(capsule: Capsule): Boolean {
        val file = capsule.file
        if (!file.exists()) return false
        val size = file.length().toInt()
        if (size <= 44) return false

        val meta = JSONObject().apply {
            put("id", capsule.id)
            put("createdAt", capsule.createdAt)
            put("durationMs", capsule.durationMs)
            put("size", size)
            put("name", file.name)
        }
        val ack = PendingAck()
        pendingAck = ack
        try {
            if (!sendCapsule(PhoneVoiceProtocol.CAP_BEGIN, meta.toString().toByteArray())) {
                return false
            }
            File(file.path).inputStream().use { input ->
                val buffer = ByteArray(CHUNK)
                while (running) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    val chunk = if (read == buffer.size) buffer else buffer.copyOf(read)
                    if (!sendCapsule(PhoneVoiceProtocol.CAP_DATA, chunk)) return false
                }
            }
            if (!sendCapsule(PhoneVoiceProtocol.CAP_END, ByteArray(0))) return false
            val ok = ack.latch.await(ACK_TIMEOUT_MS, TimeUnit.MILLISECONDS) && ack.ok
            if (ok) {
                CapsuleStore.markSynced(context, capsule.id)
                Log.i(tag, "uploaded ${capsule.id} ${size}B")
            } else {
                Log.w(tag, "upload ack timeout ${capsule.id}")
            }
            return ok
        } catch (t: Throwable) {
            Log.w(tag, "upload failed ${capsule.id}", t)
            closeSocket()
            return false
        } finally {
            pendingAck = null
        }
    }

    /** 把已经同步但还没有文本的 id 发给 Mac，补回转写结果。 */
    private fun queryTexts(wantText: List<Capsule>) {
        if (wantText.isEmpty()) return
        val ids = JSONArray()
        wantText.take(200).forEach { ids.put(it.id) }
        sendCapsule(PhoneVoiceProtocol.CAP_QUERY, ids.toString().toByteArray())
    }

    private fun sendCapsule(op: Byte, body: ByteArray): Boolean {
        val out = output ?: return false
        val payload = ByteArray(1 + body.size)
        payload[0] = op
        body.copyInto(payload, 1)
        return try {
            writeFrame(out, PhoneVoiceProtocol.TYPE_CAPSULE, payload)
            true
        } catch (t: Throwable) {
            Log.w(tag, "write failed", t)
            closeSocket()
            false
        }
    }

    @Synchronized
    private fun writeFrame(out: OutputStream, type: Int, payload: ByteArray) {
        val header = ByteArray(6)
        header[0] = PhoneVoiceProtocol.VERSION.toByte()
        header[1] = type.toByte()
        header[2] = seq.toByte()
        header[3] = 0
        header[4] = (payload.size and 0xFF).toByte()
        header[5] = ((payload.size shr 8) and 0xFF).toByte()
        seq = (seq + 1) and 0xFF
        out.write(header)
        out.write(payload)
        out.flush()
    }

    // MARK: - Reader

    private fun startReader(active: Socket) {
        reader = Thread({
            val input = runCatching { active.getInputStream() }.getOrNull() ?: return@Thread
            val header = ByteArray(6)
            while (running && !active.isClosed) {
                try {
                    if (!readFully(input, header, 6)) break
                    val type = header[1].toInt() and 0xFF
                    val length = (header[4].toInt() and 0xFF) or
                        ((header[5].toInt() and 0xFF) shl 8)
                    val payload = ByteArray(length)
                    if (length > 0 && !readFully(input, payload, length)) break
                    when (type) {
                        PhoneVoiceProtocol.TYPE_CAPSULE_ACK -> handleAck(payload)
                        PhoneVoiceProtocol.TYPE_CAPSULE_TEXT -> handleText(payload)
                    }
                } catch (t: Throwable) {
                    if (running) Log.w(tag, "read failed", t)
                    break
                }
            }
            closeSocket()
        }, "vibepad-capsule-reader").apply {
            isDaemon = true
            start()
        }
    }

    private fun handleAck(payload: ByteArray) {
        val ack = pendingAck ?: return
        ack.ok = runCatching {
            JSONObject(String(payload)).optBoolean("ok", false)
        }.getOrDefault(false)
        ack.latch.countDown()
    }

    private fun handleText(payload: ByteArray) {
        runCatching {
            val json = JSONObject(String(payload))
            val id = json.optString("id")
            val text = json.optString("text")
            if (id.isNotEmpty() && text.isNotEmpty()) {
                CapsuleStore.setText(context, id, text)
                Log.i(tag, "text received $id ${text.length}字")
            }
        }.onFailure { Log.w(tag, "bad text frame", it) }
    }

    private fun readFully(input: InputStream, buffer: ByteArray, length: Int): Boolean {
        var offset = 0
        while (offset < length) {
            val read = input.read(buffer, offset, length - offset)
            if (read <= 0) return false
            offset += read
        }
        return true
    }

    private fun sleepQuietly(ms: Long) {
        try {
            Thread.sleep(ms)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private companion object {
        const val CHUNK = 4096
        const val ACK_TIMEOUT_MS = 20_000L
    }
}
