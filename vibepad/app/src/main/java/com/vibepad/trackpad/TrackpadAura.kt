package com.vibepad.trackpad

import android.os.SystemClock
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vibepad.ui.MicGlyph
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/** 触控区动效：按住说话和按住胶囊共用一块画布，只是配色与图形不同。 */
enum class AuraMode { Voice, Capsule }

private val AuraBlue = Color(0xFF5AA9FF)
private val AuraBlueDeep = Color(0xFF0A6BFF)
private val AuraBlueLight = Color(0xFFA8D2FF)
private val AuraOrange = Color(0xFFFF9F0A)
private val AuraOrangeDeep = Color(0xFFE2660A)

@Composable
fun TrackpadAura(
    visible: Boolean,
    mode: AuraMode,
    level: Float,
    elapsedMs: Long,
    modifier: Modifier = Modifier
) {
    val fade by animateFloatAsState(
        targetValue = if (visible) 1f else 0f,
        animationSpec = tween(durationMillis = 180),
        label = "auraFade"
    )
    val enterScale by animateFloatAsState(
        targetValue = if (visible) 1f else 0.94f,
        animationSpec = tween(durationMillis = 220),
        label = "auraScale"
    )
    // 呼吸/脉动相位：只在可见时跑帧循环，不可见就停，省电。
    var phase by remember { mutableFloatStateOf(0f) }
    // 电平做一次平滑，光球和频谱条不会跟着采样抖动。
    var smoothLevel by remember { mutableFloatStateOf(0f) }
    var rotation by remember { mutableFloatStateOf(0f) }
    // 每根频谱条自己的包络（快起慢落），不是共用一条固定正弦。
    val barLevels = remember { FloatArray(44) }
    // 声音突然变大时补一圈涟漪，让起伏和说话同步。
    val ripples = remember { ArrayList<Ripple>() }
    val levelNow by rememberUpdatedState(level.coerceIn(0f, 1f))
    LaunchedEffect(visible) {
        if (!visible) return@LaunchedEffect
        smoothLevel = levelNow
        barLevels.fill(0f)
        ripples.clear()
        var previous = levelNow
        var lastFrame = SystemClock.uptimeMillis()
        val start = lastFrame
        while (true) {
            withFrameNanos { }
            val now = SystemClock.uptimeMillis()
            val dt = ((now - lastFrame) / 1000f).coerceIn(0f, 0.05f)
            lastFrame = now
            phase = (now - start) / 1000f

            val target = levelNow
            val delta = (target - previous).coerceAtLeast(0f)
            previous = target
            smoothLevel += (target - smoothLevel) * 0.20f
            // 音量越大，整圈频谱转得越快。
            rotation += (0.12f + 0.50f * smoothLevel) * dt * 6.28318f

            for (i in barLevels.indices) {
                // 每根条错开相位，看起来像一整圈的抖动而不是同一根复制 44 次。
                // 每根条的起伏跨度拉大：安静时也有明显长短差，重音时个别条冲得更高。
                val flicker = 0.28f + 0.72f * (0.5f + 0.5f * sin(phase * 2.7f + i * 5.56f))
                val kick = delta * 5.0f * abs(sin(phase * 2.3f + i * 1.7f))
                val goal = (smoothLevel * flicker + kick * (0.35f + 0.65f * flicker))
                    .coerceIn(0f, 1f)
                // 抢起速度一致，回落速度逐条不同，尾巴不会一条直线地掉。
                val release = 0.09f + 0.10f * abs(sin(i * 2.1f))
                val attack = if (goal > barLevels[i]) 0.60f else release
                barLevels[i] += (goal - barLevels[i]) * attack
            }
            if (delta > 0.05f && ripples.size < 5) {
                ripples.add(Ripple(phase, (delta * 3.5f).coerceIn(0.2f, 1f)))
            }
            while (ripples.isNotEmpty() && phase - ripples.first().start > 1.3f) {
                ripples.removeAt(0)
            }
        }
    }

    if (fade <= 0.01f) return

    Box(
        modifier = modifier
            .fillMaxSize()
            .graphicsLayer {
                alpha = fade
                scaleX = enterScale
                scaleY = enterScale
            },
        contentAlignment = Alignment.Center
    ) {
        Canvas(Modifier.fillMaxSize()) {
            when (mode) {
                AuraMode.Voice -> drawVoiceAura(phase, smoothLevel, barLevels, ripples, rotation)
                AuraMode.Capsule -> drawCapsuleAura(phase, elapsedMs)
            }
        }
        if (mode == AuraMode.Voice) {
            // 麦头居中压在光球上，一眼能看出是在收音。
            MicGlyph(
                color = Color.White.copy(alpha = 0.95f),
                modifier = Modifier.size(24.dp).offset(y = (-24).dp)
            )
        }
        Column(
            modifier = Modifier.offset(y = if (mode == AuraMode.Voice) 132.dp else 108.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                text = when (mode) {
                    AuraMode.Voice -> "正在听…"
                    AuraMode.Capsule -> "正在记 · ${formatElapsed(elapsedMs)}"
                },
                color = Color.White.copy(alpha = 0.94f),
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = when (mode) {
                    AuraMode.Voice -> "松手结束 · VibeDeck 接收中"
                    AuraMode.Capsule -> "松手保存 · 仅存本机"
                },
                color = Color.White.copy(alpha = 0.40f),
                fontSize = 10.sp
            )
        }
    }
}

