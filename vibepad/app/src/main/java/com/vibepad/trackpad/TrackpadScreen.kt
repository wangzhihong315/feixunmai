package com.vibepad.trackpad

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.HapticFeedbackConstants
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import com.vibepad.capsule.CapsuleHistoryScreen
import com.vibepad.capsule.CapsuleRecorder
import com.vibepad.capsule.CapsuleStore
import com.vibepad.ui.BackspaceGlyph
import com.vibepad.ui.GearGlyph
import com.vibepad.ui.MicGlyph
import com.vibepad.ui.PillGlyph
import com.vibepad.ui.SwitchGlyph
import com.vibepad.voice.MicTester
import com.vibepad.voice.PhoneVoiceController
import com.vibepad.voice.PhoneVoiceGattServer
import com.vibepad.VibePadBackground
import com.vibepad.VibePadBlue
import com.vibepad.VibePadCoral
import com.vibepad.VibePadFaint
import com.vibepad.VibePadGreen
import com.vibepad.VibePadInk
import com.vibepad.VibePadMuted
import com.vibepad.VibePadPad

@Composable
fun TrackpadScreen() {
    val context = LocalContext.current
    val isLandscape =
        LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    val hidState by HidDeviceController.state.collectAsState()
    val voiceState by PhoneVoiceController.state.collectAsState()
    val level by PhoneVoiceController.level.collectAsState()
    val macFlags by PhoneVoiceController.macFlags.collectAsState()
    val voiceLink by PhoneVoiceController.link.collectAsState()
    var capsuleToast by remember { mutableStateOf<String?>(null) }
    val prefs = remember { context.getSharedPreferences("vibepad", Context.MODE_PRIVATE) }
    LaunchedEffect(capsuleToast) {
        if (capsuleToast != null) {
            delay(2600)
            capsuleToast = null
        }
    }

    var sensitivity by remember { mutableFloatStateOf(prefs.getFloat("sensitivity", 1.4f)) }
    var naturalScroll by remember { mutableStateOf(prefs.getBoolean("natural_scroll", true)) }
    var edgeScroll by remember { mutableStateOf(prefs.getBoolean("edge_scroll", true)) }
    var haptics by remember { mutableStateOf(prefs.getBoolean("haptics", true)) }
    var leftHanded by remember {
        mutableStateOf(prefs.getString("handedness", "right") == "left")
    }
    var showSettings by remember { mutableStateOf(false) }
    var showCapsules by remember { mutableStateOf(false) }
    var capsuleRecording by remember { mutableStateOf(false) }
    var capsuleStartedAt by remember { mutableStateOf(0L) }
    var capsuleElapsed by remember { mutableStateOf(0L) }
    val capsuleRevision = CapsuleStore.revision
    val pendingCapsules = remember(capsuleRevision) { CapsuleStore.pendingTextCount() }

    LaunchedEffect(capsuleRecording) {
        if (!capsuleRecording) {
            capsuleElapsed = 0L
            return@LaunchedEffect
        }
        while (true) {
            capsuleElapsed = SystemClock.uptimeMillis() - capsuleStartedAt
            delay(80)
        }
    }

    Box(modifier = Modifier.fillMaxSize().background(VibePadBackground)) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .systemBarsPadding()
                .padding(horizontal = 18.dp)
        ) {
            val headerInPanel =
                isLandscape && hidState is HidDeviceController.State.Connected
            if (!headerInPanel) {
                Header(
                    hidState = hidState,
                    voiceState = voiceState,
                    macFlags = macFlags,
                    voiceLink = voiceLink,
                    capsuleBadge = pendingCapsules,
                    mode = if (isLandscape) HeaderMode.Wide else HeaderMode.Full,
                    onOpenCapsules = { showCapsules = true },
                    onSettings = { showSettings = true }
                )
            }

            if (hidState is HidDeviceController.State.Connected) {
                val onCapsuleRecording: (Boolean) -> Unit = { recording ->
                    capsuleRecording = recording
                    if (recording) capsuleStartedAt = SystemClock.uptimeMillis()
                }
                if (isLandscape) {
                    // 横屏：整列交给触控区，header 和按键收进右侧一列；左手模式整体镜像。
                    Row(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxWidth()
                            .padding(vertical = 2.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        if (leftHanded) {
                            LandscapeSidePanel(
                                modifier = Modifier.width(292.dp).fillMaxHeight(),
                                hidState = hidState,
                                voiceState = voiceState,
                                macFlags = macFlags,
                                voiceLink = voiceLink,
                                capsuleBadge = pendingCapsules,
                                onOpenCapsules = { showCapsules = true },
                                onSettings = { showSettings = true },
                                level = level,
                                leftHanded = true,
                                capsuleRecording = capsuleRecording,
                                onCapsuleRecording = onCapsuleRecording,
                                onCapsuleSaved = { capsuleToast = it },
                                toast = capsuleToast
                            )
                            TrackpadSurface(
                                modifier = Modifier.weight(1f).fillMaxHeight(),
                                sensitivity = sensitivity,
                                naturalScroll = naturalScroll,
                                edgeScroll = edgeScroll,
                                haptics = haptics,
                                edgeScrollLeft = true,
                                talking = voiceState is PhoneVoiceGattServer.State.Talking,
                                capsuleRecording = capsuleRecording,
                                level = level,
                                capsuleElapsedMs = capsuleElapsed
                            )
                        } else {
                            TrackpadSurface(
                                modifier = Modifier.weight(1f).fillMaxHeight(),
                                sensitivity = sensitivity,
                                naturalScroll = naturalScroll,
                                edgeScroll = edgeScroll,
                                haptics = haptics,
                                edgeScrollLeft = false,
                                talking = voiceState is PhoneVoiceGattServer.State.Talking,
                                capsuleRecording = capsuleRecording,
                                level = level,
                                capsuleElapsedMs = capsuleElapsed
                            )
                            LandscapeSidePanel(
                                modifier = Modifier.width(292.dp).fillMaxHeight(),
                                hidState = hidState,
                                voiceState = voiceState,
                                macFlags = macFlags,
                                voiceLink = voiceLink,
                                capsuleBadge = pendingCapsules,
                                onOpenCapsules = { showCapsules = true },
                                onSettings = { showSettings = true },
                                level = level,
                                leftHanded = false,
                                capsuleRecording = capsuleRecording,
                                onCapsuleRecording = onCapsuleRecording,
                                onCapsuleSaved = { capsuleToast = it },
                                toast = capsuleToast
                            )
                        }
                    }
                } else {
                    TrackpadSurface(
                        modifier = Modifier.weight(1f),
                        sensitivity = sensitivity,
                        naturalScroll = naturalScroll,
                        edgeScroll = edgeScroll,
                        haptics = haptics,
                        // 边缘滚动跟持机手同侧：右手拇指就在右边缘，滑起来最顺。
                        edgeScrollLeft = leftHanded,
                        talking = voiceState is PhoneVoiceGattServer.State.Talking,
                        capsuleRecording = capsuleRecording,
                        level = level,
                        capsuleElapsedMs = capsuleElapsed
                    )
                    VoiceBar(
                        state = voiceState,
                        level = level,
                        leftHanded = leftHanded,
                        capsuleRecording = capsuleRecording,
                        onCapsuleRecording = onCapsuleRecording,
                        onCapsuleSaved = { capsuleToast = it }
                    )
                    capsuleToast?.let {
                        CapsuleToast(it, Modifier.padding(bottom = 10.dp))
                    }
                }
            } else {
                PairingContent(
                    modifier = Modifier.weight(1f),
                    hidState = hidState,
                    onConnect = { HidDeviceController.connect(it) }
                )
            }
        }

        if (showSettings) {
            SettingsSheet(
                sensitivity = sensitivity,
                naturalScroll = naturalScroll,
                edgeScroll = edgeScroll,
                haptics = haptics,
                leftHanded = leftHanded,
                hidState = hidState,
                voiceState = voiceState,
                voiceLink = voiceLink,
                onVoiceLink = { PhoneVoiceController.setLink(it) },
                onHandedness = {
                    leftHanded = it
                    prefs.edit()
                        .putString("handedness", if (it) "left" else "right")
                        .apply()
                },
                onSensitivity = {
                    sensitivity = it
                    prefs.edit().putFloat("sensitivity", it).apply()
                    HidDeviceController.updateSettings(it, naturalScroll)
                },
                onNaturalScroll = {
                    naturalScroll = it
                    prefs.edit().putBoolean("natural_scroll", it).apply()
                    HidDeviceController.updateSettings(sensitivity, it)
                },
                onEdgeScroll = {
                    edgeScroll = it
                    prefs.edit().putBoolean("edge_scroll", it).apply()
                },
                onHaptics = {
                    haptics = it
                    prefs.edit().putBoolean("haptics", it).apply()
                },
                onDismiss = { showSettings = false }
            )
        }

        if (showCapsules) {
            CapsuleHistoryScreen(onBack = { showCapsules = false })
        }
    }
}

