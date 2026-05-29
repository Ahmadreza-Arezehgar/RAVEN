package app.raven.feature.feed.state

/**
 * The two feed segments shown in the home header — mirror of the
 * iOS "Local | Friends" segmented pill in `FeedView`.
 */
enum class FeedTab(val label: String) {
    Local("Local"),
    Friends("Friends"),
}
