package app.raven.feature.notifications.data

import javax.inject.Inject
import javax.inject.Singleton

/** Network-backed repository for the notifications feed. */
@Singleton
class NotificationsRepository @Inject constructor(
    private val api: NotificationsApi,
) {

    suspend fun notifications(): List<AppNotification> =
        api.getNotifications().map { AppNotification.from(it) }

    suspend fun markAllRead() {
        api.markAllRead()
    }

    suspend fun markRead(id: String) {
        api.markRead(id)
    }
}
