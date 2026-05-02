// MainWindow.xaml.cs
//
// The shell. Holds the sidebar + the swappable main pane.
// Sidebar selection drives which UserControl (Feed/Messages/Account) is
// visible in the main pane. The sub-views own their own state.

using System;
using System.Linq;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using RAVEN.Windows.Mesh;

namespace RAVEN.Windows.Ui;

public sealed partial class MainWindow : Window
{
    private readonly BleEngine _ble;

    public MainWindow()
    {
        this.InitializeComponent();

        // Mica/Acrylic backdrop on Windows 11.
        try
        {
            this.SystemBackdrop = new Microsoft.UI.Xaml.Media.MicaBackdrop
            {
                Kind = Microsoft.UI.Composition.SystemBackdrops.MicaKind.BaseAlt,
            };
        }
        catch { /* older Windows: fall through to gradient bg */ }

        this.ExtendsContentIntoTitleBar = true;
        this.SetTitleBar(null);

        _ble = App.Services.GetRequiredService<BleEngine>();

        // Live mesh status pill.
        UpdateMeshStatus();
        _ble.OnPeerDiscovered += _ => DispatcherQueue.TryEnqueue(UpdateMeshStatus);
        _ble.OnPeerLost += _ => DispatcherQueue.TryEnqueue(UpdateMeshStatus);
    }

    private void UpdateMeshStatus()
    {
        var n = _ble.Peers.Count;
        if (n == 0)
        {
            MeshStatus.Text = "Mesh idle";
            MeshDot.Fill = (SolidColorBrush)Application.Current.Resources["RavenText3"];
        }
        else
        {
            MeshStatus.Text = n == 1 ? "Mesh · 1 peer" : $"Mesh · {n} peers";
            MeshDot.Fill = (SolidColorBrush)Application.Current.Resources["RavenGreenBrush"];
        }
    }

    // ─── View switching ──────────────────────────────────────────────

    private void OnSidebarItemTapped(object sender, TappedRoutedEventArgs e)
    {
        if (sender is not SidebarRow tapped) return;

        // Single-selection across siblings.
        foreach (var row in SidebarPanel.Children.OfType<SidebarRow>())
            row.IsSelected = (row == tapped);

        // Swap which view is visible.
        FeedView.Visibility = (tapped == NavFeed) ? Visibility.Visible : Visibility.Collapsed;
        MessagesView.Visibility = (tapped == NavMessages) ? Visibility.Visible : Visibility.Collapsed;
        AccountView.Visibility = (tapped == NavAccount) ? Visibility.Visible : Visibility.Collapsed;
    }
}
