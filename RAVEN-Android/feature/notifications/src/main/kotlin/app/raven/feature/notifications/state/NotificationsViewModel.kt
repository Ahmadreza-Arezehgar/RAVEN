package app.raven.feature.notifications.state

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.raven.feature.notifications.data.AppNotification
import app.raven.feature.notifications.data.NotificationsRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

/** Drives the Notifications screen — load, mark-one-read, mark-all-read. */
@HiltViewModel
class NotificationsViewModel @Inject constructor(
    private val repo: NotificationsRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(NotificationsUiState())
    val state: StateFlow<NotificationsUiState> = _state.asStateFlow()

    init {
        load()
    }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = it.notifications.isEmpty(), errorMessage = null) }
            runCatching { repo.notifications() }
                .onSuccess { list -> _state.update { it.copy(notifications = list, isLoading = false) } }
                .onFailure { error ->
                    _state.update {
                        it.copy(isLoading = false, errorMessage = error.message ?: "Couldn't load notifications.")
                    }
                }
        }
    }

    fun markAllRead() {
        if (!_state.value.hasUnread) return
        _state.update { s -> s.copy(notifications = s.notifications.map { it.copy(isRead = true) }) }
        viewModelScope.launch { runCatching { repo.markAllRead() } }
    }

    fun onNotificationClick(notification: AppNotification) {
        if (notification.isRead) return
        _state.update { s ->
            s.copy(notifications = s.notifications.map { if (it.id == notification.id) it.copy(isRead = true) else it })
        }
        viewModelScope.launch { runCatching { repo.markRead(notification.id) } }
    }
}