/**
 * 语音动效：中央麦克风光球 + 44 根环形频谱 + 声波涟漪。
 * 每根频谱条有自己的快起慢落包络，直接跟实时电平；说话突然变响时
 * 额外冒出一圈涟漪，整圈还会随音量加速旋转。
 */
private fun DrawScope.drawVoiceAura(
    phase: Float,
    energy: Float,
    bars: FloatArray,
    ripples: List<Ripple>,
    rotation: Float
) {
    val center = Offset(size.width / 2f, size.height / 2f - 24.dp.toPx())
    val pulse = (sin(phase * 2.2f) + 1f) / 2f
    val orbR = 36.dp.toPx() + 12.dp.toPx() * energy + 3.dp.toPx() * pulse
    val maxR = minOf(size.width, size.height) / 2f - 8.dp.toPx()

    // 常驻涟漪：安静的底噪也在缓慢呼吸。
    repeat(2) { index ->
        val t = (phase * 0.34f + index / 2f) % 1f
        val radius = (62.dp.toPx() + t * (72.dp.toPx() + 36.dp.toPx() * energy))
            .coerceAtMost(maxR)
        val alpha = (1f - t) * (0.05f + 0.18f * energy)
        drawCircle(
            color = AuraBlue.copy(alpha = alpha),
            radius = radius,
            center = center,
            style = Stroke(width = 1.2.dp.toPx())
        )
    }
    // 声音顶上来时补的涟漪：扩散更远、更亮，和说话节奏同步。
    for (ripple in ripples) {
        val t = ((phase - ripple.start) / 1.3f).coerceIn(0f, 1f)
        val radius = (60.dp.toPx() +
            t * (110.dp.toPx() + 70.dp.toPx() * ripple.strength)).coerceAtMost(maxR)
        val alpha = (1f - t) * (0.10f + 0.45f * ripple.strength)
        drawCircle(
            color = AuraBlue.copy(alpha = alpha),
            radius = radius,
            center = center,
            style = Stroke(width = (1.4f + 1.6f * ripple.strength).dp.toPx())
        )
    }

    // 光球外晕
    val glowR = orbR * 2.3f
    drawCircle(
        brush = Brush.radialGradient(
            colors = listOf(
                AuraBlue.copy(alpha = 0.36f + 0.22f * energy),
                AuraBlue.copy(alpha = 0.10f),
                Color.Transparent
            ),
            center = center,
            radius = glowR
        ),
        radius = glowR,
        center = center
    )
    // 球体本身
    drawCircle(
        brush = Brush.radialGradient(
            colors = listOf(AuraBlueLight, AuraBlueDeep),
            center = center,
            radius = orbR
        ),
        radius = orbR,
        center = center
    )
    drawCircle(
        color = Color.White.copy(alpha = 0.20f),
        radius = orbR,
        center = center,
        style = Stroke(width = 1.dp.toPx())
    )

    // 环形频谱：长度、粗细、亮度全部由每根条自己的包络决定。
    val count = bars.size
    val innerR = orbR + 8.dp.toPx()
    val step = 2f * PI.toFloat() / count
    for (i in 0 until count) {
        val angle = rotation + i * step
        val v = bars[i]
        val h = 3.dp.toPx() + v * 40.dp.toPx()
        val c = cos(angle)
        val s = sin(angle)
        drawLine(
            color = Color.White.copy(alpha = 0.24f + 0.66f * v),
            start = Offset(center.x + c * innerR, center.y + s * innerR),
            end = Offset(center.x + c * (innerR + h), center.y + s * (innerR + h)),
            strokeWidth = (1.7f + 1.9f * v).dp.toPx(),
            cap = StrokeCap.Round
        )
    }
}

