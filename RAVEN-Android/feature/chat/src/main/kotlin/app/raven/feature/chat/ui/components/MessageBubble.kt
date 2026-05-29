package app.raven.feature.chat.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Done
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.raven.core.design.RavenPalette
import app.raven.core.design.Spacing
import app.raven.feature.chat.data.ChatMessage
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * One chat message bubble — pixel-port of iOS `MessageBubbleView`'s
 * core shape (BubbleShape with 6dp tail offset).
 *
 *   • From-me bubble (purple gradient, right-aligned)
 *   • From-peer bubble (surface-card, left-aligned)
 *   • Reply preview pill on top when message is a reply
 *   • Bottom-right time + delivery tick row (only on from-me)
 *
 * Phase 2 only supports plain text + reply preview. Voice / image /
 * file / location bubbles land in Phase 2b alongside the
 * attachment picker.
 */
@Composable
fun MessageBubble(
    message: ChatMessage,
    modifier: Modifier = Modifier,
) {
    val isFromMe = message.isFromMe
    val bgColor = if (isFromMe) RavenPalette.Purple else MaterialTheme.colorScheme.surfaceVariant
    val fgColor = if (isFromMe) Color.White else MaterialTheme.colorScheme.onSurface
    val align = if (isFromMe) Alignment.End else Alignment.Start
    // Tail-bias shape — outer corner facing the tail-side is smaller.
    val shape = if (isFromMe) {
        RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp, bottomStart = 18.dp, bottomEnd = 4.dp)
    } else {
        RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp, bottomStart = 4.dp, bottomEnd = 18.dp)
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = Spacing.md, vertical = 2.dp),
        horizontalAlignment = align,
    ) {
        Box(
            modifier = Modifier
                .widthIn(max = 280.dp)
                .clip(shape)
                .background(bgColor)
                .padding(horizontal = 12.dp, vertical = 8.dp),
        ) {
            Column {
                if (message.replyToMessageId != null) {
                    ReplyPreviewPill(
                        senderName = message.replyToSenderName ?: "Reply",
                        preview = message.replyToPreview.orEmpty(),
                        isFromMe = isFromMe,
                    )
                    Spacer(Modifier.size(4.dp))
                }

                Text(
                    text = message.content,
                    style = MaterialTheme.typography.bodyLarge,
                    color = fgColor,
                )

                Spacer(Modifier.size(2.dp))

                Row(
                    modifier = Modifier.align(Alignment.End),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        text = message.timestamp.atZone(ZoneId.systemDefault())
                            .format(DateTimeFormatter.ofPattern("HH:mm")),
                        style = MaterialTheme.typography.labelSmall,
                        color = fgColor.copy(alpha = 0.65f),
                    )
                    if (isFromMe) {
                        DeliveryTick(message = message, color = fgColor.copy(alpha = 0.65f))
                    }
                }
            }
        }
    }
}

@Composable
private fun ReplyPreviewPill(
    senderName: String,
    preview: String,
    isFromMe: Boolean,
) {
    val bg = if (isFromMe) {
        Color.White.copy(alpha = 0.18f)
    } else MaterialTheme.colorScheme.primary.copy(alpha = 0.10f)
    val fg = if (isFromMe) Color.White else MaterialTheme.colorScheme.onSurface
    val accent = if (isFromMe) Color.White else MaterialTheme.colorScheme.primary
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .background(bg)
            .padding(horizontal = 8.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(width = 3.dp, height = 28.dp)
                .background(accent, RoundedCornerShape(2.dp)),
        )
        Spacer(Modifier.size(8.dp))
        Column {
            Text(
                text = senderName,
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                color = accent,
            )
            Text(
                text = preview,
                style = MaterialTheme.typography.bodySmall,
                color = fg.copy(alpha = 0.8f),
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun DeliveryTick(message: ChatMessage, color: Color) {
    val icon = if (message.isRead || message.isDelivered) Icons.Filled.DoneAll else Icons.Filled.Done
    val tint = if (message.isRead) RavenPalette.Emerald else color
    Icon(
        imageVector = icon,
        contentDescription = if (message.isRead) "Read" else if (message.isDelivered) "Delivered" else "Sent",
        modifier = Modifier.size(14.dp),
        tint = tint,
    )
}