// MARK: - Header

/** Full=竖屏两行；Wide=横屏未连接时铺满顶部的单行；Panel=横屏右侧栏里的两行。 */
private enum class HeaderMode { Full, Wide, Panel }

@Composable
private fun Header(
    hidState: HidDeviceController.State,
    voiceState: PhoneVoiceGattServer.State,
    macFlags: Int,
    voiceLink: String,
    capsuleBadge: Int,
    mode: HeaderMode,
    onOpenCapsules: () -> Unit,
    onSettings: () -> Unit
) {
    val hidReady = hidState is HidDeviceController.State.Connected
    val talking = voiceState is PhoneVoiceGattServer.State.Talking
    val voiceReady = voiceState is PhoneVoiceGattServer.State.Connected || talking
    val macKnown = macFlags != 0
    val macReady = (macFlags and 0x01) != 0
    val isWifi = voiceLink == PhoneVoiceController.LINK_WIFI

    val voiceText = when {
        talking -> "语音传输中"
        voiceReady -> "语音已连接"
        voiceState is PhoneVoiceGattServer.State.Advertising -> "语音等待"
        else -> "语音未启用"
    }
    val voiceColor = when {
        talking -> VibePadCoral
        voiceReady -> VibePadGreen
        else -> VibePadFaint
    }
    val macText = when {
        !macKnown -> "Mac 授权 等待"
        macReady -> "Mac 授权 已就绪"
        else -> "Mac 授权 需确认"
    }
    // 横屏单行时把文案压到最短，省出来的高度全部给触控区和按键区。
    val macTextCompact = when {
        !macKnown -> "Mac 等待"
        macReady -> "Mac 已就绪"
        else -> "Mac 需确认"
    }
    val macColor = when {
        !macKnown -> VibePadFaint
        macReady -> VibePadGreen
        else -> VibePadCoral
    }
    val linkText = if (isWifi) "Wi-Fi 语音" else "蓝牙 HID"
    val linkTextCompact = if (isWifi) "Wi-Fi" else "蓝牙"
    val linkColor = when {
        isWifi -> if (voiceReady) VibePadGreen else VibePadFaint
        else -> if (hidReady) VibePadGreen else VibePadFaint
    }

    val dense = mode != HeaderMode.Full
    val titleSize = if (dense) 18.sp else 22.sp
    val titleSpacing = if (dense) (-0.3).sp else (-0.4).sp
    val iconSize = if (dense) 32.dp else 36.dp
    val glyphSize = if (dense) 15.dp else 17.dp
    val shownMacText = if (dense) macTextCompact else macText
    val shownLinkText = if (dense) linkTextCompact else linkText

    if (mode == HeaderMode.Wide) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 2.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "VibePad",
                fontSize = titleSize,
                fontWeight = FontWeight.SemiBold,
                color = VibePadInk,
                letterSpacing = titleSpacing
            )
            Spacer(Modifier.width(14.dp))
            HeaderStatus(voiceColor, voiceText, small = true)
            Spacer(Modifier.width(10.dp))
            HeaderStatus(macColor, shownMacText, small = true)
            Spacer(Modifier.width(10.dp))
            HeaderStatus(linkColor, shownLinkText, small = true)
            Spacer(Modifier.weight(1f))
            CircleIconButton(
                onClick = onOpenCapsules,
                badge = capsuleBadge,
                size = iconSize
            ) {
                PillGlyph(
                    color = Color(0xFFC93400),
                    modifier = Modifier.size(glyphSize)
                )
            }
            Spacer(Modifier.width(8.dp))
            CircleIconButton(onClick = onSettings, size = iconSize) {
                GearGlyph(color = VibePadInk, modifier = Modifier.size(glyphSize))
            }
        }
        return
    }

    Column(
        modifier = Modifier.fillMaxWidth().padding(
            top = if (mode == HeaderMode.Panel) 2.dp else 8.dp,
            bottom = if (mode == HeaderMode.Panel) 2.dp else 10.dp
        )
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = "VibePad",
                fontSize = titleSize,
                fontWeight = FontWeight.SemiBold,
                color = VibePadInk,
                letterSpacing = titleSpacing
            )
            Spacer(Modifier.weight(1f))
            CircleIconButton(
                onClick = onOpenCapsules,
                badge = capsuleBadge,
                size = iconSize
            ) {
                PillGlyph(
                    color = Color(0xFFC93400),
                    modifier = Modifier.size(glyphSize)
                )
            }
            Spacer(Modifier.width(8.dp))
            CircleIconButton(onClick = onSettings, size = iconSize) {
                GearGlyph(color = VibePadInk, modifier = Modifier.size(glyphSize))
            }
        }
        Spacer(Modifier.height(if (dense) 6.dp else 9.dp))
        Row(
            horizontalArrangement = Arrangement.spacedBy(if (dense) 10.dp else 13.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            HeaderStatus(voiceColor, voiceText, small = dense)
            HeaderStatus(macColor, shownMacText, small = dense)
            HeaderStatus(linkColor, shownLinkText, small = dense)
        }
    }
}

