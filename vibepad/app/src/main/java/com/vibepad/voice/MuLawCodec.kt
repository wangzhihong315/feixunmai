package com.vibepad.voice

/**
 * G.711 μ-law, 8 bit per sample.
 *
 * Replaces the 4-bit IMA ADPCM path: the quantisation hiss of 4-bit delta
 * coding was audible on the Mac's virtual microphone even at healthy levels.
 * μ-law keeps the same 320-byte frame for 320 samples (20 ms at 16 kHz) and
 * gives roughly telephone-grade clean speech, which is what recognisers want.
 */
class MuLawEncoder {
    fun encode(samples: ShortArray, count: Int = samples.size): ByteArray {
        val out = ByteArray(count)
        for (i in 0 until count) {
            out[i] = encodeSample(samples[i].toInt()).toByte()
        }
        return out
    }

    private fun encodeSample(sample: Int): Int {
        val bias = 0x84
        val clip = 32635
        var value = sample.coerceIn(-clip, clip)
        val sign = if (value < 0) 0x80 else 0
        if (value < 0) value = -value
        value += bias
        var exponent = 7
        var mask = 0x4000
        while (exponent > 0 && (value and mask) == 0) {
            mask = mask shr 1
            exponent--
        }
        val mantissa = (value shr (exponent + 3)) and 0x0F
        return (sign or (exponent shl 4) or mantissa) xor 0xFF
    }
}

/// Decoder used by the on-device self test to audition exactly what the Mac
/// receives after the 8 kHz μ-law trip.
class MuLawDecoder {
    fun decodeByte(byte: Int): Int {
        val value = byte xor 0xFF
        val sign = value and 0x80
        val exponent = (value shr 4) and 0x07
        val mantissa = value and 0x0F
        var sample = ((mantissa shl 3) + 0x84) shl exponent
        sample -= 0x84
        return if (sign != 0) -sample else sample
    }
}
