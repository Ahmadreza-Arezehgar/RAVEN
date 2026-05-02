// SidebarRow.xaml.cs
//
// Capsule sidebar row — mirrors `iOS-Mac RavenMacShell.SidebarRow`.
// Selection state animates background tint + stroke; hover state dims.

using System;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace RAVEN.Windows.Ui;

public sealed partial class SidebarRow : UserControl
{
    // ─── Dependency properties ───────────────────────────────────────

    public static readonly DependencyProperty IconProperty =
        DependencyProperty.Register(nameof(Icon), typeof(string), typeof(SidebarRow), new PropertyMetadata(""));
    public string Icon
    {
        get => (string)GetValue(IconProperty);
        set => SetValue(IconProperty, value);
    }

    public static readonly DependencyProperty LabelProperty =
        DependencyProperty.Register(nameof(Label), typeof(string), typeof(SidebarRow), new PropertyMetadata("Item"));
    public string Label
    {
        get => (string)GetValue(LabelProperty);
        set => SetValue(LabelProperty, value);
    }

    public static readonly DependencyProperty TintProperty =
        DependencyProperty.Register(nameof(Tint), typeof(Brush), typeof(SidebarRow), new PropertyMetadata(null, OnTintOrSelectedChanged));
    public Brush Tint
    {
        get => (Brush)GetValue(TintProperty);
        set => SetValue(TintProperty, value);
    }

    public static readonly DependencyProperty IsSelectedProperty =
        DependencyProperty.Register(nameof(IsSelected), typeof(bool), typeof(SidebarRow), new PropertyMetadata(false, OnTintOrSelectedChanged));
    public bool IsSelected
    {
        get => (bool)GetValue(IsSelectedProperty);
        set => SetValue(IsSelectedProperty, value);
    }

    // ─── Bindings derived from above ─────────────────────────────────

    public Brush IconBrush => IsSelected ? (Tint ?? new SolidColorBrush(Microsoft.UI.Colors.MediumPurple))
                                         : (Brush)Application.Current.Resources["RavenText3"];

    public Brush LabelBrush => IsSelected ? (Brush)Application.Current.Resources["RavenText"]
                                          : (Brush)Application.Current.Resources["RavenText2"];

    public FontWeight LabelWeight => IsSelected ? Microsoft.UI.Text.FontWeights.SemiBold
                                                : Microsoft.UI.Text.FontWeights.Medium;

    public SidebarRow()
    {
        this.InitializeComponent();
        UpdateVisualState();
    }

    private static void OnTintOrSelectedChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is SidebarRow row) row.UpdateVisualState();
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
        // Selection background = tint at 16% opacity, stroke at 35%.
        // Hover = generic light surface at 5%.
        if (IsSelected && Tint is SolidColorBrush tintBrush)
        {
            var bg = tintBrush.Color;
            bg.A = (byte)(0.16 * 255);
            RowBorder.Background = new SolidColorBrush(bg);

            var border = tintBrush.Color;
            border.A = (byte)(0.35 * 255);
            RowBorder.BorderBrush = new SolidColorBrush(border);
        }
        else if (_isHover)
        {
            RowBorder.Background = new SolidColorBrush(Color.FromArgb((byte)(0.05 * 255), 255, 255, 255));
            RowBorder.BorderBrush = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        }
        else
        {
            RowBorder.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            RowBorder.BorderBrush = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        }

        // Refresh derived bindings (manual since they're not Dependency Properties).
        Bindings.Update();
    }
}
