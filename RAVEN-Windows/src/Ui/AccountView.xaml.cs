// AccountView.xaml.cs
//
// Identity + mesh diagnostics + settings.

using System;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using RAVEN.Windows.Mesh;
using RAVEN.Windows.Storage;

namespace RAVEN.Windows.Ui;

public sealed partial class AccountView : UserControl
{
    private readonly KeyStore _keyStore;
    private readonly BleEngine _ble;
    private readonly MessageRouter _router;

    public AccountView()
    {
        this.InitializeComponent();
        _keyStore = App.Services.GetRequiredService<KeyStore>();
        _ble = App.Services.GetRequiredService<BleEngine>();
        _router = App.Services.GetRequiredService<MessageRouter>();

        _ = LoadIdentityAsync();
        StartPeerCountUpdates();
    }

    private async Task LoadIdentityAsync()
    {
        try
        {
            var keys = await _keyStore.LoadOrCreateAsync();
            DispatcherQueue.TryEnqueue(() =>
            {
                FingerprintLabel.Text = keys.Fingerprint;
                EdPubLabel.Text = Convert.ToBase64String(keys.Ed25519PublicKey);
                XPubLabel.Text = Convert.ToBase64String(keys.X25519PublicKey);
            });
        }
        catch (Exception ex)
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                FingerprintLabel.Text = "(failed to load: " + ex.Message + ")";
            });
        }
    }

    private void StartPeerCountUpdates()
    {
        // Quick-and-dirty: update peer count every 2s. A proper version would
        // subscribe to BleEngine.OnPeerDiscovered/OnPeerLost events.
        var timer = new Microsoft.UI.Xaml.DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(2),
        };
        timer.Tick += (_, _) =>
        {
            PeersValue.Text = _ble.Peers.Count.ToString();
            RelayedValue.Text = _router.FramesRelayed.ToString();
            BridgeValue.Text = _router.BridgeUplinks.ToString();
        };
        timer.Start();
    }
}
