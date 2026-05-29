package app.raven.feature.notifications.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/**
 * Wire DTO for GET /api/notifications — mirror of `NotificationResponse`
 * in `server/routers/notifications.py`.
 *
 * `data` is a free-form JSON object whose shape depends on [type]
 * (e.g. a "like" carries `liker_username` + `post_id`), so it's kept
 * as a raw [JsonObject] and interpreted per-type in [AppNotification].
 */
@Serializable
data class NotificationDto(
    val id: String,
    val type: String = "",
    val data: JsonObject = JsonObject(emptyMap()),
    val timestamp: String,
    @SerialName("is_read") val isRead: Boolean = false,
)