@Composable
private fun HeaderStatus(color: Color, text: String, small: Boolean = false) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(if (small) 4.dp else 5.dp).background(color, CircleShape))
        Spacer(Modifier.width(if (small) 4.dp else 5.dp))
        Text(
            text = text,
            fontSize = if (small) 10.sp else 11.sp,
            color = VibePadMuted,
            maxLines = 1
        )
    }
}

@Composable
private fun CircleIconButton(
    onClick: () -> Unit,
    badge: Int = 0,
    size: Dp = 36.dp,
    content: @Composable () -> Unit
) {
    Box {
        Surface(
            onClick = onClick,
            modifier = Modifier.size(size),
            shape = CircleShape,
            color = Color(0xFFE9E9EE)
        ) {
            Box(contentAlignment = Alignment.Center) { content() }
        }
        if (badge > 0) {
            CapsuleBadge(
                count = badge,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .offset(x = 3.dp, y = (-3).dp)
            )
        }
    }
}

/**
 * 徽标圆点。数字用 Canvas 自己测量居中，避开 Text 的字体上下留白：
 * 之前 8sp 的一行字在 15dp 圆里会被压低到圆底。
 */
@Composable
private fun CapsuleBadge(count: Int, modifier: Modifier = Modifier) {
    val measurer = rememberTextMeasurer()
    Canvas(modifier.size(16.dp)) {
        drawCircle(VibePadCoral)
        val layout = measurer.measure(
            text = AnnotatedString(if (count > 9) "9+" else "$count"),
            style = TextStyle(
                color = Color.White,
                fontSize = 9.sp,
                fontWeight = FontWeight.SemiBold,
                platformStyle = PlatformTextStyle(includeFontPadding = false)
            )
        )
        drawText(
            textLayoutResult = layout,
            topLeft = Offset(
                (size.width - layout.size.width) / 2f,
                (size.height - layout.size.height) / 2f
            )
        )
    }
}

// MARK: - Trackpad

