package app.raven.feature.chat.state

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.raven.feature.chat.data.ChatRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Inbox screen VM. Cache-first: subscribes to
 * [ChatRepository.observeInbox] (Room Flow) for the live list,
 * and fires [refresh] to pull fresh data from the server.
 * Once the WebSocket is connected, incoming messages funnel into
 * the same cache and re-render here without an explicit pull.
 *
 * Mirror of iOS `ConversationStore.shared` — same public surface,
 * different implementation (Flow + Room replaces @Observable +
 * manual array).
 */
@HiltViewModel
class InboxViewModel @Inject constructor(
    private val repo: ChatRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(InboxUiState(isLoading = true))
    val state: StateFlow<InboxUiState> = _state.asStateFlow()

    init {
        // Hot-stream the cache into UI state. Room orders the rows
        // (`is_pinned DESC, updated_at DESC`) so we don't re-sort.
        viewModelScope.launch {
            repo.observeInbox().collect { list ->
                _state.update { it.copy(conversations = list) }
            }
        }
        refresh()
    }

    /** Pull-to-refresh hook. Suppresses the loading spinner if we
     *  already have cached data on screen — quiet background sync. */
    fun refresh() {
        viewModelScope.launch {
            val hasData = _state.value.conversations.isNotEmpty()
            _state.update { it.copy(isLoading = !hasData, errorMessage = null) }
            runCatching { repo.syncInbox() }
                .onSuccess {
                    _state.update { it.copy(isLoading = false) }
                }
                .onFailure { t ->
                    _state.update {
                        it.copy(
                            isLoading = false,
                            errorMessage = t.message ?: "Failed to load conversations.",
                        )
                    }
                }
        }
    }

    fun setSearchQuery(query: String) {
        _state.update { it.copy(searchQuery = query) }
    }

    fun setFilter(filter: InboxFilter) {
        _state.update { it.copy(filter = filter) }
    }
}
