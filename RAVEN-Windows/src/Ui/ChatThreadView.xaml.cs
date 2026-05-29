// ChatThreadView.xaml.cs
//
// Right-pane chat thread. Listens to ShellRouter.ConversationSelected to
// know which thread to load and to MessageRouter / BleEngine inbound
// events for live updates. Sending currently appends a placeholder bubble
// — once `MessageRouter.SendDmAsync` is wired through to a recipient
// resolution path (HANDOFF.md M4) this becomes a real outbound envelope.

using System;
using System.Collections.ObjectModel;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using RAVEN.Windows.Mesh;

namespace RAVEN.Windows.Ui;

public sealed partial class ChatThreadView : UserControl
{
    public ObservableCollection<MessageVm> Messages { get; } = new();

    private readonly ShellRouter _router;
    private readonly MessageRouter _messageRouter;
    private readonly BleEngine _ble;
    private string? _activeConversationId;

    public ChatThreadView()
    {
        this.InitializeComponent();
        _router = App.ShellRouter;
        _messageRouter = App.Services.GetRequiredService<MessageRouter>();
        _ble = App.Services.GetRequiredService<BleEngine>();
        MessageList.ItemsSource = Messages;

        _router.ConversationSelected += OnConversationSelected;

        _ble.OnInboundPacket += pkt =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                if (string.IsNullOrEmpty(_activeConversationId)) return;
                Messages.Add(new MessageVm(
                    body: $"[{pkt.SenderFingerprint}] {pkt.Payload.Length} bytes",
                    isOutgoing: false));
            });
        };
    }

    private void OnConversationSelected(object? sender, string? conversationId)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            _activeConversationId = conversationId;

            if (string.IsNullOrEmpty(conversationId))
            {
                EmptyState.Visibility = Visibility.Visible;
                ThreadRoot.Visibility = Visibility.Collapsed;
                Messages.Clear();
                return;
            }

            EmptyState.Visibility = Visibility.Collapsed;
            ThreadRoot.Visibility = Visibility.Visible;

            HeaderTitle.Text =
                _router.SelectedIsGroup && !string.IsNullOrEmpty(_router.SelectedGroupName)
                    ? _router.SelectedGroupName
                    : (_router.SelectedPeerUsername ?? conversationId);

            HeaderInitials.Text = HeaderTitle.Text.Length > 0
                ? HeaderTitle.Text[..1].ToUpperInvariant()
                : "?";

            HeaderSubtitle.Text = _router.SelectedIsGroup
                ? "Group · End-to-end encrypted"
                : "End-to-end encrypted";

            // Reset for the new conversation. (Once thread storage lands,
            // load persisted messages here instead of clearing.)
            Messages.Clear();
        });
    }

    private void OnSendClicked(object sender, RoutedEventArgs e) => DoSend();

    private void OnComposeKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter && !e.KeyStatus.IsMenuKeyDown)
        {
            e.Handled = true;
            DoSend();
        }
    }

    private void DoSend()
    {
        var text = ComposeBox.Text;
        if (string.IsNullOrWhiteSpace(text)) return;
        if (string.IsNullOrEmpty(_activeConversationId)) return;

        Messages.Add(new MessageVm(
            body: text,
            isOutgoing: true,
            isGroupChat: _router.SelectedIsGroup,
            deliveredOrRead: MessageStatus.Sending));
        ComposeBox.Text = string.Empty;

        // TODO[ROUTER-WIRE] real outbound. Calling MessageRouter.SendDmAsync
        // needs three things we don't have at this point in the build:
        //
        //   1. The recipient's X25519 public key (base64). Currently we only
        //      know the peer by the 8-char fingerprint surfaced by
        //      BleEngine.OnPeerDiscovered, and TrustStore only persists
        //      Ed25519 pubs.
        //   2. The recipient's userId (server-side). Needed for the dual-
        //      path send (server + mesh) so the server route can match.
        //   3. A pairing/exchange flow so #1 and #2 get into TrustStore.
        //
        // Once those land (HANDOFF.md M4 + M5), build a SecureMeshEnvelope
        // here, populate `RecipientId`, `Text`, `MessageType = 0`, and call
        // _messageRouter.SendDmAsync(env, recipientX25519Base64).
        _ = _messageRouter;
    }
}
