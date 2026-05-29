package app.raven.feature.discover.state

import app.raven.feature.discover.data.DiscoverUser
import app.raven.feature.feed.data.Post

/** Which kind of result the search view is showing. */
enum class SearchMode(val label: String) {
    People("People"),
    Posts("Posts"),
}

/** UI model for the Discover tab. */
data class DiscoverUiState(
    val query: String = "",
    val searchMode: SearchMode = SearchMode.People,
    val suggested: List<DiscoverUser> = emptyList(),
    val results: List<DiscoverUser> = emptyList(),
    val postResults: List<Post> = emptyList(),
    val isLoadingSuggested: Boolean = true,
    val isLoadingResults: Boolean = false,
    val isLoadingPosts: Boolean = false,
    /** Error for the People search / suggestions. */
    val errorMessage: String? = null,
    /** Error for the Posts search — kept separate so a slow post
     *  search never mislabels the People tab (and vice versa). */
    val postErrorMessage: String? = null,
    /** Users we've optimistically sent a friend request to. */
    val sentRequestIds: Set<String> = emptySet(),
) {
    /** Server search needs ≥ 2 chars; below that we keep showing suggestions. */
    val isSearching: Boolean get() = query.trim().length >= 2
}
