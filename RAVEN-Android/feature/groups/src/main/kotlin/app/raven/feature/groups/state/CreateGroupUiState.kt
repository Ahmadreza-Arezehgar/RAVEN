package app.raven.feature.groups.state

import app.raven.feature.groups.data.GroupCandidate

/** UI model for the create-group screen. */
data class CreateGroupUiState(
    val name: String = "",
    val query: String = "",
    val friends: List<GroupCandidate> = emptyList(),
    val searchResults: List<GroupCandidate> = emptyList(),
    val selected: List<GroupCandidate> = emptyList(),
    val isLoadingCandidates: Boolean = false,
    val isSearching: Boolean = false,
    val isCreating: Boolean = false,
    val errorMessage: String? = null,
    /** Non-null once the group is created — drives navigation away. */
    val createdGroupId: String? = null,
) {
    /** Server search kicks in at ≥ 2 chars; below that we show friends. */
    val isSearchActive: Boolean get() = query.trim().length >= 2

    /** Candidates to render — search results while searching, else friends. */
    val visibleCandidates: List<GroupCandidate>
        get() = if (isSearchActive) searchResults else friends

    fun isSelected(id: String): Boolean = selected.any { it.id == id }

    /** A name is the only hard requirement — the server allows a
     *  creator-only group, so member count is not gated. */
    val canCreate: Boolean get() = name.trim().isNotEmpty() && !isCreating
}
