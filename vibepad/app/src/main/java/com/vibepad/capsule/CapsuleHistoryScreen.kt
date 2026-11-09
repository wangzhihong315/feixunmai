package com.vibepad.capsule

import android.media.MediaPlayer
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vibepad.VibePadBackground
import com.vibepad.VibePadCoral
import com.vibepad.VibePadFaint
import com.vibepad.VibePadGreen
import com.vibepad.VibePadInk
import com.vibepad.VibePadMuted
import com.vibepad.ui.ChevronLeftGlyph
import com.vibepad.ui.PillGlyph
import com.vibepad.ui.PlayGlyph
import com.vibepad.ui.StopGlyph
import kotlinx.coroutines.delay

/**
 * 闪念胶囊历史：录音留在本机，可以直接试听确认效果；
 * 转写发生在 Mac 端（豆包），这里不做识别。
 */
@Composable
fun CapsuleHistoryScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    // 订阅 store 版本号，增删后自动刷新。
    val revision = CapsuleStore.revision
    val items = remember(revision) { CapsuleStore.all() }
    val pending = items.count { it.text.isNullOrEmpty() }
    var confirmClear by remember { mutableStateOf(false) }
    var playingId by remember { mutableStateOf<String?>(null) }
    var playProgress by remember { mutableFloatStateOf(0f) }
    val player = remember { mutableStateOf<MediaPlayer?>(null) }
    BackHandler { onBack() }

    fun stopAudio() {
        player.value?.let { mp ->
            runCatching { mp.stop() }
            runCatching { mp.release() }
        }
        player.value = null
        playingId = null
        playProgress = 0f
    }

    fun toggleAudio(capsule: Capsule) {
        if (playingId == capsule.id) {
            stopAudio()
            return
        }
        stopAudio()
        val mp = MediaPlayer()
        val started = runCatching {
            mp.setDataSource(capsule.file.absolutePath)
            mp.prepare()
            mp.start()
        }.isSuccess
        if (!started) {
            runCatching { mp.release() }
            return
        }
        mp.setOnCompletionListener { stopAudio() }
        player.value = mp
        playingId = capsule.id
    }

    DisposableEffect(Unit) {
        onDispose { stopAudio() }
    }

    // 播放时每 80ms 刷新进度条。
    LaunchedEffect(playingId) {
        while (playingId != null) {
            val mp = player.value
            if (mp != null) {
                val duration = runCatching { mp.duration }.getOrDefault(1).coerceAtLeast(1)
                val position = runCatching { mp.currentPosition }.getOrDefault(0)
                playProgress = (position.toFloat() / duration).coerceIn(0f, 1f)
            }
            delay(80)
        }
    }

    Surface(modifier = Modifier.fillMaxSize(), color = VibePadBackground) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .systemBarsPadding()
                .padding(horizontal = 18.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp, bottom = 2.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Surface(
                    onClick = onBack,
                    modifier = Modifier.size(36.dp),
                    shape = CircleShape,
                    color = Color(0xFFE9E9EE)
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        ChevronLeftGlyph(
                            color = VibePadInk,
                            modifier = Modifier.size(18.dp)
                        )
                    }
                }
                Spacer(Modifier.width(12.dp))
                Text(
                    text = "闪念胶囊",
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = VibePadInk
                )
                Spacer(Modifier.weight(1f))
                // 同步状态与标题同排，省掉一整行高度。
                if (items.isNotEmpty()) {
                    Box(
                        Modifier
                            .size(5.dp)
                            .background(
                                if (pending > 0) Color(0xFFFF9F0A) else VibePadGreen,
                                CircleShape
                            )
                    )
                    Spacer(Modifier.width(5.dp))
                    Text(
                        text = if (pending > 0) "$pending 条待转写" else "全部已转写",
                        fontSize = 11.sp,
                        color = VibePadMuted,
                        maxLines = 1
                    )
                }
                if (items.isNotEmpty()) {
                    TextButton(onClick = { confirmClear = true }) {
                        Text("清空", fontSize = 13.sp, color = VibePadCoral)
                    }
                } else {
                    Spacer(Modifier.width(8.dp))
                }
            }

            if (items.isEmpty()) {
                EmptyState(Modifier.weight(1f))
            } else {
                // 横屏自动铺成 3 列（更宽平板更多）；竖屏仍是单列。
                LazyVerticalGrid(
                    columns = GridCells.Adaptive(minSize = 260.dp),
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(top = 10.dp, bottom = 28.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    items(items, key = { it.id }) { capsule ->
                        CapsuleCard(
                            capsule = capsule,
                            playing = playingId == capsule.id,
                            progress = if (playingId == capsule.id) playProgress else 0f,
                            onTogglePlay = { toggleAudio(capsule) },
                            onDelete = {
                                if (playingId == capsule.id) stopAudio()
                                CapsuleStore.delete(context, capsule.id)
                            }
                        )
                    }
                }
            }
        }
    }

    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("清空全部胶囊？", fontSize = 16.sp) },
            text = { Text("录音文件会一起删除，无法恢复。", fontSize = 13.sp, color = VibePadMuted) },
            confirmButton = {
                TextButton(onClick = {
                    stopAudio()
                    CapsuleStore.deleteAll(context)
                    confirmClear = false
                }) {
                    Text("删除", color = VibePadCoral, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmClear = false }) {
                    Text("取消", color = VibePadMuted)
                }
            }
        )
    }
}

