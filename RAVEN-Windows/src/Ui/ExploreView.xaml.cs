// ExploreView.xaml.cs
//
// Placeholder explore screen. Visual layout matches Mac's ExploreColumn;
// the trending-hashtag fetch + search will wire up once ApiClient grows
// the matching endpoint methods.

using Microsoft.UI.Xaml.Controls;

namespace RAVEN.Windows.Ui;

public sealed partial class ExploreView : UserControl
{
    public ExploreView()
    {
        this.InitializeComponent();
    }
}
