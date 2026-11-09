package com.vibepad.voice

import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.log10
import kotlin.math.sin

class AdpcmCodecTest {

    @Test
    fun sineRoundTripKeepsSignal() {
        val n = 320
        val pcm = ShortArray(n) {
            (sin(2.0 * PI * 440.0 * it / 16_000.0) * 12_000.0).toInt().toShort()
        }
        val encoded = AdpcmEncoder().encode(pcm)
        val decoded = ShortArray(n)
        AdpcmDecoder().decode(encoded, decoded)

        var signal = 0.0
        var noise = 0.0
        for (i in 0 until n) {
            val s = pcm[i].toDouble()
            val d = (pcm[i] - decoded[i]).toDouble()
            signal += s * s
            noise += d * d
        }
        val snr = if (noise == 0.0) 99.0 else 10.0 * log10(signal / noise)
        println("AdpcmCodecTest SNR=${"%.2f".format(snr)} dB")
        assertTrue("SNR too low: $snr", snr > 15.0)
    }
}