@Composable
private fun TrackpadSurface(
    modifier: Modifier,
    sensitivity: Float,
    naturalScroll: Boolean,
    edgeScroll: Boolean,
    haptics: Boolean,
    edgeScrollLeft: Boolean,
    talking: Boolean,
    capsuleRecording: Boolean,
    level: Float,
    capsuleElapsedMs: Long
) {
    val density = LocalDensity.current
    val view = LocalView.current
    val hapticsNow = rememberUpdatedState(haptics)
    val slopPx = with(density) { 10.dp.toPx() }
    val scrollStepPx = with(density) { 14.dp.toPx() }
    val edgePx = with(density) { 72.dp.toPx() }
    val auraVisible = talking || capsuleRecording
    // 说话/录音时手指不在触控区，屏蔽手势，避免误碰移动光标。
    val hintAlpha by animateFloatAsState(
        targetValue = if (auraVisible) 0f else 1f,
        animationSpec = tween(durationMillis = 180),
        label = "padHint"
    )

    val edgeFlag = remember { mutableStateOf(false) }
    val engine = remember(density) {
        GestureEngine(
            callbacks = object : GestureEngine.Callbacks {
                override fun move(dx: Float, dy: Float) = HidDeviceController.move(dx, dy)
                override fun scroll(pan: Int, wheel: Int) {
                    Log.i("VibePadTouch", "scroll pan=$pan wheel=$wheel edge=${edgeFlag.value}")
                    HidDeviceController.scroll(pan, wheel)
                }
                override fun click(button: Int) = HidDeviceController.click(button)
                override fun button(button: Int, down: Boolean) =
                    HidDeviceController.button(button, down)

                override fun haptic() {
                    if (hapticsNow.value) {
                        view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                    }
                }
            },
            slopPx = slopPx,
            scrollStepPx = scrollStepPx,
            edgeZonePx = edgePx
        )
    }
    engine.sensitivity = sensitivity
    engine.naturalScroll = naturalScroll
    engine.edgeScrollEnabled = edgeScroll
    engine.edgeScrollLeft = edgeScrollLeft

    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp)
            .shadow(14.dp, RoundedCornerShape(28.dp))
            .clip(RoundedCornerShape(28.dp))
            .background(
                Brush.radialGradient(
                    listOf(Color(0xFF1D1F26), Color(0xFF0E0F13))
                ),
                RoundedCornerShape(28.dp)
            )
            .border(
                1.dp,
                Brush.verticalGradient(
                    listOf(Color.White.copy(alpha = 0.16f), Color.White.copy(alpha = 0.03f))
                ),
                RoundedCornerShape(28.dp)
            )
            .dotGrid(Color.White.copy(alpha = 0.045f))
            .onSizeChanged { size ->
                // MIUI 的侧边返回会抢走从屏幕边缘起手的触摸，系统侧边手势
                // 区域内的触摸根本到不了这里，边缘滚动因此失效。
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    view.systemGestureExclusionRects =
                        listOf(android.graphics.Rect(0, 0, size.width, size.height))
                }
            }
            .pointerInput(engine, auraVisible) {
                if (auraVisible) return@pointerInput
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    engine.onDown(
                        listOf(down.position),
                        down.uptimeMillis,
                        size.width.toFloat()
                    )
                    edgeFlag.value = engine.isEdgeScrolling
                    Log.i(
                        "VibePadTouch",
                        "down x=${down.position.x.toInt()} w=${size.width} edge=${edgeFlag.value}"
                    )
                    down.consume()
                    while (true) {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.filter { it.pressed }
                        val time = event.changes.firstOrNull()?.uptimeMillis
                            ?: SystemClock.uptimeMillis()
                        if (pressed.isEmpty()) {
                            engine.onUp(time)
                            break
                        }
                        engine.onMove(pressed.map { it.position }, time)
                        event.changes.forEach { it.consume() }
                    }
                }
            }
    ) {
        Text(
            text = "VIBEPAD TOUCH",
            modifier = Modifier.align(Alignment.TopStart).padding(20.dp),
            color = Color.White.copy(alpha = 0.20f),
            fontSize = 9.sp,
            fontFamily = FontFamily.Monospace,
            letterSpacing = 1.5.sp
        )
        Column(
            modifier = Modifier
                .align(Alignment.Center)
                .graphicsLayer { alpha = hintAlpha },
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                text = "触控板",
                color = Color.White.copy(alpha = 0.22f),
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium
            )
            Spacer(Modifier.height(6.dp))
            Text(
                text = "单指移动 / 双指滚动 / 双指轻点右键",
                color = Color.White.copy(alpha = 0.14f),
                fontSize = 11.sp,
                textAlign = TextAlign.Center
            )
        }
        Text(
            text = "按住不动再拖 · 边缘滑动滚动",
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 18.dp)
                .graphicsLayer { alpha = hintAlpha },
            color = Color.White.copy(alpha = 0.14f),
            fontSize = 11.sp
        )
        TrackpadAura(
            visible = auraVisible,
            mode = if (capsuleRecording) AuraMode.Capsule else AuraMode.Voice,
            level = level,
            elapsedMs = capsuleElapsedMs
        )
    }
}

// MARK: - Voice

@Composable
private fun VoiceBar(
    state: PhoneVoiceGattServer.State,
    level: Float,
    leftHanded: Boolean,
    capsuleRecording: Boolean,
    onCapsuleRecording: (Boolean) -> Unit,
    onCapsuleSaved: (String) -> Unit
) {
    val talking = state is PhoneVoiceGattServer.State.Talking
    val voiceReady = state is PhoneVoiceGattServer.State.Connected || talking

    Column(
        modifier = Modifier.fillMaxWidth().padding(top = 6.dp, bottom = 6.dp)
    ) {
        Surface(
            color = Color.White,
            shape = RoundedCornerShape(22.dp),
            shadowElevation = 3.dp
        ) {
            Column(modifier = Modifier.fillMaxWidth().padding(8.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    VoiceKey(
                        modifier = Modifier.weight(1f),
                        talking = talking,
                        ready = voiceReady,
                        level = level
                    )
                    ConfirmKey(
                        modifier = Modifier.width(72.dp),
                        enabled = !talking,
                        height = 56.dp
                    )
                }
                Spacer(Modifier.height(8.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    if (leftHanded) {
                        SwitchKey(Modifier.weight(1f))
                        InterruptKey(Modifier.weight(1f))
                        DeleteKey(Modifier.weight(1f))
                        CapsuleKey(
                            Modifier.weight(1f),
                            recording = capsuleRecording,
                            onRecordingChange = onCapsuleRecording,
                            onSaved = onCapsuleSaved
                        )
                    } else {
                        CapsuleKey(
                            Modifier.weight(1f),
                            recording = capsuleRecording,
                            onRecordingChange = onCapsuleRecording,
                            onSaved = onCapsuleSaved
                        )
                        DeleteKey(Modifier.weight(1f))
                        InterruptKey(Modifier.weight(1f))
                        SwitchKey(Modifier.weight(1f))
                    }
                }
            }
        }
    }
}

@Composable
private fun CapsuleToast(text: String, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier,
        color = Color(0xFF1C1C1E),
        shape = RoundedCornerShape(14.dp),
        shadowElevation = 6.dp
    ) {
        Text(
            text = text,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 9.dp),
            color = Color.White,
            fontSize = 12.sp
        )
    }
}

