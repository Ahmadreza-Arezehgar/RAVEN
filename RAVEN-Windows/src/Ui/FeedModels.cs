// FeedModels.cs
//
// View models for HomeView (Echo Wall feed). Pulled out of the original
// FeedView.xaml.cs so HomeView can own them without re-declaring.

using System;

namespace RAVEN.Windows.Ui;

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
