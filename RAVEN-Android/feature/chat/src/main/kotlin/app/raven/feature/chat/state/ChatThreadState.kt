package app.raven.feature.chat.state

import app.raven.feature.chat.data.ChatMessage
import app.raven.feature.chat.data.ChatPeer

data class ChatThreadUiState(
    val peer: ChatPeer? = null,
    /** True when this thread is a group conversation. */
    val isGroup: Boolean = false,
    val messages: List<ChatMessage> = emptyList(),
    val isLoading: Boolean = false,
    val isSending: Boolean = false,
    val errorMessage: String? = null,
    val draft: String = "",
)