/** 横屏右侧一栏：上面是 header，下面是按键面板。 */
@Composable
private fun LandscapeSidePanel(
    modifier: Modifier,
    hidState: HidDeviceController.State,
    voiceState: PhoneVoiceGattServer.State,
    macFlags: Int,
    voiceLink: String,
    capsuleBadge: Int,
    onOpenCapsules: () -> Unit,
    onSettings: () -> Unit,
    level: Float,
    leftHanded: Boolean,
    capsuleRecording: Boolean,
    onCapsuleRecording: (Boolean) -> Unit,
    onCapsuleSaved: (String) -> Unit,
    toast: String?
) {
    Column(modifier = modifier) {
        Header(
            hidState = hidState,
            voiceState = voiceState,
            macFlags = macFlags,
            voiceLink = voiceLink,
            capsuleBadge = capsuleBadge,
            mode = HeaderMode.Panel,
            onOpenCapsules = onOpenCapsules,
            onSettings = onSettings
        )
        Spacer(Modifier.height(4.dp))
        LandscapeControls(
            modifier = Modifier.weight(1f).fillMaxWidth(),
            state = voiceState,
            level = level,
            leftHanded = leftHanded,
            capsuleRecording = capsuleRecording,
            onCapsuleRecording = onCapsuleRecording,
            onCapsuleSaved = onCapsuleSaved,
            toast = toast
        )
    }
}

/** 横屏右侧（左手模式在左侧）的按键面板：语音/确认按剩余空间分配，四个小键并成一行。 */
@Composable
private fun LandscapeControls(
    modifier: Modifier,
    state: PhoneVoiceGattServer.State,
    level: Float,
    leftHanded: Boolean,
    capsuleRecording: Boolean,
    onCapsuleRecording: (Boolean) -> Unit,
    onCapsuleSaved: (String) -> Unit,
    toast: String?
) {
    val talking = state is PhoneVoiceGattServer.State.Talking
    val voiceReady = state is PhoneVoiceGattServer.State.Connected || talking

    Surface(
        modifier = modifier,
        color = Color.White,
        shape = RoundedCornerShape(24.dp),
        shadowElevation = 3.dp
    ) {
        Column(Modifier.fillMaxSize().padding(8.dp)) {
            Column(
                modifier = Modifier.weight(1f).fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                VoiceKey(
                    modifier = Modifier.weight(1.6f).fillMaxWidth(),
                    talking = talking,
                    ready = voiceReady,
                    level = level,
                    height = null
                )
                ConfirmKey(
                    modifier = Modifier.weight(0.85f).fillMaxWidth(),
                    enabled = !talking,
                    height = null
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    if (leftHanded) {
                        SwitchKey(Modifier.weight(1f))
                        InterruptKey(Modifier.weight(1f))
                        DeleteKey(Modifier.weight(1f))
                        CapsuleKey(
                            Modifier.weight(1f),
                            recording = capsuleRecording,
                            onRecordingChange = onCapsuleRecording,
                            onSaved = onCapsuleSaved
                        )
                    } else {
                        CapsuleKey(
                            Modifier.weight(1f),
                            recording = capsuleRecording,
                            onRecordingChange = onCapsuleRecording,
                            onSaved = onCapsuleSaved
                        )
                        DeleteKey(Modifier.weight(1f))
                        InterruptKey(Modifier.weight(1f))
                        SwitchKey(Modifier.weight(1f))
                    }
                }
            }
            toast?.let {
                CapsuleToast(it, Modifier.fillMaxWidth().padding(top = 6.dp))
            }
        }
    }
}

@Composable
private fun VoiceKey(
    modifier: Modifier,
    talking: Boolean,
    ready: Boolean,
    level: Float,
    height: Dp? = 56.dp
) {
    var pressed by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(
        targetValue = if (pressed) 0.985f else 1f,
        animationSpec = tween(durationMillis = 100),
        label = "voiceScale"
    )

    Surface(
        modifier = modifier
            .then(if (height != null) Modifier.height(height) else Modifier)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .then(
                if (ready) {
                    Modifier.pointerInput(ready) {
                        detectTapGestures(onPress = {
                            pressed = true
                            PhoneVoiceController.startTalk()
                            try {
                                tryAwaitRelease()
                            } finally {
                                pressed = false
                                PhoneVoiceController.stopTalk()
                            }
                        })
                    }
                } else {
                    Modifier
                }
            ),
        color = when {
            talking -> VibePadCoral
            ready -> VibePadInk
            else -> Color(0xFFE5E5EA)
        },
        shape = RoundedCornerShape(16.dp),
        shadowElevation = if (ready) 4.dp else 0.dp
    ) {
        Row(
            modifier = Modifier.fillMaxSize().padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center
        ) {
            Box(
                modifier = Modifier
                    .size(32.dp)
                    .background(
                        Color.White.copy(alpha = if (ready) 0.10f + 0.12f * level.coerceIn(0f, 1f) else 0.04f),
                        CircleShape
                    ),
                contentAlignment = Alignment.Center
            ) {
                MicGlyph(
                    color = if (ready) Color.White else VibePadMuted,
                    modifier = Modifier.size(17.dp)
                )
            }
            Spacer(Modifier.width(9.dp))
            Column {
                Text(
                    text = when {
                        talking -> "正在听… 松手结束"
                        ready -> "按住说话"
                        else -> "语音等待"
                    },
                    color = if (ready) Color.White else VibePadMuted,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1
                )
                Text(
                    text = when {
                        talking -> "VibeDeck 正在接收"
                        ready -> "VibeDeck · 长按收音"
                        else -> "先连接 Mac"
                    },
                    color = if (ready) Color.White.copy(alpha = 0.52f) else VibePadFaint,
                    fontSize = 9.sp,
                    maxLines = 1
                )
            }
        }
    }
}

