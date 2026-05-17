// MainWindow.xaml.cs
//
// Three-column shell. Owns no logic of its own — all section state lives
// in `App.ShellRouter`. We just listen for SectionChanged and toggle the
// matching main-column host's Visibility.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace RAVEN.Windows.Ui;

public sealed partial class MainWindow : Window
{
    private readonly ShellRouter _router;

    public MainWindow()
    {
        this.InitializeComponent();

        // Pure black backdrop to match Mac. (Mica adds a Win11-native
        // texture but breaks visual parity with the macOS shell — and the
        // user explicitly asked for them to look identical.)
        try { this.SystemBackdrop = null; } catch { /* older Windows */ }

        this.ExtendsContentIntoTitleBar = true;
        this.SetTitleBar(null);

        _router = App.ShellRouter;
        _router.SectionChanged += (_, section) =>
            DispatcherQueue.TryEnqueue(() => ApplyMainColumn(section));

        ApplyMainColumn(_router.Section);
    }

    private void ApplyMainColumn(ShellSection section)
    {
        HomeHost.Visibility          = section == ShellSection.Home          ? Visibility.Visible : Visibility.Collapsed;
        ExploreHost.Visibility       = section == ShellSection.Explore       ? Visibility.Visible : Visibility.Collapsed;
        NotificationsHost.Visibility = section == ShellSection.Notifications ? Visibility.Visible : Visibility.Collapsed;
        ChatListHost.Visibility      = section == ShellSection.Messages      ? Visibility.Visible : Visibility.Collapsed;
        ProfileHost.Visibility       = section == ShellSection.Profile       ? Visibility.Visible : Visibility.Collapsed;
    }
}
