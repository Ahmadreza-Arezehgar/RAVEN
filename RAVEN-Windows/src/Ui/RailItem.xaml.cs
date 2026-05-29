// RailItem.xaml.cs
//
// Capsule rail-row UserControl. One per nav section (Home, Explore,
// Notifications, Messages, Profile). Visual states match the Mac app's
// `RailItem` (RailView.swift):
//   - default:  70% white text, no background
//   - hover:    same text, 5% white capsule background
//   - selected: 100% white text, bold weight, no background tint (Mac's
//               selection cue is just bold + filled SF Symbol; we mirror
//               that with an "iconActive" glyph swap and FontWeight.Bold)

using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace RAVEN.Windows.Ui;

public sealed partial class RailItem : UserControl
{
    public static readonly DependencyProperty IconProperty =
        DependencyProperty.Register(nameof(Icon), typeof(string), typeof(RailItem),
            new PropertyMetadata(""));
    public string Icon
    {
        get => (string)GetValue(IconProperty);
        set => SetValue(IconProperty, value);
    }

    /// Optional alternate glyph used while selected (Mac's "filled" SF
    /// Symbol equivalent). If empty, the same Icon is used.
    public static readonly DependencyProperty IconActiveProperty =
        DependencyProperty.Register(nameof(IconActive), typeof(string), typeof(RailItem),
            new PropertyMetadata("", OnVisualPropertyChanged));
    public string IconActive
    {
        get => (string)GetValue(IconActiveProperty);
        set => SetValue(IconActiveProperty, value);
    }

    public static readonly DependencyProperty LabelProperty =
        DependencyProperty.Register(nameof(Label), typeof(string), typeof(RailItem),
            new PropertyMetadata("Item"));
    public string Label
    {
        get => (string)GetValue(LabelProperty);
        set => SetValue(LabelProperty, value);
    }

    public static readonly DependencyProperty IsSelectedProperty =
        DependencyProperty.Register(nameof(IsSelected), typeof(bool), typeof(RailItem),
            new PropertyMetadata(false, OnVisualPropertyChanged));
    public bool IsSelected
    {
        get => (bool)GetValue(IsSelectedProperty);
        set => SetValue(IsSelectedProperty, value);
    }

    public Brush LabelBrush => IsSelected
        ? (Brush)Application.Current.Resources["RavenText"]
        : new SolidColorBrush(Color.FromArgb((byte)(0.7 * 255), 255, 255, 255));

    public FontWeight LabelWeight => IsSelected
        ? Microsoft.UI.Text.FontWeights.Bold
        : Microsoft.UI.Text.FontWeights.Medium;

    public RailItem()
    {
        this.InitializeComponent();
        UpdateVisualState();
    }

    private static void OnVisualPropertyChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is RailItem row) row.UpdateVisualState();
    }

    private bool _isHover;

    private void OnPointerEntered(object sender, PointerRoutedEventArgs e)
    {
        _isHover = true;
        UpdateVisualState();
    }

    private void OnPointerExited(object sender, PointerRoutedEventArgs e)
    {
        _isHover = false;
        UpdateVisualState();
    }

    private new void OnTapped(object sender, TappedRoutedEventArgs e)
    {
        Tapped?.Invoke(this, e);
    }

    public new event TappedEventHandler? Tapped;

    private void UpdateVisualState()
    {
        // Selection has no special tint — Mac uses bold+fill swap only.
        // Hover paints a 5% white capsule.
        if (_isHover && !IsSelected)
        {
            RowBorder.Background = new SolidColorBrush(Color.FromArgb((byte)(0.05 * 255), 255, 255, 255));
        }
        else
        {
            RowBorder.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        }

        // Swap to the "active" glyph when selected, if one was provided.
        if (IsSelected && !string.IsNullOrEmpty(IconActive))
        {
            IconGlyph.Glyph = IconActive;
        }
        else
        {
            IconGlyph.Glyph = Icon;
        }

        Bindings.Update();
    }
}
