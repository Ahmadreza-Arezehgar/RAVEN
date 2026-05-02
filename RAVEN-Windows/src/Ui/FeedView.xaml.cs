// FeedView.xaml.cs
//
// Echo Wall feed. Shows posts received via mesh + composer to publish new ones.
// Posts come in over BLE as MeshPostEnvelope frames (frame discriminator
// "mesh_post_v1") — see MESH_PROTOCOL.md §C.3.

using System;
using System.Collections.ObjectModel;
using System.Linq;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RAVEN.Windows.Mesh;

namespace RAVEN.Windows.Ui;

public sealed partial class FeedView : UserControl
{
    public ObservableCollection<PostVm> Posts { get; } = new();

    private readonly MessageRouter _router;
    private readonly BleEngine _ble;

    public FeedView()
    {
        this.InitializeComponent();
        _router = App.Services.GetRequiredService<MessageRouter>();
        _ble = App.Services.GetRequiredService<BleEngine>();

        PostList.ItemsSource = Posts;

        // Seed: a hint post so the first launch isn't empty.
        Posts.Add(new PostVm(
            authorUsername: "@raven",
            authorInitials: "RV",
            body: "Welcome to Echo Wall on Windows. Posts you publish here travel device-to-device over BLE — encrypted end-to-end.",
            createdAt: DateTime.Now.AddMinutes(-5),
            scope: PostScope.Public,
            route: PostRoute.Server,
            likeCount: 0,
            commentCount: 0));

        // TODO: subscribe to MessageRouter's mesh-post inbound stream when a
        // proper post-event is exposed. For now the wiring is here as scaffolding;
        // the dedup + signature verification already happens in MessageRouter.
    }

    private void OnPublishClicked(object sender, RoutedEventArgs e)
    {
        var text = ComposeBox.Text;
        if (string.IsNullOrWhiteSpace(text)) return;

        var scope = (ScopePicker.SelectedIndex) switch
        {
            1 => PostScope.Friends,
            2 => PostScope.Local,
            _ => PostScope.Public,
        };

        // Optimistic UI insert.
        Posts.Insert(0, new PostVm(
            authorUsername: "@you",
            authorInitials: "ME",
            body: text,
            createdAt: DateTime.Now,
            scope: scope,
            route: PostRoute.Mesh,
            likeCount: 0,
            commentCount: 0));

        ComposeBox.Text = string.Empty;

        // TODO: build a MeshPostEnvelope, sign it with our Ed25519 key,
        // and broadcast via _ble.BroadcastAsync(...). The MeshPostEnvelope
        // model already exists; just need to construct + sign.
    }
}

// ─── View models ────────────────────────────────────────────────────

public enum PostScope { Public, Friends, Local }
public enum PostRoute { Server, Mesh, Bridge }

public sealed class PostVm
{
    public string AuthorUsername { get; }
    public string AuthorInitials { get; }
    public string Body { get; }
    public DateTime CreatedAt { get; }
    public PostScope Scope { get; }
    public PostRoute Route { get; }
    public int LikeCount { get; }
    public int CommentCount { get; }

    public string TimeText
    {
        get
        {
            var diff = DateTime.Now - CreatedAt;
            if (diff.TotalMinutes < 1) return "just now";
            if (diff.TotalMinutes < 60) return $"{(int)diff.TotalMinutes}m ago";
            if (diff.TotalHours < 24) return $"{(int)diff.TotalHours}h ago";
            return CreatedAt.ToString("MMM d");
        }
    }

    public string ScopeIcon => Scope switch
    {
        PostScope.Public => "🌍",
        PostScope.Friends => "👥",
        PostScope.Local => "📍",
        _ => "🌍",
    };

    public string ScopeLabel => Scope switch
    {
        PostScope.Public => "Public",
        PostScope.Friends => "Friends",
        PostScope.Local => "Local mesh",
        _ => "Public",
    };

    public string RouteIcon => Route switch
    {
        PostRoute.Server => "",   // cloud
        PostRoute.Mesh => "",     // antenna
        PostRoute.Bridge => "",   // bridge
        _ => "",
    };

    public string RouteLabel => Route switch
    {
        PostRoute.Server => "Server",
        PostRoute.Mesh => "Mesh",
        PostRoute.Bridge => "Bridge",
        _ => "Server",
    };

    public string LikeCountText => LikeCount.ToString();
    public string CommentCountText => CommentCount.ToString();

    public PostVm(string authorUsername, string authorInitials, string body, DateTime createdAt,
                  PostScope scope, PostRoute route, int likeCount, int commentCount)
    {
        AuthorUsername = authorUsername;
        AuthorInitials = authorInitials;
        Body = body;
        CreatedAt = createdAt;
        Scope = scope;
        Route = route;
        LikeCount = likeCount;
        CommentCount = commentCount;
    }
}
