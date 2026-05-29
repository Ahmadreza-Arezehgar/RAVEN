// ProfileView.xaml.cs
//
// Profile screen — replaces the old AccountView. Layout matches Mac's
// `ProfileColumn` (header card + action tiles), with the existing
// Windows-only mesh diagnostics + identity cards appended underneath.

using System;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RAVEN.Windows.Mesh;
using RAVEN.Windows.Storage;

namespace RAVEN.Windows.Ui;

public sealed partial class ProfileView : UserControl
{
    private readonly BleEngine _ble;

    public ProfileView()
    {
        this.InitializeComponent();
        _ble = App.Services.GetRequiredService<BleEngine>();

        Loaded += OnLoaded;

        _ble.OnPeerDiscovered += _ => DispatcherQueue.TryEnqueue(UpdateMeshCounters);
        _ble.OnPeerLost += _ => DispatcherQueue.TryEnqueue(UpdateMeshCounters);
        UpdateMeshCounters();
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (App.Services is null) return;
        var keys = await App.Services.GetRequiredService<KeyStore>().LoadOrCreateAsync();
        FingerprintLabel.Text = keys.Fingerprint;
        EdPubLabel.Text = Convert.ToBase64String(keys.Ed25519PublicKey);
        XPubLabel.Text = Convert.ToBase64String(keys.X25519PublicKey);

        if (!string.IsNullOrEmpty(keys.Fingerprint))
        {
            DisplayName.Text = keys.Fingerprint.Length > 14
                ? keys.Fingerprint[..14]
                : keys.Fingerprint;
            HandleLabel.Text = "@" + (keys.Fingerprint.Length > 6 ? keys.Fingerprint[..6] : keys.Fingerprint);
            AvatarLetter.Text = keys.Fingerprint[..1].ToUpperInvariant();
        }
    }

    private void UpdateMeshCounters()
    {
        PeersValue.Text = _ble.Peers.Count.ToString();
        // Frames-relayed and bridge-uplink counters live on MessageRouter
        // once those events are exposed; for now show placeholders.
    }
}
