// ChatModels.cs
//
// View models for the conversation list (ChatListColumn) and the chat
// thread (ChatThreadView). Pulled out of the original MessagesView so
// both components can reference them without re-declaring.

using System;
using System.Linq;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace RAVEN.Windows.Ui;

public sealed class ConversationVm
{
    public string Name { get; }
    public string Preview { get; }
    public DateTime LastActivity { get; }
    public bool HasUnread { get; }
    public int UnreadCount { get; }
    public bool IsGroup { get; }

    public string Initials =>
        string.IsNullOrEmpty(Name) ? "?" :
        new string(Name.Where(char.IsLetterOrDigit).Take(2).Select(char.ToUpperInvariant).ToArray());

    public string TimeText
    {
        get
        {
            var diff = DateTime.Now - LastActivity;
            if (diff.TotalMinutes < 1) return "now";
            if (diff.TotalMinutes < 60) return $"{(int)diff.TotalMinutes}m";
            if (diff.TotalHours < 24) return $"{(int)diff.TotalHours}h";
            return LastActivity.ToString("MMM d");
        }
    }

    public string UnreadText => UnreadCount > 0 ? UnreadCount.ToString() : string.Empty;
    public Visibility UnreadVisibility => UnreadCount > 0 || HasUnread ? Visibility.Visible : Visibility.Collapsed;
    public Visibility GroupBadgeVisibility => IsGroup ? Visibility.Visible : Visibility.Collapsed;

    public ConversationVm(string name, string preview, DateTime lastActivity,
                          bool hasUnread, bool isGroup = false, int unreadCount = 0)
    {
        Name = name;
        Preview = preview;
        LastActivity = lastActivity;
        HasUnread = hasUnread;
        IsGroup = isGroup;
        UnreadCount = unreadCount;
    }
}

public enum MessageStatus { None, Sending, Sent, Delivered, Read }

public sealed class MessageVm
{
    public string Body { get; }
    public bool IsOutgoing { get; }
    public MessageStatus Status { get; }
    public bool IsGroupChat { get; }
    public string? SenderName { get; }

    public DateTime SentAt { get; } = DateTime.Now;
    public string TimeText => SentAt.ToString("HH:mm");

    public HorizontalAlignment AlignmentBinding =>
        IsOutgoing ? HorizontalAlignment.Right : HorizontalAlignment.Left;

    public Brush BubbleBackground =>
        IsOutgoing
            ? (Brush)Application.Current.Resources["OutgoingBubbleBrush"]
            : (Brush)Application.Current.Resources["RavenBgCardHover"];

    public Brush BubbleBorder =>
        IsOutgoing
            ? new SolidColorBrush(Color.FromArgb(0, 0, 0, 0))
            : (Brush)Application.Current.Resources["RavenBorder"];

    public Brush BubbleForeground =>
        IsOutgoing
            ? new SolidColorBrush(Microsoft.UI.Colors.White)
            : (Brush)Application.Current.Resources["RavenText"];

    public Brush MetaForeground =>
        IsOutgoing
            ? new SolidColorBrush(Color.FromArgb(180, 255, 255, 255))
            : (Brush)Application.Current.Resources["RavenText3"];

    public Brush SenderForeground => (Brush)Application.Current.Resources["RavenLogoStartBrush"];

    public string SenderLabel => SenderName ?? string.Empty;

    public Visibility SenderVisibility =>
        IsGroupChat && !IsOutgoing && !string.IsNullOrEmpty(SenderName)
            ? Visibility.Visible : Visibility.Collapsed;

    public string StatusIcon => Status switch
    {
        MessageStatus.Sending => "",     // Clock
        MessageStatus.Sent => "",        // Single check
        MessageStatus.Delivered => "",   // Double check
        MessageStatus.Read => "",        // Double check (would tint differently)
        _ => string.Empty,
    };

    public Visibility StatusVisibility =>
        IsOutgoing && Status != MessageStatus.None ? Visibility.Visible : Visibility.Collapsed;

    public MessageVm(string body, bool isOutgoing, bool isGroupChat = false,
                     string? senderName = null, MessageStatus deliveredOrRead = MessageStatus.None)
    {
        Body = body;
        IsOutgoing = isOutgoing;
        IsGroupChat = isGroupChat;
        SenderName = senderName;
        Status = deliveredOrRead;
    }
}
