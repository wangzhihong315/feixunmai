package com.vibepad.capsule

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import com.vibepad.voice.AutoGain
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.max

/**
 * 闪念胶囊只负责"把话录下来"：16 kHz 单声道 WAV，存本机。
 * 识别放到 Mac 端用豆包做（见 VibeDeck 的转写队列）。
 */
data class Capsule(
    val id: String,
    val createdAt: Long,
    val durationMs: Long,
    val file: File,
    var text: String? = null,
    var synced: Boolean = false
) {
    val timeLabel: String
        get() = SimpleDateFormat("M月d日 HH:mm", Locale.CHINA).format(Date(createdAt))

    val durationLabel: String
        get() = "${(durationMs / 1000).coerceAtLeast(1)} 秒"
}

object CapsuleRecorder {
    private const val TAG = "VibePadCapsule"
    private const val SAMPLE_RATE = 16_000

    private var record: AudioRecord? = null
    private var thread: Thread? = null
    private var target: File? = null
    private var startedAt = 0L

    @Volatile
    var recording = false
        private set

    fun start(context: Context): Boolean {
        if (recording) return false
        val dir = CapsuleStore.dir(context)
        dir.mkdirs()
        val id = "cap_" + System.currentTimeMillis()
        val file = File(dir, "$id.wav")
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val recorder = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                max(minBuf, 320 * 2 * 4)
            )
        } catch (t: Throwable) {
            Log.w(TAG, "AudioRecord create failed", t)
            return false
        }
        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            return false
        }
        val out = try {
            RandomAccessFile(file, "rw")
        } catch (t: Throwable) {
            recorder.release()
            return false
        }
        out.setLength(0)
        out.write(ByteArray(44)) // 先占位，停止时回填头
        try {
            recorder.startRecording()
        } catch (t: Throwable) {
            out.close()
            recorder.release()
            return false
        }
        record = recorder
        target = file
        startedAt = System.currentTimeMillis()
        recording = true
        val agc = AutoGain()
        thread = Thread({
            val buffer = ShortArray(320)
            val bytes = ByteArray(640)
            try {
                while (recording) {
                    val read = recorder.read(buffer, 0, buffer.size)
                    if (read <= 0) continue
                    // 和语音链路同一套清理：高通去掉直流/握持低频，自适应增益抬起轻声，
                    // 写进 WAV 的就是能直接喂给豆包的样本。
                    agc.apply(buffer, read)
                    for (i in 0 until read) {
                        val v = buffer[i].toInt()
                        bytes[i * 2] = (v and 0xFF).toByte()
                        bytes[i * 2 + 1] = ((v shr 8) and 0xFF).toByte()
                    }
                    out.write(bytes, 0, read * 2)
                }
            } catch (t: Throwable) {
                Log.w(TAG, "write failed", t)
            } finally {
                runCatching { out.close() }
            }
        }, "vibepad-capsule-rec").apply {
            isDaemon = true
            start()
        }
        Log.i(TAG, "recording → ${file.name}")
        return true
    }

    /** 返回 (文件, 时长ms)，失败返回 null。 */
    fun stop(): Pair<File, Long>? {
        if (!recording) return null
        recording = false
        thread?.let { runCatching { it.join(800) } }
        thread = null
        runCatching { record?.stop() }
        runCatching { record?.release() }
        record = null
        val file = target ?: return null
        target = null
        val duration = System.currentTimeMillis() - startedAt
        runCatching { writeWavHeader(file) }
        Log.i(TAG, "saved ${file.name} ${file.length()}B ${duration}ms")
        return file to duration
    }

    private fun writeWavHeader(file: File) {
        val dataSize = (file.length() - 44).toInt().coerceAtLeast(0)
        RandomAccessFile(file, "rw").use { raf ->
            raf.seek(0)
            val header = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray())
            header.putInt(36 + dataSize)
            header.put("WAVE".toByteArray())
            header.put("fmt ".toByteArray())
            header.putInt(16)
            header.putShort(1)
            header.putShort(1)
            header.putInt(SAMPLE_RATE)
            header.putInt(SAMPLE_RATE * 2)
            header.putShort(2)
            header.putShort(16)
            header.put("data".toByteArray())
            header.putInt(dataSize)
            raf.write(header.array())
        }
    }
}

object CapsuleStore {
    private const val PREFS = "vibepad"
    private const val KEY = "capsules"

    private val items = mutableListOf<Capsule>()
    private var context: Context? = null

    /** 供 Compose 订阅：列表有任何增删改都会 +1，界面据此重组。 */
    var revision by mutableIntStateOf(0)
        private set

    @Synchronized
    fun init(context: Context) {
        this.context = context.applicationContext
        items.clear()
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, null) ?: return
        runCatching {
            val array = JSONArray(raw)
            for (i in 0 until array.length()) {
                val obj = array.getJSONObject(i)
                val file = File(dir(context), obj.getString("file"))
                if (!file.exists()) continue
                items += Capsule(
                    id = obj.getString("id"),
                    createdAt = obj.getLong("createdAt"),
                    durationMs = obj.getLong("durationMs"),
                    file = file,
                    text = obj.optString("text").takeIf { it.isNotEmpty() },
                    synced = obj.optBoolean("synced")
                )
            }
        }.onFailure { Log.w("VibePadCapsule", "load failed", it) }
    }

    fun dir(context: Context): File =
        File(context.getExternalFilesDir(null) ?: context.filesDir, "capsules")

    @Synchronized
    fun all(): List<Capsule> = items.sortedByDescending { it.createdAt }

    @Synchronized
    fun pendingCount(): Int = items.count { !it.synced }

    /// 还没有转写文本的条数。徽标和"待转写"状态都以此为准：
    /// 同步完之后徽标不会立刻消失，要等 Mac 真正把文字写回来。
    @Synchronized
    fun pendingTextCount(): Int = items.count { it.text.isNullOrEmpty() }

    @Synchronized
    fun add(context: Context, file: File, durationMs: Long): Capsule {
        val capsule = Capsule(
            id = file.nameWithoutExtension,
            createdAt = System.currentTimeMillis(),
            durationMs = durationMs,
            file = file
        )
        items += capsule
        persist(context)
        return capsule
    }

    @Synchronized
    fun markSynced(context: Context, id: String) {
        items.firstOrNull { it.id == id }?.synced = true
        persist(context)
    }

    @Synchronized
    fun setText(context: Context, id: String, text: String) {
        items.firstOrNull { it.id == id }?.text = text
        persist(context)
    }

    @Synchronized
    fun delete(context: Context, id: String) {
        items.firstOrNull { it.id == id }?.let { capsule ->
            runCatching { capsule.file.delete() }
        }
        items.removeAll { it.id == id }
        persist(context)
    }

    @Synchronized
    fun deleteAll(context: Context) {
        items.forEach { runCatching { it.file.delete() } }
        items.clear()
        persist(context)
    }

    @Synchronized
    private fun persist(context: Context) {
        val array = JSONArray()
        for (item in items) {
            array.put(JSONObject().apply {
                put("id", item.id)
                put("createdAt", item.createdAt)
                put("durationMs", item.durationMs)
                put("file", item.file.name)
                put("text", item.text ?: "")
                put("synced", item.synced)
            })
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY, array.toString()).apply()
        revision += 1
    }
}
