package app.raven.feature.chat.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.raven.core.design.RavenPalette

/**
 * Counter pill the iOS inbox uses next to each conversation row.
 *   • Hidden when [count] == 0
 *   • "99+" cap above 99
 *   • Muted variant uses the secondary text colour at 60 % alpha
 */
@Composable
fun UnreadBadge(count: Int, isMuted: Boolean = false) {
    if (count <= 0) return
    val label = if (count > 99) "99+" else count.toString()
    val bg = if (isMuted) MaterialTheme.colorScheme.outline.copy(alpha = 0.6f) else RavenPalette.Purple
    Box(
        modifier = Modifier
            .defaultMinSize(minWidth = 20.dp, minHeight = 20.dp)
            .background(bg, CircleShape)
            .padding(horizontal = 6.dp, vertical = 2.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            color = Color.White,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
        )
    }
}
