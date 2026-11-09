package com.vibepad.ui

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.rotate
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * 统一的线性图标：全部用 Canvas 画，不依赖 emoji 或字体字符，
 * 换机器、换系统字体都不会跑形。
 */

/** 麦克风：胶囊形音头 + 弧形拾音罩 + 底座。 */
@Composable
fun MicGlyph(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        val cx = w / 2
        val capW = w * 0.30f
        val capH = h * 0.50f
        drawRoundRect(
            color = color,
            topLeft = Offset(cx - capW / 2, h * 0.10f),
            size = Size(capW, capH),
            cornerRadius = CornerRadius(capW / 2, capW / 2)
        )
        drawArc(
            color = color,
            startAngle = 0f,
            sweepAngle = 180f,
            useCenter = false,
            topLeft = Offset(cx - w * 0.30f, h * 0.30f),
            size = Size(w * 0.60f, h * 0.42f),
            style = Stroke(width = w * 0.075f, cap = StrokeCap.Round)
        )
        drawLine(
            color = color,
            start = Offset(cx, h * 0.72f),
            end = Offset(cx, h * 0.86f),
            strokeWidth = w * 0.075f,
            cap = StrokeCap.Round
        )
        drawLine(
            color = color,
            start = Offset(cx - w * 0.16f, h * 0.87f),
            end = Offset(cx + w * 0.16f, h * 0.87f),
            strokeWidth = w * 0.075f,
            cap = StrokeCap.Round
        )
    }
}

/** 胶囊 / 药丸：斜放的圆角长条，下半截实心，一眼能看出是药丸。 */
@Composable
fun PillGlyph(
    color: Color,
    modifier: Modifier = Modifier,
    filled: Boolean = false
) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        rotate(degrees = -30f) {
            val pw = w * 0.46f
            val ph = h * 0.94f
            val topLeft = Offset((w - pw) / 2f, (h - ph) / 2f)
            val pillSize = Size(pw, ph)
            val radius = CornerRadius(pw / 2f, pw / 2f)
            if (filled) {
                drawRoundRect(color, topLeft, pillSize, radius)
            } else {
                val pill = Path().apply {
                    addRoundRect(
                        RoundRect(
                            left = topLeft.x,
                            top = topLeft.y,
                            right = topLeft.x + pw,
                            bottom = topLeft.y + ph,
                            radiusX = pw / 2f,
                            radiusY = pw / 2f
                        )
                    )
                }
                drawPath(pill, color, style = Stroke(width = w * 0.085f))
                clipPath(pill) {
                    drawRect(
                        color = color,
                        topLeft = Offset(topLeft.x, topLeft.y + ph * 0.52f),
                        size = Size(pw, ph * 0.48f)
                    )
                }
            }
        }
    }
}

/** 退格 / 删除：左侧尖角的键帽 + 中间一个 ×。 */
@Composable
fun BackspaceGlyph(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        val path = Path().apply {
            moveTo(w * 0.40f, h * 0.14f)
            lineTo(w * 0.94f, h * 0.14f)
            lineTo(w * 0.94f, h * 0.86f)
            lineTo(w * 0.40f, h * 0.86f)
            lineTo(w * 0.06f, h * 0.50f)
            close()
        }
        drawPath(
            path = path,
            color = color,
            style = Stroke(
                width = w * 0.08f,
                cap = StrokeCap.Round,
                join = StrokeJoin.Round
            )
        )
        drawLine(
            color, Offset(w * 0.52f, h * 0.38f), Offset(w * 0.76f, h * 0.62f),
            strokeWidth = w * 0.07f, cap = StrokeCap.Round
        )
        drawLine(
            color, Offset(w * 0.76f, h * 0.38f), Offset(w * 0.52f, h * 0.62f),
            strokeWidth = w * 0.07f, cap = StrokeCap.Round
        )
    }
}

/** 切换应用：两个叠放的窗口 + 指向右的箭头（Cmd+Tab 的语义）。 */
@Composable
fun SwitchGlyph(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        drawRoundRect(
            color = color.copy(alpha = 0.45f),
            topLeft = Offset(w * 0.08f, h * 0.32f),
            size = Size(w * 0.50f, h * 0.46f),
            cornerRadius = CornerRadius(w * 0.11f, w * 0.11f),
            style = Stroke(width = w * 0.07f)
        )
        drawRoundRect(
            color = color,
            topLeft = Offset(w * 0.40f, h * 0.16f),
            size = Size(w * 0.52f, h * 0.46f),
            cornerRadius = CornerRadius(w * 0.11f, w * 0.11f),
            style = Stroke(width = w * 0.07f)
        )
        drawLine(
            color, Offset(w * 0.54f, h * 0.39f), Offset(w * 0.80f, h * 0.39f),
            strokeWidth = w * 0.065f, cap = StrokeCap.Round
        )
        drawLine(
            color, Offset(w * 0.71f, h * 0.31f), Offset(w * 0.80f, h * 0.39f),
            strokeWidth = w * 0.065f, cap = StrokeCap.Round
        )
        drawLine(
            color, Offset(w * 0.71f, h * 0.47f), Offset(w * 0.80f, h * 0.39f),
            strokeWidth = w * 0.065f, cap = StrokeCap.Round
        )
    }
}

/** 设置：一圈齿 + 内圈。 */
@Composable
fun GearGlyph(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        val cx = w / 2f
        val cy = h / 2f
        val inner = minOf(w, h) * 0.30f
        drawCircle(
            color, radius = inner, center = Offset(cx, cy),
            style = Stroke(width = w * 0.075f)
        )
        drawCircle(
            color, radius = inner * 0.42f, center = Offset(cx, cy),
            style = Stroke(width = w * 0.07f)
        )
        for (i in 0 until 8) {
            val angle = (i * 45f) * (PI / 180f).toFloat()
            val c = cos(angle)
            val s = sin(angle)
            drawLine(
                color,
                Offset(cx + c * inner * 1.02f, cy + s * inner * 1.02f),
                Offset(cx + c * inner * 1.38f, cy + s * inner * 1.38f),
                strokeWidth = w * 0.09f,
                cap = StrokeCap.Round
            )
        }
    }
}

/** 播放：实心三角。 */
@Composable
fun PlayGlyph(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        val path = Path().apply {
            moveTo(w * 0.22f, h * 0.12f)
            lineTo(w * 0.86f, h * 0.50f)
            lineTo(w * 0.22f, h * 0.88f)
            close()
        }
        drawPath(path, color)
    }
}

/** 停止：圆角方块。 */
@Composable
fun StopGlyph(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        drawRoundRect(
            color = color,
            topLeft = Offset(w * 0.18f, h * 0.18f),
            size = Size(w * 0.64f, h * 0.64f),
            cornerRadius = CornerRadius(w * 0.14f, w * 0.14f)
        )
    }
}

/** 返回：一个左向箭头。 */
@Composable
fun ChevronLeftGlyph(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        drawLine(
            color, Offset(w * 0.62f, h * 0.20f), Offset(w * 0.36f, h * 0.50f),
            strokeWidth = w * 0.11f, cap = StrokeCap.Round
        )
        drawLine(
            color, Offset(w * 0.36f, h * 0.50f), Offset(w * 0.62f, h * 0.80f),
            strokeWidth = w * 0.11f, cap = StrokeCap.Round
        )
    }
}