private data class Ripple(val start: Float, val strength: Float)

private fun DrawScope.drawCapsuleAura(phase: Float, elapsedMs: Long) {
    val center = Offset(size.width / 2f, size.height / 2f - 24.dp.toPx())
    val pulse = (sin(phase * 2.2f) + 1f) / 2f
    val glowR = 118.dp.toPx() + 10.dp.toPx() * pulse

    drawCircle(
        brush = Brush.radialGradient(
            colors = listOf(
                AuraOrange.copy(alpha = 0.26f),
                AuraOrangeDeep.copy(alpha = 0.10f),
                Color.Transparent
            ),
            center = center,
            radius = glowR
        ),
        radius = glowR,
        center = center
    )

    // 外圈 24 颗点：每 1.25 秒点亮一颗，录满 30 秒全亮。
    val dots = 24
    val ringR = 84.dp.toPx()
    val lit = (elapsedMs / 1250L).toInt().coerceIn(0, dots)
    for (i in 0 until dots) {
        val angle = (-PI / 2f + i * (2 * PI / dots)).toFloat()
        val dotCenter = Offset(
            center.x + cos(angle) * ringR,
            center.y + sin(angle) * ringR
        )
        val isLit = i < lit
        val isCurrent = i == lit - 1
        val alpha = when {
            isCurrent -> 0.65f + 0.30f * pulse
            isLit -> 0.85f
            else -> 0.12f
        }
        drawCircle(
            color = if (isLit) AuraOrange.copy(alpha = alpha) else Color.White.copy(alpha = alpha),
            radius = if (isCurrent) 3.4.dp.toPx() else 2.4.dp.toPx(),
            center = dotCenter
        )
    }

    // 中央的药丸：轻轻脉动，中间一道分界线。
    val scale = 1f + 0.05f * pulse
    val pw = 34.dp.toPx() * scale
    val ph = 88.dp.toPx() * scale
    rotate(degrees = -24f, pivot = center) {
        val topLeft = Offset(center.x - pw / 2f, center.y - ph / 2f)
        drawRoundRect(
            brush = Brush.verticalGradient(
                colors = listOf(Color(0xFFFFC46B), AuraOrange, AuraOrangeDeep),
                startY = center.y - ph / 2f,
                endY = center.y + ph / 2f
            ),
            topLeft = topLeft,
            size = Size(pw, ph),
            cornerRadius = CornerRadius(pw / 2f, pw / 2f)
        )
        drawRoundRect(
            color = Color.White.copy(alpha = 0.26f),
            topLeft = topLeft,
            size = Size(pw, ph),
            cornerRadius = CornerRadius(pw / 2f, pw / 2f),
            style = Stroke(width = 1.2.dp.toPx())
        )
        drawLine(
            color = Color.White.copy(alpha = 0.34f),
            start = Offset(topLeft.x + pw * 0.12f, center.y),
            end = Offset(topLeft.x + pw * 0.88f, center.y),
            strokeWidth = 1.4.dp.toPx(),
            cap = StrokeCap.Round
        )
    }
}

private fun formatElapsed(ms: Long): String {
    val total = (ms / 1000L).coerceAtLeast(0L)
    return "%d:%02d".format(total / 60, total % 60)
}