@Composable
private fun ConfirmKey(modifier: Modifier, enabled: Boolean, height: Dp? = 48.dp) {
    Surface(
        onClick = { HidDeviceController.keyCombo(0, 0x28) },
        enabled = enabled,
        modifier = modifier.then(if (height != null) Modifier.height(height) else Modifier),
        shape = RoundedCornerShape(14.dp),
        color = if (enabled) VibePadBlue else Color(0xFFE5E5EA),
        contentColor = if (enabled) Color.White else VibePadMuted,
        shadowElevation = if (enabled) 3.dp else 0.dp
    ) {
        Column(
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Text("↵", fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Text("确认", fontSize = 9.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun InterruptKey(modifier: Modifier) {
    Surface(
        onClick = { HidDeviceController.keyCombo(0, 0x29) },
        modifier = modifier.height(48.dp),
        shape = RoundedCornerShape(14.dp),
        color = Color(0xFFEEF0F4),
        contentColor = VibePadInk
    ) {
        Column(
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Text(
                text = "Esc",
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace
            )
            Text(
                text = "打断",
                fontSize = 9.sp,
                fontWeight = FontWeight.SemiBold,
                color = VibePadMuted
            )
        }
    }
}

@Composable
private fun CapsuleKey(
    modifier: Modifier,
    recording: Boolean,
    onRecordingChange: (Boolean) -> Unit,
    onSaved: (String) -> Unit
) {
    val context = LocalContext.current
    val view = LocalView.current

    Surface(
        modifier = modifier
            .height(48.dp)
            .pointerInput(Unit) {
                detectTapGestures(
                    onPress = {
                        view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                        val started = CapsuleRecorder.start(context)
                        if (started) onRecordingChange(true)
                        try {
                            tryAwaitRelease()
                        } finally {
                            view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                            val result = if (started) CapsuleRecorder.stop() else null
                            onRecordingChange(false)
                            if (result != null) {
                                CapsuleStore.add(context, result.first, result.second)
                                onSaved("已存为胶囊 · 待转写")
                            } else {
                                onSaved("录音失败")
                            }
                        }
                    }
                )
            },
        shape = RoundedCornerShape(14.dp),
        color = if (recording) Color(0xFFFFD9C2) else Color(0xFFFFF3E6),
        contentColor = Color(0xFFC93400)
    ) {
        Column(
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            PillGlyph(
                color = Color(0xFFC93400),
                filled = recording,
                modifier = Modifier.size(18.dp)
            )
            Spacer(Modifier.height(2.dp))
            Text(
                text = if (recording) "录音中" else "胶囊",
                fontSize = 9.sp,
                fontWeight = FontWeight.SemiBold
            )
        }
    }
}

@Composable
private fun DeleteKey(modifier: Modifier) {
    val view = LocalView.current
    Surface(
        modifier = modifier
            .height(48.dp)
            .pointerInput(Unit) {
                detectTapGestures(
                    onTap = { HidDeviceController.keyCombo(0, 0x2A) },
                    onLongPress = {
                        view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                        // 长按 = 全选再删除（Cmd+A → Backspace）
                        HidDeviceController.keyCombo(0x08, 0x04)
                        HidDeviceController.keyCombo(0, 0x2A)
                    }
                )
            },
        shape = RoundedCornerShape(14.dp),
        color = Color(0xFFEEF0F4),
        contentColor = VibePadInk
    ) {
        Column(
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            BackspaceGlyph(color = VibePadInk, modifier = Modifier.size(18.dp))
            Spacer(Modifier.height(2.dp))
            Text("删除", fontSize = 9.sp, fontWeight = FontWeight.SemiBold, color = VibePadMuted)
        }
    }
}

@Composable
private fun SwitchKey(modifier: Modifier) {
    Surface(
        onClick = { HidDeviceController.keyCombo(0x08, 0x2B) },
        modifier = modifier.height(48.dp),
        shape = RoundedCornerShape(14.dp),
        color = Color(0xFFEEF0F4),
        contentColor = VibePadInk
    ) {
        Column(
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            SwitchGlyph(color = VibePadInk, modifier = Modifier.size(18.dp))
            Spacer(Modifier.height(2.dp))
            Text("切换", fontSize = 9.sp, fontWeight = FontWeight.SemiBold, color = VibePadMuted)
        }
    }
}




// MARK: - Pairing

@Composable
private fun PairingContent(
    modifier: Modifier,
    hidState: HidDeviceController.State,
    onConnect: (BluetoothDevice) -> Unit
) {
    val context = LocalContext.current
    val devices = remember(hidState) { HidDeviceController.pairedDevices() }
    val savedAddress = remember(hidState) { HidDeviceController.savedTargetAddress() }

    Column(
        modifier = modifier
            .verticalScroll(rememberScrollState())
            .padding(vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(190.dp)
                .clip(RoundedCornerShape(28.dp))
                .background(VibePadPad)
                .dotGrid(Color.White.copy(alpha = 0.045f))
        ) {
            Column(
                modifier = Modifier.align(Alignment.CenterStart).padding(24.dp)
            ) {
                WaveformGlyph(
                    color = Color.White,
                    modifier = Modifier.width(84.dp).height(34.dp)
                )
                Spacer(Modifier.height(12.dp))
                Text(
                    text = "VibePad",
                    color = Color.White,
                    fontSize = 28.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = (-0.5).sp
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "触控板 × 语音",
                    color = Color.White.copy(alpha = 0.45f),
                    fontSize = 12.sp
                )
            }
            Text(
                text = "VIBEDECK READY",
                modifier = Modifier.align(Alignment.BottomEnd).padding(20.dp),
                color = Color.White.copy(alpha = 0.22f),
                fontSize = 9.sp,
                fontFamily = FontFamily.Monospace,
                letterSpacing = 1.sp
            )
        }

        Surface(
            color = Color.White,
            shape = RoundedCornerShape(24.dp),
            shadowElevation = 2.dp
        ) {
            Column(modifier = Modifier.padding(20.dp)) {
                Text(
                    text = "连接 Mac",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = VibePadInk
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    text = "1. 点下面按钮，让 Mac 在蓝牙里发现 VibePad\n" +
                        "2. 在 Mac 上配对并连接\n" +
                        "3. 回到这里点 Mac 名称",
                    fontSize = 13.sp,
                    color = VibePadMuted,
                    lineHeight = 19.sp
                )
                Spacer(Modifier.height(16.dp))
                Button(
                    onClick = { startDiscoverable(context) },
                    modifier = Modifier.fillMaxWidth().height(48.dp),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = VibePadBlue,
                        contentColor = Color.White
                    )
                ) {
                    Text("让 Mac 发现本机", fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
                TextButton(
                    onClick = { openBluetoothSettings(context) },
                    modifier = Modifier.align(Alignment.End)
                ) {
                    Text("打开蓝牙设置", fontSize = 13.sp, color = VibePadMuted)
                }
                Text(
                    text = hidStateText(hidState),
                    fontSize = 11.sp,
                    color = VibePadFaint
                )
            }
        }

        Surface(
            color = Color.White,
            shape = RoundedCornerShape(24.dp),
            shadowElevation = 2.dp
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text(
                    text = "已配对的设备",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = VibePadMuted
                )
                Spacer(Modifier.height(8.dp))
                if (devices.isEmpty()) {
                    Text(
                        text = "还没有已配对设备。先在 Mac 上完成配对；如果列表为空，点“打开蓝牙设置”检查。",
                        fontSize = 12.sp,
                        color = VibePadFaint,
                        lineHeight = 18.sp
                    )
                } else {
                    devices.forEach { device ->
                        DeviceRow(
                            device = device,
                            selected = device.address == savedAddress,
                            onClick = { onConnect(device) }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun DeviceRow(
    device: BluetoothDevice,
    selected: Boolean,
    onClick: () -> Unit
) {
    Surface(
        onClick = onClick,
        color = if (selected) VibePadBlue.copy(alpha = 0.08f) else Color.Transparent,
        shape = RoundedCornerShape(14.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier.size(34.dp).background(Color(0xFFF1F1F4), CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Text("Mac", fontSize = 9.sp, color = VibePadMuted)
            }
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = device.name ?: device.address,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = VibePadInk
                )
                Text(text = device.address, fontSize = 11.sp, color = VibePadFaint)
            }
            Text(
                text = if (selected) "连接" else "选择",
                fontSize = 12.sp,
                color = VibePadBlue
            )
        }
    }
}

// MARK: - Settings sheet

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsSheet(
    sensitivity: Float,
    naturalScroll: Boolean,
    edgeScroll: Boolean,
    haptics: Boolean,
    leftHanded: Boolean,
    hidState: HidDeviceController.State,
    voiceState: PhoneVoiceGattServer.State,
    voiceLink: String,
    onVoiceLink: (String) -> Unit,
    onHandedness: (Boolean) -> Unit,
    onSensitivity: (Float) -> Unit,
    onNaturalScroll: (Boolean) -> Unit,
    onEdgeScroll: (Boolean) -> Unit,
    onHaptics: (Boolean) -> Unit,
    onDismiss: () -> Unit
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color.White,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .padding(bottom = 32.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "设置",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = VibePadInk
                )
                Spacer(Modifier.weight(1f))
                TextButton(onClick = onDismiss) {
                    Text("完成", fontSize = 13.sp, color = VibePadBlue)
                }
            }

            SectionLabel("触控")
            HandednessRow(leftHanded = leftHanded, onChange = onHandedness)
            SheetSlider(
                title = "灵敏度",
                value = sensitivity,
                range = 0.5f..3.0f,
                onChange = onSensitivity
            )
            SheetToggle("自然滚动", naturalScroll, onNaturalScroll)
            SheetToggle("边缘滚动", edgeScroll, onEdgeScroll)
            Text(
                text = "右手持机：语音键在左、按键在右、边缘滚动在右侧；左手则镜像。",
                modifier = Modifier.padding(top = 2.dp, bottom = 4.dp),
                fontSize = 11.sp,
                color = VibePadFaint,
                lineHeight = 16.sp
            )
            SheetToggle("触觉反馈", haptics, onHaptics)

            Spacer(Modifier.height(18.dp))
            SectionLabel("诊断")
            MicTestRow()

            Spacer(Modifier.height(18.dp))
            SectionLabel("语音链路")
            VoiceLinkRow(current = voiceLink, onChange = onVoiceLink)
            Text(
                text = if (voiceLink == PhoneVoiceController.LINK_WIFI) {
                    "Wi-Fi：16 kHz 无损，需要手机和 Mac 在同一局域网。触控板仍走蓝牙。"
                } else {
                    "蓝牙：不依赖网络，离开电脑所在 Wi-Fi 也能用。"
                },
                modifier = Modifier.padding(top = 2.dp, bottom = 4.dp),
                fontSize = 11.sp,
                color = VibePadFaint,
                lineHeight = 16.sp
            )

            Spacer(Modifier.height(18.dp))
            SectionLabel("连接")
            SheetStatusRow("触控板", hidStateText(hidState))
            SheetStatusRow("语音", voiceStateText(voiceState))
            TextButton(onClick = { PhoneVoiceController.restart() }) {
                Text("重新广播语音", fontSize = 13.sp, color = VibePadBlue)
            }

            Text(
                text = "ZCode / Cursor 不在完全访问模式时，发送/允许点「确认」（Enter）；要中断当前生成点「打断」（Esc）。",
                modifier = Modifier.padding(top = 8.dp),
                fontSize = 11.sp,
                color = VibePadFaint,
                lineHeight = 16.sp
            )

            Spacer(Modifier.height(18.dp))
            Text(
                text = "VibePad 0.1.0 · 配合 VibeDeck 使用",
                fontSize = 11.sp,
                color = VibePadFaint
            )
        }
    }
}

@Composable
private fun VoiceLinkRow(current: String, onChange: (String) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text("传输方式", fontSize = 14.sp, color = VibePadInk)
        Spacer(Modifier.weight(1f))
        Row(
            modifier = Modifier
                .background(Color(0xFFF1F1F4), RoundedCornerShape(10.dp))
                .padding(2.dp)
        ) {
            HandednessOption(
                "蓝牙",
                selected = current == PhoneVoiceController.LINK_BLE
            ) { onChange(PhoneVoiceController.LINK_BLE) }
            HandednessOption(
                "Wi-Fi",
                selected = current == PhoneVoiceController.LINK_WIFI
            ) { onChange(PhoneVoiceController.LINK_WIFI) }
        }
    }
}

@Composable
private fun MicTestRow() {
    val context = LocalContext.current
    var running by remember { mutableStateOf(false) }
    var status by remember {
        mutableStateOf("依次用 3 种采集源各录 4 秒，存成 wav 供试听")
    }
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text("手机录音自测", fontSize = 14.sp, color = VibePadInk)
            Text(
                text = status,
                fontSize = 11.sp,
                color = VibePadFaint,
                lineHeight = 15.sp
            )
        }
        TextButton(
            onClick = {
                if (running) return@TextButton
                running = true
                status = "录音中，请正常说话…"
                Thread {
                    val result = runCatching { MicTester.recordAll(context) }.getOrNull()
                    Handler(Looper.getMainLooper()).post {
                        running = false
                        status = when {
                            result == null -> "录音失败"
                            result.files.isEmpty() -> "没有录到声音"
                            else -> "已保存 ${result.files.size} 个 wav · Android/data/com.vibepad/files"
                        }
                    }
                }.start()
            }
        ) {
            Text(if (running) "录制中…" else "开始", fontSize = 13.sp, color = VibePadBlue)
        }
    }
}

@Composable
private fun HandednessRow(leftHanded: Boolean, onChange: (Boolean) -> Unit) {    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text("惯用手", fontSize = 14.sp, color = VibePadInk)
        Spacer(Modifier.weight(1f))
        Row(
            modifier = Modifier
                .background(Color(0xFFF1F1F4), RoundedCornerShape(10.dp))
                .padding(2.dp)
        ) {
            HandednessOption("右手", selected = !leftHanded) { onChange(false) }
            HandednessOption("左手", selected = leftHanded) { onChange(true) }
        }
    }
}

@Composable
private fun HandednessOption(
    label: String,
    selected: Boolean,
    onClick: () -> Unit
) {
    Surface(
        onClick = onClick,
        color = if (selected) Color.White else Color.Transparent,
        shape = RoundedCornerShape(8.dp),
        shadowElevation = if (selected) 1.dp else 0.dp
    ) {
        Text(
            text = label,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp),
            fontSize = 12.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) VibePadInk else VibePadMuted
        )
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text = text,
        modifier = Modifier.padding(top = 16.dp, bottom = 6.dp),
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        color = VibePadMuted
    )
}

@Composable
private fun SheetSlider(
    title: String,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    onChange: (Float) -> Unit
) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, fontSize = 14.sp, color = VibePadInk)
            Spacer(Modifier.weight(1f))
            Text(
                text = String.format("%.2f×", value),
                fontSize = 12.sp,
                color = VibePadMuted,
                fontFamily = FontFamily.Monospace
            )
        }
        Slider(
            value = value,
            onValueChange = onChange,
            valueRange = range,
            colors = SliderDefaults.colors(
                thumbColor = VibePadBlue,
                activeTrackColor = VibePadBlue,
                inactiveTrackColor = Color(0xFFE5E5EA)
            )
        )
    }
}

