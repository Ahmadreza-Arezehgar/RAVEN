// RightPane.xaml.cs
//
// Switches between the chat thread (when the user is on Messages with a
// conversation selected) and the static widgets stack (everywhere else).
// Mac's RightPane uses the same rule: if `section == .messages` show
// ChatThreadView, otherwise WidgetsView.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace RAVEN.Windows.Ui;

public sealed partial class RightPane : UserControl
{
    private readonly ShellRouter _router;

    public RightPane()
    {
        this.InitializeComponent();
        _router = App.ShellRouter;
        _router.SectionChanged += (_, _) =>
            DispatcherQueue.TryEnqueue(ApplyVisibility);
        ApplyVisibility();
    }

    private void ApplyVisibility()
    {
        var showThread = _router.Section == ShellSection.Messages;
        ThreadHost.Visibility = showThread ? Visibility.Visible : Visibility.Collapsed;
        WidgetsHost.Visibility = showThread ? Visibility.Collapsed : Visibility.Visible;
    }
}
