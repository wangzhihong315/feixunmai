package com.vibepad.voice

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max

/**
 * On-device microphone self test.
 *
 * Records the same 4 s phrase from every capture source the voice path can use
 * and writes two WAVs per source:
 *
 *  - `<source>-16k.wav` — what the phone's microphone + our gain produce,
 *    before any transport;
 *  - `<source>-8k.wav`  — that stream pushed through the real wire path
 *    (16 k → 8 k → μ-law → decode → 16 k), i.e. what the Mac's virtual
 *    microphone actually plays.
 *
 * Comparing the two tells us whether a problem lives in the phone's capture or
 * in the transport, without involving Bluetooth at all.
 */
object MicTester {
    val sources: List<Pair<String, Int>> = listOf(
        "mic" to MediaRecorder.AudioSource.MIC,
        "voice_recognition" to MediaRecorder.AudioSource.VOICE_RECOGNITION,
        "voice_communication" to MediaRecorder.AudioSource.VOICE_COMMUNICATION
    )

    data class Result(
        val files: List<File>,
        val peaks: Map<String, Int>
    )

    fun recordAll(context: Context, secondsPerSource: Int = 4): Result {
        val dir = context.getExternalFilesDir(null) ?: context.filesDir
        dir.mkdirs()
        val files = mutableListOf<File>()
        val peaks = linkedMapOf<String, Int>()
        for ((name, source) in sources) {
            val recorded = record(source, secondsPerSource) ?: continue
            val rawFile = File(dir, "$name-16k.wav")
            val wireFile = File(dir, "$name-8k.wav")
            writeWav(rawFile, recorded.first, PhoneVoiceProtocol.SAMPLE_RATE)
            writeWav(wireFile, recorded.second, PhoneVoiceProtocol.SAMPLE_RATE)
            files += rawFile
            files += wireFile
            var peak = 0
            for (sample in recorded.first) {
                val value = abs(sample.toInt())
                if (value > peak) peak = value
            }
            peaks[name] = peak
        }
        return Result(files, peaks)
    }

    /** Returns (16 kHz raw, 16 kHz after the 8 kHz μ-law trip). */
    private fun record(source: Int, seconds: Int): Pair<ShortArray, ShortArray>? {
        val rate = PhoneVoiceProtocol.SAMPLE_RATE
        val frame = PhoneVoiceProtocol.FRAME_SAMPLES
        val minBuf = AudioRecord.getMinBufferSize(
            rate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val bufSize = max(minBuf, frame * 2 * 4)
        val rec = try {
            AudioRecord(
                source,
                rate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufSize
            )
        } catch (t: Throwable) {
            return null
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            return null
        }
        val total = rate * seconds
        val raw = ShortArray(total)
        val wire = ShortArray(total)
        val gain = AutoGain()
        val encoder = AdpcmEncoder()
        val decoder = AdpcmDecoder()
        val chunk = ShortArray(frame)
        var position = 0
        try {
            rec.startRecording()
            while (position + frame <= total) {
                val read = rec.read(chunk, 0, chunk.size)
                if (read <= 0) continue
                gain.apply(chunk, read)
                chunk.copyInto(raw, position, 0, read)
                val narrow = ShortArray(read / 2) { index ->
                    ((chunk[index * 2].toInt() + chunk[index * 2 + 1].toInt()) / 2).toShort()
                }
                val bytes = encoder.encode(narrow, narrow.size)
                val decoded = ShortArray(narrow.size)
                decoder.decode(bytes, decoded)
                var previous = 0
                for (index in decoded.indices) {
                    val sample = decoded[index].toInt()
                    wire[position + index * 2] = previous.toShort()
                    wire[position + index * 2 + 1] = ((previous + sample) / 2).toShort()
                    previous = sample
                }
                position += read
            }
        } catch (t: Throwable) {
            rec.release()
            return null
        }
        rec.release()
        return raw to wire
    }

    private fun writeWav(file: File, samples: ShortArray, sampleRate: Int) {
        val dataSize = samples.size * 2
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray())
        header.putInt(36 + dataSize)
        header.put("WAVE".toByteArray())
        header.put("fmt ".toByteArray())
        header.putInt(16)
        header.putShort(1)
        header.putShort(1)
        header.putInt(sampleRate)
        header.putInt(sampleRate * 2)
        header.putShort(2)
        header.putShort(16)
        header.put("data".toByteArray())
        header.putInt(dataSize)
        val body = ByteBuffer.allocate(dataSize).order(ByteOrder.LITTLE_ENDIAN)
        for (sample in samples) body.putShort(sample)
        file.outputStream().use { out ->
            out.write(header.array())
            out.write(body.array())
        }
    }
}
