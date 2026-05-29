// RailView.xaml.cs
//
// The left column of the 3-pane shell. Owns the visual selection state
// for the rail items and forwards section changes to the shared
// `ShellRouter` (so the middle and right columns can react).

using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace RAVEN.Windows.Ui;

public sealed partial class RailView : UserControl
{
    private readonly ShellRouter _router;

    public RailView()
    {
        this.InitializeComponent();
        _router = App.ShellRouter;

        _router.SectionChanged += (_, section) =>
        {
            DispatcherQueue.TryEnqueue(() => ApplyVisualSelection(section));
        };

        ApplyVisualSelection(_router.Section);
    }

    private void OnRailItemTapped(object sender, TappedRoutedEventArgs e)
    {
        if (sender is not RailItem tapped) return;

        var section =
            tapped == NavHome          ? ShellSection.Home
            : tapped == NavExplore     ? ShellSection.Explore
            : tapped == NavNotifications ? ShellSection.Notifications
            : tapped == NavMessages    ? ShellSection.Messages
            : tapped == NavProfile     ? ShellSection.Profile
            : ShellSection.Home;

        _router.Section = section;
    }

    private void OnPostClicked(object sender, RoutedEventArgs e)
    {
        _router.RequestComposePost();
    }

    private void ApplyVisualSelection(ShellSection section)
    {
        NavHome.IsSelected          = section == ShellSection.Home;
        NavExplore.IsSelected       = section == ShellSection.Explore;
        NavNotifications.IsSelected = section == ShellSection.Notifications;
        NavMessages.IsSelected      = section == ShellSection.Messages;
        NavProfile.IsSelected       = section == ShellSection.Profile;
    }
}
