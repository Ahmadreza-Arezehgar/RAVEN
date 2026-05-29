// WidgetsView.xaml.cs
//
// Right-pane widgets (search + trending hashtags + RAVEN+ upsell + footer).
// Trending hashtags are pulled from the server's `/api/trending` endpoint
// — when offline, the empty state shows "No trends right now." (matching
// Mac's WidgetsView L57).

using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace RAVEN.Windows.Ui;

public sealed partial class WidgetsView : UserControl
{
    public ObservableCollection<TrendVm> Trends { get; } = new();

    public WidgetsView()
    {
        this.InitializeComponent();
        TrendsList.ItemsSource = Trends;
        UpdateEmptyState();

        Trends.CollectionChanged += (_, _) => UpdateEmptyState();
        // Trending fetch will be wired once ApiClient.TrendingHashtagsAsync
        // exists; for now the right-rail just shows the empty-state line so
        // the layout reads.
    }

    private void UpdateEmptyState()
    {
        EmptyTrends.Visibility = Trends.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }
}

public sealed class TrendVm
{
    public string Hashtag { get; }
    public int PostCount { get; }

    public string TagDisplay => "#" + Hashtag;
    public string PostsLabel
    {
        get
        {
            var n = PostCount;
            if (n >= 1_000_000) return (n / 1_000_000) + "M posts";
            if (n >= 1_000)     return (n / 1_000.0).ToString("0.0") + "K posts";
            return n == 1 ? "1 post" : n + " posts";
        }
    }

    public TrendVm(string hashtag, int postCount)
    {
        Hashtag = hashtag;
        PostCount = postCount;
    }
}
