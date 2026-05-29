// ShellRouter.cs
//
// Central navigation state for the 3-column shell. Mirrors the Mac app's
// `ShellRouter` ObservableObject (`RAVEN-MacApp/RAVEN/Views/MacShellView.swift`)
// so both builds drive the same conceptual model:
//
//   - Section: which middle-pane content is showing
//   - SelectedConversationId / SelectedPeer / SelectedIsGroup: which thread
//     the right pane should render when Section == Messages
//
// Concrete differences from SwiftUI's @Published model: WinUI doesn't have
// a built-in observation primitive that propagates to bound XAML controls
// AND raw subscribers cleanly, so we expose plain CLR events. Views that
// care subscribe in their constructor and unsubscribe on Unloaded.

using System;

namespace RAVEN.Windows.Ui;

public enum ShellSection
{
    Home,
    Explore,
    Notifications,
    Messages,
    Profile,
}

public sealed class ShellRouter
{
    private ShellSection _section = ShellSection.Home;
    public ShellSection Section
    {
        get => _section;
        set
        {
            if (_section == value) return;
            _section = value;
            SectionChanged?.Invoke(this, value);
        }
    }

    /// Peer user id of the open DM (server's `/api/messages/conversation/{id}`
    /// path parameter), OR the group room id if SelectedIsGroup is true.
    public string? SelectedConversationId { get; private set; }
    public string? SelectedPeerUsername { get; private set; }
    public string? SelectedPeerAvatarUrl { get; private set; }
    public bool SelectedIsGroup { get; private set; }
    public string? SelectedGroupName { get; private set; }
    public string? SelectedGroupAvatarUrl { get; private set; }

    /// Set by ChatListColumn when a row is tapped. RightPane subscribes
    /// to render the thread.
    public void SelectConversation(
        string conversationId,
        string? peerUsername,
        string? peerAvatarUrl,
        bool isGroup,
        string? groupName = null,
        string? groupAvatarUrl = null)
    {
        SelectedConversationId = conversationId;
        SelectedPeerUsername = peerUsername;
        SelectedPeerAvatarUrl = peerAvatarUrl;
        SelectedIsGroup = isGroup;
        SelectedGroupName = groupName;
        SelectedGroupAvatarUrl = groupAvatarUrl;
        ConversationSelected?.Invoke(this, conversationId);
    }

    public void ClearConversation()
    {
        SelectedConversationId = null;
        SelectedPeerUsername = null;
        SelectedPeerAvatarUrl = null;
        SelectedIsGroup = false;
        SelectedGroupName = null;
        SelectedGroupAvatarUrl = null;
        ConversationSelected?.Invoke(this, null);
    }

    /// Fired when a rail item is tapped (or Section is set programmatically).
    public event EventHandler<ShellSection>? SectionChanged;

    /// Fired when ChatListColumn selects a row. Argument is the new
    /// conversation id (peer-user-id for DMs, group-id for groups), or
    /// null when cleared.
    public event EventHandler<string?>? ConversationSelected;

    /// Compose-post sheet trigger (the gradient Post button on the rail).
    public event EventHandler? ComposePostRequested;

    public void RequestComposePost() => ComposePostRequested?.Invoke(this, EventArgs.Empty);
}
