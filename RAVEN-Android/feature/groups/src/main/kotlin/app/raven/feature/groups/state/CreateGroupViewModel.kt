package app.raven.feature.groups.state

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.raven.feature.chat.data.ChatRepository
import app.raven.feature.groups.data.GroupCandidate
import app.raven.feature.groups.data.GroupsRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Drives the create-group screen: loads friends for the member
 * picker, runs a debounced user search as a fallback, tracks the
 * selected members, and creates the group.
 *
 * On success it pulls the new group into the inbox cache via
 * [ChatRepository.syncInbox] so the conversation list shows it
 * immediately when the user returns.
 */
@HiltViewModel
class CreateGroupViewModel @Inject constructor(
    private val repo: GroupsRepository,
    private val chatRepo: ChatRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(CreateGroupUiState())
    val state: StateFlow<CreateGroupUiState> = _state.asStateFlow()

    private var searchJob: Job? = null

    init {
        loadFriends()
    }

    private fun loadFriends() {
        viewModelScope.launch {
            _state.update { it.copy(isLoadingCandidates = true) }
            runCatching { repo.friends() }
                .onSuccess { list -> _state.update { it.copy(friends = list, isLoadingCandidates = false) } }
                .onFailure { _state.update { it.copy(isLoadingCandidates = false) } }
        }
    }

    fun setName(value: String) = _state.update { it.copy(name = value) }

    /** Search-as-you-type — 300 ms debounced. */
    fun setQuery(value: String) {
        _state.update { it.copy(query = value) }
        searchJob?.cancel()
        if (value.trim().length < 2) {
            _state.update { it.copy(searchResults = emptyList(), isSearching = false) }
            return
        }
        val q = value.trim()
        searchJob = viewModelScope.launch {
            delay(300)
            _state.update { it.copy(isSearching = true) }
            runCatching { repo.searchUsers(q) }
                .onSuccess { list -> _state.update { it.copy(searchResults = list, isSearching = false) } }
                .onFailure { _state.update { it.copy(isSearching = false) } }
        }
    }

    fun toggleMember(candidate: GroupCandidate) {
        _state.update { s ->
            val next = if (s.selected.any { it.id == candidate.id }) {
                s.selected.filterNot { it.id == candidate.id }
            } else {
                s.selected + candidate
            }
            s.copy(selected = next)
        }
    }

    fun createGroup() {
        val s = _state.value
        if (!s.canCreate) return
        _state.update { it.copy(isCreating = true, errorMessage = null) }
        viewModelScope.launch {
            runCatching { repo.createGroup(s.name.trim(), s.selected.map { it.id }) }
                .onSuccess { group ->
                    // Sync the inbox so the new group row appears in
                    // the conversation list the moment we navigate back.
                    runCatching { chatRepo.syncInbox() }
                    _state.update { it.copy(isCreating = false, createdGroupId = group.id) }
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(isCreating = false, errorMessage = error.message ?: "Couldn't create the group.")
                    }
                }
        }
    }
}