@Composable
private fun CapsuleCard(
    capsule: Capsule,
    playing: Boolean,
    progress: Float,
    onTogglePlay: () -> Unit,
    onDelete: () -> Unit
) {
    Surface(
        color = Color.White,
        shape = RoundedCornerShape(18.dp),
        shadowElevation = 1.dp
    ) {
        Column(Modifier.fillMaxWidth().padding(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(5.dp)
                        .background(
                            if (!capsule.text.isNullOrEmpty()) VibePadGreen else Color(0xFFFF9F0A),
                            CircleShape
                        )
                )
                Spacer(Modifier.width(6.dp))
                Text(capsule.timeLabel, fontSize = 11.sp, color = VibePadMuted)
                Text(" · ", fontSize = 11.sp, color = VibePadFaint)
                Text(capsule.durationLabel, fontSize = 11.sp, color = VibePadFaint)
                Spacer(Modifier.weight(1f))
                Text(
                    text = if (!capsule.text.isNullOrEmpty()) "已转写" else "待转写",
                    fontSize = 10.sp,
                    color = if (!capsule.text.isNullOrEmpty()) VibePadGreen else Color(0xFFC93400),
                    fontWeight = FontWeight.Medium
                )
            }
            Spacer(Modifier.height(7.dp))
            Text(
                text = capsule.text ?: "等待 Mac 转写…",
                fontSize = 14.sp,
                lineHeight = 20.sp,
                color = if (capsule.text != null) VibePadInk else VibePadFaint,
                maxLines = 4,
                overflow = TextOverflow.Ellipsis
            )
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Surface(
                    onClick = onTogglePlay,
                    shape = RoundedCornerShape(999.dp),
                    color = if (playing) Color(0xFFFFE3D2) else Color(0xFFFFF3E6)
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        if (playing) {
                            StopGlyph(
                                color = Color(0xFFC93400),
                                modifier = Modifier.size(9.dp)
                            )
                        } else {
                            PlayGlyph(
                                color = Color(0xFFC93400),
                                modifier = Modifier.size(9.dp)
                            )
                        }
                        Spacer(Modifier.width(5.dp))
                        Text(
                            text = if (playing) "停止" else "播放",
                            fontSize = 11.sp,
                            color = Color(0xFFC93400),
                            fontWeight = FontWeight.Medium
                        )
                    }
                }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = onDelete) {
                    Text("删除", fontSize = 12.sp, color = VibePadFaint)
                }
            }
            if (playing) {
                Spacer(Modifier.height(4.dp))
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(2.dp)
                        .background(Color(0x1FFFC064), RoundedCornerShape(999.dp))
                ) {
                    Box(
                        Modifier
                            .fillMaxWidth(progress)
                            .height(2.dp)
                            .background(Color(0xFFFF9F0A), RoundedCornerShape(999.dp))
                    )
                }
            }
        }
    }
}

@Composable
private fun EmptyState(modifier: Modifier) {
    Column(
        modifier = modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Box(
            modifier = Modifier
                .size(72.dp)
                .background(Color(0xFFFFF3E6), RoundedCornerShape(24.dp)),
            contentAlignment = Alignment.Center
        ) {
            PillGlyph(
                color = Color(0xFFC93400),
                modifier = Modifier.size(30.dp)
            )
        }
        Spacer(Modifier.height(16.dp))
        Text("还没有胶囊", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = VibePadInk)
        Spacer(Modifier.height(6.dp))
        Text(
            "在触控板下方按住「胶囊」说话\n松手即存，Mac 连上后自动转写",
            fontSize = 12.sp,
            lineHeight = 18.sp,
            color = VibePadMuted,
            textAlign = TextAlign.Center
        )
    }
}
