package com.vibepad

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val VibePadBackground = Color(0xFFF5F5F7)
val VibePadInk = Color(0xFF1D1D1F)
val VibePadMuted = Color(0xFF6E6E73)
val VibePadFaint = Color(0xFF8E8E93)
val VibePadBlue = Color(0xFF0A84FF)
val VibePadGreen = Color(0xFF30D158)
val VibePadCoral = Color(0xFFFF6B4A)
val VibePadPad = Color(0xFF141519)

private val LightColors = lightColorScheme(
    primary = VibePadBlue,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFE5F1FF),
    onPrimaryContainer = Color(0xFF003A66),
    secondary = VibePadMuted,
    onSecondary = Color.White,
    background = VibePadBackground,
    onBackground = VibePadInk,
    surface = Color.White,
    onSurface = VibePadInk,
    surfaceVariant = Color(0xFFECECEF),
    onSurfaceVariant = VibePadMuted,
    outline = Color(0x14000000),
    error = Color(0xFFFF453A)
)

@Composable
fun VibePadTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = LightColors, content = content)
}
