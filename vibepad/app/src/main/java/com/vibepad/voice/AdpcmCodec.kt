package com.vibepad.voice

/**
 * IMA/DVI ADPCM, 4-bit, 16 kHz mono.
 *
 * Two samples per byte: the even sample is in the low nibble and the odd
 * sample in the high nibble. Encoder and decoder start from predictor 0 and
 * index 0 at the beginning of every push-to-talk session.
 *
 * 320 samples (20 ms) -> 160 bytes, which is the audio payload the Mac
 * PhoneAudioBridge reassembles and decodes.
 */
class AdpcmEncoder {
    private var predictor = 0
    private var index = 0

    fun reset() {
        predictor = 0
        index = 0
    }

    fun encode(samples: ShortArray, count: Int = samples.size): ByteArray {
        val out = ByteArray((count + 1) / 2)
        var i = 0
        while (i < count) {
            val lo = encodeSample(samples[i].toInt())
            val hi = if (i + 1 < count) encodeSample(samples[i + 1].toInt()) else 0
            out[i / 2] = ((hi shl 4) or lo).toByte()
            i += 2
        }
        return out
    }

    private fun encodeSample(sample: Int): Int {
        val step = STEP_TABLE[index]
        var diff = sample - predictor
        var code = 0
        if (diff < 0) {
            code = 8
            diff = -diff
        }
        if (diff >= step) {
            code = code or 4
            diff -= step
        }
        if (diff >= (step shr 1)) {
            code = code or 2
            diff -= step shr 1
        }
        if (diff >= (step shr 2)) {
            code = code or 1
        }
        val delta = ((code and 7) * 2 + 1) * step / 8
        predictor += if ((code and 8) != 0) -delta else delta
        predictor = predictor.coerceIn(-32768, 32767)
        index = (index + INDEX_TABLE[code and 0x0F]).coerceIn(0, 88)
        return code and 0x0F
    }

    companion object {
        val STEP_TABLE = intArrayOf(
            7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
            34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130,
            143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449,
            494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411,
            1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026,
            4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
            11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
            27086, 29794, 32767
        )
        val INDEX_TABLE = intArrayOf(
            -1, -1, -1, -1, 2, 4, 6, 8,
            -1, -1, -1, -1, 2, 4, 6, 8
        )
    }
}

class AdpcmDecoder {
    private var predictor = 0
    private var index = 0

    fun reset() {
        predictor = 0
        index = 0
    }

    fun decode(data: ByteArray, out: ShortArray) {
        var o = 0
        for (b in data) {
            val lo = b.toInt() and 0x0F
            out[o++] = decodeNibble(lo).toShort()
            if (o >= out.size) break
            val hi = (b.toInt() shr 4) and 0x0F
            out[o++] = decodeNibble(hi).toShort()
            if (o >= out.size) break
        }
    }

    private fun decodeNibble(code: Int): Int {
        val step = AdpcmEncoder.STEP_TABLE[index]
        var diff = step shr 3
        if ((code and 1) != 0) diff += step shr 2
        if ((code and 2) != 0) diff += step shr 1
        if ((code and 4) != 0) diff += step
        predictor += if ((code and 8) != 0) -diff else diff
        predictor = predictor.coerceIn(-32768, 32767)
        index = (index + AdpcmEncoder.INDEX_TABLE[code]).coerceIn(0, 88)
        return predictor
    }
}
