package com.vibepad.voice

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Clean-up stage between the phone microphone and the encoder.
 *
 * Order matters:
 *  1. one-pole high-pass (~50 Hz) removes DC bias and handling rumble;
 *  2. a slowly tracking noise floor sets the gate — the gain is frozen while
 *     the frame sits near the floor, so pauses stay quiet instead of being
 *     pumped up into audible hiss (the previous version gated at a fixed 300
 *     and amplified room noise to near full scale);
 *  3. above the gate the gain lifts quiet speech toward [targetPeak], but a
 *     per-frame clamp guarantees the result can never clip.
 */
class AutoGain(
    private val targetPeak: Float = 9_000f,
    private val maxGain: Float = 8f,
    private val ceiling: Float = 30_000f
) {
    private var gain = 1f
    private var noiseFloor = 250f
    private var hpPrevIn = 0f
    private var hpPrevOut = 0f
    private val hpAlpha = 0.98f

    fun reset() {
        gain = 1f
        noiseFloor = 250f
        hpPrevIn = 0f
        hpPrevOut = 0f
    }

    fun apply(pcm: ShortArray, count: Int) {
        if (count <= 0) return

        // 1. high-pass / DC blocker
        for (i in 0 until count) {
            val x = pcm[i].toFloat()
            val y = hpAlpha * (hpPrevOut + x - hpPrevIn)
            hpPrevIn = x
            hpPrevOut = y
            pcm[i] = y.toInt().coerceIn(-32768, 32767).toShort()
        }

        var peak = 0
        for (i in 0 until count) {
            val value = abs(pcm[i].toInt())
            if (value > peak) peak = value
        }

        // 2. adaptive noise floor: rises slowly, falls slowly
        noiseFloor = max(120f, noiseFloor * 0.97f + peak * 0.03f)
        // 降噪后的语音只有 -36 dBFS 左右，门槛要贴着噪声底，否则连人声
        // 一起被挡住；贴着底噪时语音仍能过门，静音段保持原样不被放大。
        val gate = max(200f, noiseFloor * 1.6f)
        if (peak < gate) {
            // At or below the floor — freeze the gain so silence stays silent.
            return
        }

        // 3. lift quiet speech, never past the clipping ceiling
        val wanted = (targetPeak / peak).coerceIn(1f, maxGain)
        val factor = if (wanted > gain) 0.4f else 0.2f
        gain += (wanted - gain) * factor
        val safe = min(gain, ceiling / peak)
        if (safe <= 1.001f) return
        for (i in 0 until count) {
            val value = (pcm[i] * safe).toInt()
            pcm[i] = value.coerceIn(-32768, 32767).toShort()
        }
    }
}
