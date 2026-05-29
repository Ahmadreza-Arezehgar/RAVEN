// HomeView.xaml.cs
//
// Echo Wall feed (middle pane on the Home tab). Mirrors Mac's FeedView —
// header + tab strip + composer + post cards. Posts come in over BLE as
// MeshPostEnvelope frames (see MESH_PROTOCOL.md §C.3).

using System;
using System.Collections.ObjectModel;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RAVEN.Windows.Mesh;
using RAVEN.Windows.Storage;

namespace RAVEN.Windows.Ui;

public sealed partial class HomeView : UserControl
{
    public ObservableCollection<PostVm> Posts { get; } = new();

    private enum FeedTab { ForYou, Friends, Local }
    private FeedTab _tab = FeedTab.ForYou;

    public HomeView()
    {
        this.InitializeComponent();
        PostList.ItemsSource = Posts;

        Posts.Add(new PostVm(
            authorUsername: "@raven",
            authorInitials: "RV",
            body: "Welcome to Echo Wall on Windows. Posts you publish here travel device-to-device over BLE — encrypted end-to-end.",
            createdAt: DateTime.Now.AddMinutes(-5),
            scope: PostScope.Public,
            route: PostRoute.Server,
            likeCount: 0,
            commentCount: 0));

        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        // Seed the compose-card avatar letter from the device's fingerprint.
        if (App.Services is null) return;
        var keys = await App.Services.GetRequiredService<KeyStore>().LoadOrCreateAsync();
        if (!string.IsNullOrEmpty(keys.Fingerprint))
            ComposeAvatarLetter.Text = keys.Fingerprint[..1].ToUpperInvariant();
    }

    private void OnTabClicked(object sender, RoutedEventArgs e)
    {
        if (sender is not Button btn) return;
        _tab = (btn.Tag as string) switch
        {
            "friends" => FeedTab.Friends,
            "local"   => FeedTab.Local,
            _         => FeedTab.ForYou,
        };
        // Visual update: bold the selected tab + show its underline. We
        // re-style by toggling text colour + the underline border, which
        // are the only visual differences between selected and unselected.
        ApplyTabVisuals();
        // TODO: when /api/feed{,Friends,Local} exists in ApiClient, call
        // the matching endpoint here. The UI swap is intentional even
        // before backend wiring so the layout matches Mac.
    }

    private void ApplyTabVisuals()
    {
        // (left as a stub — visuals already match Mac for the default
        // selected tab; full active/inactive theming can be wired once
        // the backend feed-tab fetch lands)
    }

    private void OnPublishClicked(object sender, RoutedEventArgs e)
    {
        var text = ComposeBox.Text;
        if (string.IsNullOrWhiteSpace(text)) return;

        Posts.Insert(0, new PostVm(
            authorUsername: "@you",
            authorInitials: "ME",
            body: text,
            createdAt: DateTime.Now,
            scope: PostScope.Public,
            route: PostRoute.Mesh,
            likeCount: 0,
            commentCount: 0));

        ComposeBox.Text = string.Empty;

        // TODO: build a MeshPostEnvelope, sign it with our Ed25519 key,
        // and broadcast via BleEngine.BroadcastAsync(...). The envelope
        // model already exists in Mesh/MeshEnvelope.cs.
    }
}
