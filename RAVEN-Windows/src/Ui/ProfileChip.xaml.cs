// ProfileChip.xaml.cs
//
// Bottom-of-rail user chip. Reads the local fingerprint via KeyStore so
// even an unauthenticated install shows *something* identifying. Once the
// login flow lands (M5 in HANDOFF.md), the username/handle here will be
// replaced with the server-resolved profile.

using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using RAVEN.Windows.Storage;

namespace RAVEN.Windows.Ui;

public sealed partial class ProfileChip : UserControl
{
    public ProfileChip()
    {
        this.InitializeComponent();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        // App.Services may not be ready in the XAML designer.
        if (App.Services is null) return;

        var keys = await App.Services.GetRequiredService<KeyStore>().LoadOrCreateAsync();
        var fingerprint = keys.Fingerprint;
        if (!string.IsNullOrEmpty(fingerprint))
        {
            DisplayName.Text = fingerprint.Length > 10
                ? fingerprint[..10]
                : fingerprint;
            Handle.Text = "@" + (fingerprint.Length > 6 ? fingerprint[..6] : fingerprint);
            AvatarLetter.Text = fingerprint[..1].ToUpperInvariant();
        }
    }

    private void OnPointerEntered(object sender, PointerRoutedEventArgs e)
    {
        RowBorder.Background = new SolidColorBrush(Color.FromArgb((byte)(0.05 * 255), 255, 255, 255));
    }

    private void OnPointerExited(object sender, PointerRoutedEventArgs e)
    {
        RowBorder.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
    }
}