@Composable
private fun SheetToggle(
    title: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(title, fontSize = 14.sp, color = VibePadInk)
        Spacer(Modifier.weight(1f))
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Color.White,
                checkedTrackColor = VibePadGreen,
                uncheckedThumbColor = Color.White,
                uncheckedTrackColor = Color(0xFFD1D1D6)
            )
        )
    }
}

@Composable
private fun SheetStatusRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(label, fontSize = 14.sp, color = VibePadInk)
        Spacer(Modifier.weight(1f))
        Text(
            text = value,
            fontSize = 12.sp,
            color = VibePadMuted,
            textAlign = TextAlign.End
        )
    }
}

// MARK: - Glyphs

@Composable
private fun WaveformGlyph(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val bars = listOf(0.28f, 0.46f, 0.72f, 0.40f, 0.92f, 0.55f, 0.34f, 0.66f, 0.44f)
        val gap = size.width * 0.035f
        val barW = (size.width - gap * (bars.size - 1)) / bars.size
        bars.forEachIndexed { index, fraction ->
            val barH = size.height * fraction
            drawRoundRect(
                color = color,
                topLeft = Offset(index * (barW + gap), (size.height - barH) / 2),
                size = Size(barW, barH),
                cornerRadius = CornerRadius(barW / 2, barW / 2)
            )
        }
    }
}

