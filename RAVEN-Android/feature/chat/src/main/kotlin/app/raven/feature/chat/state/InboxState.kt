package app.raven.feature.chat.state

import app.raven.feature.chat.data.Conversation

/**
 * The inbox-screen UI model. Maps 1-1 with iOS `ConversationStore.shared`
 * surface — same loading / error / empty / loaded states, same
 * client-side filter chips.
 */
data class InboxUiState(
    val isLoading: Boolean = false,
    val conversations: List<Conversation> = emptyList(),
    val errorMessage: String? = null,
    val searchQuery: String = "",
    val filter: InboxFilter = InboxFilter.All,
) {
    /** Conversations after applying the [filter] + [searchQuery]. */
    val visibleConversations: List<Conversation>
        get() {
            val pool = if (filter == InboxFilter.Unread) {
                conversations.filter { it.unreadCount > 0 }
            } else conversations

            val q = searchQuery.trim()
            if (q.isEmpty()) return pool
            val needle = q.lowercase()
            return pool.filter { c ->
                c.title.lowercase().contains(needle) ||
                    c.lastMessagePreview?.lowercase()?.contains(needle) == true
            }
        }

    /** True when the user has zero conversations AND we're not in an error
     *  / loading state. Used to render the iOS `EmptyMessagesStateView`. */
    val isEmpty: Boolean
        get() = !isLoading && errorMessage == null && conversations.isEmpty()
}

enum class InboxFilter(val label: String) {
    All("All"),
    Unread("Unread"),
}
