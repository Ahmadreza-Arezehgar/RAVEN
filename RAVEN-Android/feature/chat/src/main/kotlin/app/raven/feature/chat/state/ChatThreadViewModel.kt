package app.raven.feature.chat.state

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.raven.core.security.TokenStore
import app.raven.feature.chat.data.ChatPeer
import app.raven.feature.chat.data.ChatRepository
import app.raven.feature.chat.data.cleanNameOrNull
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Single-conversation VM. Same cache-first pattern as
 * [InboxViewModel] — observe a Flow from [ChatRepository], sync
 * lazily from REST on open.
 *
 * Once /ws/inbox is connected, new incoming messages land in Room
 * via [ChatRepository.startRealtime] and the observe Flow lights up
 * — no manual push needed here.
 *
 * iOS `MessageStore` does the same: it subscribes to the Core Data
 * NSFetchedResultsController for the conversation and lets the
 * realtime layer poke entities into the store.
 */
@HiltViewModel
class ChatThreadViewModel @Inject constructor(
    private val repo: ChatRepository,
    private val tokenStore: TokenStore,
    savedStateHandle: SavedStateHandle,
) : ViewModel() {

    private val peerUserId: String = savedStateHandle.get<String>("peerUserId").orEmpty()
    private val peerUsername: String = savedStateHandle.get<String>("peerUsername").orEmpty()
    // Drop ciphertext that may have leaked into the name nav arg —
    // the header falls back to the username instead.
    private val peerDisplayName: String =
        cleanNameOrNull(savedStateHandle.get<String>("peerDisplayName")).orEmpty()
    private val peerAvatarUrl: String? = savedStateHandle.get<String>("peerAvatarUrl")
    private val isGroup: Boolean = savedStateHandle.get<Boolean>("isGroup") ?: false

    private val _state = MutableStateFlow(
        ChatThreadUiState(
            peer = ChatPeer(
                userId = peerUserId,
                username = peerUsername,
                displayName = peerDisplayName.ifBlank { peerUsername },
                avatarUrl = peerAvatarUrl,
                isVerified = false,
                isPremium = false,
            ),
            isGroup = isGroup,
            isLoading = true,
        )
    )
    val state: StateFlow<ChatThreadUiState> = _state.asStateFlow()

    init {
        // Hot-stream messages from Room into UI state.
        viewModelScope.launch {
            repo.observeThread(peerUserId).collect { msgs ->
                _state.update { it.copy(messages = msgs) }
            }
        }
        loadThread()
    }

    fun loadThread() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, errorMessage = null) }
            runCatching { repo.syncThread(peerUserId) }
                .onSuccess {
                    _state.update { it.copy(isLoading = false) }
                    // Mark visible incoming messages as read in the
                    // background. iOS `MessageStore.markVisibleRead`
                    // does the same once the thread renders.
                    val incomingUnreadIds = _state.value.messages
                        .filter { !it.isFromMe && !it.isRead }
                        .map { it.id }
                    if (incomingUnreadIds.isNotEmpty()) {
                        runCatching { repo.markRead(incomingUnreadIds) }
                    }
                }
                .onFailure { t ->
                    _state.update {
                        it.copy(
                            isLoading = false,
                            errorMessage = t.message ?: "Failed to load conversation.",
                        )
                    }
                }
        }
    }

    fun setDraft(value: String) {
        _state.update { it.copy(draft = value) }
    }

    fun send() {
        val text = _state.value.draft.trim()
        if (text.isEmpty() || _state.value.isSending) return
        viewModelScope.launch {
            _state.update { it.copy(isSending = true, draft = "") }
            runCatching { repo.sendText(peerUserId, text) }
                .onSuccess {
                    // Cache write inside the repo already flipped
                    // the observe Flow; we just clear the sending
                    // flag here.
                    _state.update { it.copy(isSending = false) }
                }
                .onFailure { t ->
                    _state.update {
                        it.copy(
                            isSending = false,
                            draft = text,  // restore for retry
                            errorMessage = t.message ?: "Send failed.",
                        )
                    }
                }
        }
    }
}
