package app.raven.feature.notifications.state

import app.raven.feature.notifications.data.AppNotification

data class NotificationsUiState(
    val notifications: List<AppNotification> = emptyList(),
    val isLoading: Boolean = true,
    val errorMessage: String? = null,
) {
    /** Number of unread notifications — drives the feed bell badge. */
    val unreadCount: Int get() = notifications.count { !it.isRead }
    val hasUnread: Boolean get() = unreadCount > 0
    val isEmpty: Boolean get() = !isLoading && errorMessage == null && notifications.isEmpty()
}
