package app.raven.feature.feed.ui.components

import android.media.MediaPlayer
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import app.raven.core.design.RavenBrandGradient
import app.raven.core.design.Spacing
import kotlinx.coroutines.delay

/**
 * Inline audio player for a voice post — mirror of the iOS voice-post
 * bubble. A brand-gradient play/pause control, a scrubber that fills
 * as it plays, and an m:ss counter.
 *
 * Streams the audio with the platform [MediaPlayer]. The player is
 * released when the card leaves composition (LazyColumn scroll-off),
 * so only the cards on screen ever hold a decoder.
 */
@Composable
fun VoicePostPlayer(
    url: String,
    durationSec: Int,
    modifier: Modifier = Modifier,
) {
    var isPlaying by remember(url) { mutableStateOf(false) }
    var isLoading by remember(url) { mutableStateOf(false) }
    var prepared by remember(url) { mutableStateOf(false) }
    var positionMs by remember(url) { mutableIntStateOf(0) }
    var totalMs by remember(url) { mutableIntStateOf((durationSec * 1000).coerceAtLeast(1)) }

    val player = remember(url) { MediaPlayer() }

    DisposableEffect(url) {
        player.setOnPreparedListener { mp ->
            prepared = true
            isLoading = false
            if (mp.duration > 0) totalMs = mp.duration
            mp.start()
            isPlaying = true
        }
        player.setOnCompletionListener {
            isPlaying = false
            positionMs = 0
        }
        player.setOnErrorListener { mp, _, _ ->
            isPlaying = false
            isLoading = false
            prepared = false
            runCatching { mp.reset() }
            true
        }
        onDispose { runCatching { player.release() } }
    }

    // Tick the scrubber forward only while actually playing.
    LaunchedEffect(isPlaying) {
        while (isPlaying) {
            positionMs = runCatching { player.currentPosition }.getOrDefault(positionMs)
            delay(120)
        }
    }

    val onToggle = {
        when {
            isLoading -> Unit
            isPlaying -> {
                runCatching { player.pause() }
                isPlaying = false
            }
            prepared -> {
                runCatching { player.start() }
                isPlaying = true
            }
            else -> {
                isLoading = true
                val started = runCatching {
                    player.setDataSource(url)
                    player.prepareAsync()
                }.isSuccess
                if (!started) isLoading = false
            }
        }
    }

    val fraction = (positionMs.toFloat() / totalMs).coerceIn(0f, 1f)
    val shownMs = if (isPlaying || positionMs > 0) positionMs else totalMs

    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
            .padding(Spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.sm),
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(RavenBrandGradient)
                .clickable(onClick = onToggle),
            contentAlignment = Alignment.Center,
        ) {
            if (isLoading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(20.dp),
                    strokeWidth = 2.dp,
                    color = Color.White,
                )
            } else {
                Icon(
                    imageVector = if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = if (isPlaying) "Pause" else "Play",
                    tint = Color.White,
                    modifier = Modifier.size(22.dp),
                )
            }
        }

        Box(
            modifier = Modifier
                .weight(1f)
                .height(5.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(MaterialTheme.colorScheme.outline.copy(alpha = 0.4f)),
        ) {
            if (fraction > 0f) {
                Box(
                    modifier = Modifier
                        .fillMaxHeight()
                        .fillMaxWidth(fraction)
                        .clip(RoundedCornerShape(3.dp))
                        .background(RavenBrandGradient),
                )
            }
        }

        Text(
            text = formatTime(shownMs),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** Milliseconds → `m:ss`. */
private fun formatTime(ms: Int): String {
    val totalSec = (ms / 1000).coerceAtLeast(0)
    return "%d:%02d".format(totalSec / 60, totalSec % 60)
}
