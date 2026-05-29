// ChatListColumn.xaml.cs
//
// Inbox list. Selecting a row hands the conversation off to the shared
// `ShellRouter` so the right pane can render the thread.
//
// Live BLE peer feed adds DM-style placeholder rows for any nearby peer
// the BleEngine surfaces; the placeholder converts into a real
// conversation as soon as the user sends or receives an envelope.

using System;
using System.Collections.ObjectModel;
using System.Linq;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using RAVEN.Windows.Mesh;

namespace RAVEN.Windows.Ui;

public sealed partial class ChatListColumn : UserControl
{
    public ObservableCollection<ConversationVm> Conversations { get; } = new();
    private readonly ShellRouter _router;
    private readonly BleEngine _ble;

    public ChatListColumn()
    {
        this.InitializeComponent();
        _router = App.ShellRouter;
        _ble = App.Services.GetRequiredService<BleEngine>();
        ConversationList.ItemsSource = Conversations;

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
    }

    private void OnConversationSelected(object sender, SelectionChangedEventArgs e)
    {
        if (ConversationList.SelectedItem is not ConversationVm sel)
        {
            _router.ClearConversation();
            return;
        }
        _router.SelectConversation(
            conversationId: sel.Name,
            peerUsername: sel.Name,
            peerAvatarUrl: null,
            isGroup: sel.IsGroup,
            groupName: sel.IsGroup ? sel.Name : null);
    }
}