// MARK: - Helpers

private fun Modifier.dotGrid(color: Color, step: Dp = 26.dp): Modifier = drawBehind {
    val stepPx = step.toPx()
    var x = stepPx / 2
    while (x < size.width) {
        var y = stepPx / 2
        while (y < size.height) {
            drawCircle(color, radius = 1.1.dp.toPx(), center = Offset(x, y))
            y += stepPx
        }
        x += stepPx
    }
}

private fun startDiscoverable(context: Context) {
    val intent = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE).apply {
        putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 300)
    }
    runCatching { context.startActivity(intent) }
}

private fun openBluetoothSettings(context: Context) {
    runCatching { context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS)) }
}

private fun hidStateText(state: HidDeviceController.State): String = when (state) {
    HidDeviceController.State.Idle -> "HID 未启动"
    HidDeviceController.State.BluetoothOff -> "蓝牙未开启"
    HidDeviceController.State.NoPermission -> "缺少蓝牙权限"
    HidDeviceController.State.Registering -> "正在注册 HID…"
    HidDeviceController.State.Registered -> "HID 已注册，等待连接"
    is HidDeviceController.State.Connecting -> "正在连接 ${state.name}"
    is HidDeviceController.State.Connected -> "已连接 ${state.name}"
    is HidDeviceController.State.Error -> state.message
}

private fun voiceStateText(state: PhoneVoiceGattServer.State): String = when (state) {
    PhoneVoiceGattServer.State.Idle -> "语音未启用"
    PhoneVoiceGattServer.State.Advertising -> "语音等待 Mac 连接"
    is PhoneVoiceGattServer.State.Connected -> "语音已连接"
    PhoneVoiceGattServer.State.Talking -> "语音正在传输"
    is PhoneVoiceGattServer.State.Error -> state.message
}
