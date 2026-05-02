// MessagesView.xaml.cs
//
// DM + group chat list and detail. Encapsulates everything that used to be
// inline in MainWindow so the main shell can swap views by sidebar selection.

using System;
using System.Collections.ObjectModel;
using System.Linq;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using RAVEN.Windows.Mesh;

namespace RAVEN.Windows.Ui;

public sealed partial class MessagesView : UserControl
{
    public ObservableCollection<ConversationVm> Conversations { get; } = new();
    public ObservableCollection<MessageVm> Messages { get; } = new();

    private readonly MessageRouter _router;
    private readonly BleEngine _ble;
    private ConversationVm? _activeConversation;

    public MessagesView()
    {
        this.InitializeComponent();

        _router = App.Services.GetRequiredService<MessageRouter>();
        _ble = App.Services.GetRequiredService<BleEngine>();

        ConversationList.ItemsSource = Conversations;
        MessageList.ItemsSource = Messages;

        // Seed: one DM-style placeholder + one group placeholder so the layout reads.
        Conversations.Add(new ConversationVm("RAVEN Mesh",
            "Discovers nearby peers via BLE", DateTime.Now, hasUnread: false, isGroup: false));

        // Live BLE peer feed → DM-style conversations.
        _ble.OnPeerDiscovered += peer =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                if (Conversations.Any(c => c.Name == peer.Fingerprint)) return;
                Conversations.Add(new ConversationVm(
                    name: peer.Fingerprint,
                    preview: "Discovered nearby · BLE",
                    lastActivity: DateTime.Now,
                    hasUnread: false,
                    isGroup: false));
            });
        };
        _ble.OnPeerLost += fp =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                var existing = Conversations.FirstOrDefault(c => c.Name == fp);
                if (existing is not null) Conversations.Remove(existing);
            });
        };
        _ble.OnInboundPacket += pkt =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                Messages.Add(new MessageVm(
                    body: $"[{pkt.SenderFingerprint}] received {pkt.Payload.Length} bytes",
                    isOutgoing: false,
                    isGroupChat: false,
                    senderName: null,
                    deliveredOrRead: MessageStatus.None));
            });
        };
    }

    private void OnConversationSelected(object sender, SelectionChangedEventArgs e)
    {
        var sel = ConversationList.SelectedItem as ConversationVm;
        _activeConversation = sel;
        if (sel is null)
        {
            HeaderTitle.Text = "Select a conversation";
            HeaderInitials.Text = "—";
            HeaderSubtitle.Text = "End-to-end encrypted · mesh ready";
            return;
        }
        HeaderTitle.Text = sel.Name;
        HeaderInitials.Text = sel.Initials;
        HeaderSubtitle.Text = sel.IsGroup
            ? "Group · End-to-end encrypted"
            : "Online · End-to-end encrypted";
    }

    private void OnSendClicked(object sender, RoutedEventArgs e) => DoSend();

    private void OnComposeKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter)
        {
            e.Handled = true;
            DoSend();
        }
    }

    private void DoSend()
    {
        var text = ComposeBox.Text;
        if (string.IsNullOrWhiteSpace(text)) return;

        Messages.Add(new MessageVm(
            body: text,
            isOutgoing: true,
            isGroupChat: _activeConversation?.IsGroup ?? false,
            senderName: null,
            deliveredOrRead: MessageStatus.Sending));
        ComposeBox.Text = string.Empty;

        // TODO: route through MessageRouter once recipient resolution is wired.
        // For DMs: env.RecipientId = _activeConversation.UserId
        // For groups: send the same envelope to each group member's pubkey.
    }
}

// ─────────────────────────────────────────────────────────────────────
// View models
// ─────────────────────────────────────────────────────────────────────

public sealed class ConversationVm
{
    public string Name { get; }
    public string Preview { get; }
    public DateTime LastActivity { get; }
    public bool HasUnread { get; }
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

    public Visibility UnreadVisibility => HasUnread ? Visibility.Visible : Visibility.Collapsed;
    public Visibility GroupBadgeVisibility => IsGroup ? Visibility.Visible : Visibility.Collapsed;

    public ConversationVm(string name, string preview, DateTime lastActivity, bool hasUnread, bool isGroup = false)
    {
        Name = name;
        Preview = preview;
        LastActivity = lastActivity;
        HasUnread = hasUnread;
        IsGroup = isGroup;
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

    public Brush SenderForeground => (Brush)Application.Current.Resources["RavenPurpleBrush"];

    public string SenderLabel => SenderName ?? string.Empty;

    public Visibility SenderVisibility =>
        IsGroupChat && !IsOutgoing && !string.IsNullOrEmpty(SenderName)
            ? Visibility.Visible : Visibility.Collapsed;

    public string StatusIcon => Status switch
    {
        MessageStatus.Sending => "",   // Clock
        MessageStatus.Sent => "",       // Single check
        MessageStatus.Delivered => "", // Double check
        MessageStatus.Read => "",      // Read (would tint differently)
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
