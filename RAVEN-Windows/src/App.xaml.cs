// App.xaml.cs
//
// Application entry point. Brings up the singleton services
// (KeyStore, EncryptedDb, BleEngine, MessageRouter) and shows the main window.

using System;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.UI.Xaml;
using RAVEN.Windows.Crypto;
using RAVEN.Windows.Mesh;
using RAVEN.Windows.Network;
using RAVEN.Windows.Storage;
using RAVEN.Windows.Ui;

namespace RAVEN.Windows;

public partial class App : Application
{
    public static IServiceProvider Services { get; private set; } = default!;
    private Window? _window;

    public App()
    {
        this.InitializeComponent();
    }

    private TrayService? _tray;

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        Services = await BuildServicesAsync();

        _window = new MainWindow();
        _window.Activate();

        // Boot the mesh engine.
        var ble = Services.GetRequiredService<BleEngine>();
        await ble.StartAsync();

        // Install the tray icon so closing the window keeps mesh alive.
        _tray = new TrayService(_window, ble);
        _tray.Install();
    }

    private static async Task<IServiceProvider> BuildServicesAsync()
    {
        var services = new ServiceCollection();

        services.AddLogging(b =>
        {
            b.SetMinimumLevel(LogLevel.Information);
            b.AddDebug();
        });

        services.AddSingleton<KeyStore>();
        services.AddSingleton<TokenStore>();
        services.AddSingleton<EncryptedDb>();
        services.AddSingleton<DedupRepository>(sp =>
        {
            var db = sp.GetRequiredService<EncryptedDb>();
            return new DedupRepository(sp.GetRequiredService<ILogger<DedupRepository>>(), db.Connection);
        });
        services.AddSingleton<TrustStore>(sp =>
        {
            var db = sp.GetRequiredService<EncryptedDb>();
            return new TrustStore(sp.GetRequiredService<ILogger<TrustStore>>(), db.Connection);
        });
        services.AddSingleton<ApiClient>();
        services.AddSingleton<RealtimeWebSocket>();

        services.AddSingleton<BleEngine>(sp =>
        {
            var keys = sp.GetRequiredService<KeyStore>().LoadOrCreateAsync().GetAwaiter().GetResult();
            return new BleEngine(sp.GetRequiredService<ILogger<BleEngine>>(), keys.Ed25519PublicKey);
        });
        services.AddSingleton<MessageRouter>();

        var sp = services.BuildServiceProvider();

        // Open the encrypted DB and run schema migrations.
        var encDb = sp.GetRequiredService<EncryptedDb>();
        await encDb.OpenAsync();
        await sp.GetRequiredService<DedupRepository>().InitializeAsync();
        await sp.GetRequiredService<TrustStore>().InitializeAsync();

        return sp;
    }
}
