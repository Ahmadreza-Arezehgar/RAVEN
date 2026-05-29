// QrLoginView.xaml.cs
//
// Drives the WhatsApp-Web-style scan-to-login flow on Windows.
// Calls ApiClient.QrLoginInitAsync once, renders the QR, then polls every
// 2s until status flips to approved/denied/expired. Tokens are persisted
// inside ApiClient.QrLoginPollAsync; this view raises `LoginCompleted`
// for the host to swap to the main window.

using System;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using QRCoder;
using RAVEN.Windows.Network;

namespace RAVEN.Windows.Ui;

public sealed partial class QrLoginView : UserControl
{
    private readonly ApiClient _api;
    private readonly ILogger<QrLoginView> _log;

    private CancellationTokenSource? _cts;
    private string? _sessionId;
    private string? _nonce;
    private DateTime _expiresAt = DateTime.MinValue;

    public event Action<string /*userId*/, string /*username*/>? LoginCompleted;

    public QrLoginView()
    {
        this.InitializeComponent();
        _api = App.Services.GetRequiredService<ApiClient>();
        _log = App.Services.GetRequiredService<ILogger<QrLoginView>>();
        this.Loaded += (_, _) => _ = StartAsync();
        this.Unloaded += (_, _) => _cts?.Cancel();
    }

    private async Task StartAsync()
    {
        _cts?.Cancel();
        _cts = new CancellationTokenSource();
        SetStatus("Generating code…");
        RetryButton.Visibility = Visibility.Collapsed;

        try
        {
            var init = await _api.QrLoginInitAsync(_cts.Token);
            _sessionId = init.SessionId;
            _nonce = init.Nonce;
            _expiresAt = init.ExpiresAt;

            // The QR encodes the same payload Flutter expects: base64url
            // of {"v":1,"type":"desktop_login","sid":"...","n":"...","exp":<unix>}.
            var payloadJson = JsonSerializer.Serialize(new
            {
                v = 1,
                type = "desktop_login",
                sid = _sessionId,
                n = _nonce,
                exp = new DateTimeOffset(_expiresAt, TimeSpan.Zero).ToUnixTimeSeconds(),
            });
            var payloadB64 = ToBase64Url(Encoding.UTF8.GetBytes(payloadJson));

            RenderQr(payloadB64);
            SetStatus($"Waiting for scan… expires in {RemainingSeconds()} s");
            _ = PollLoopAsync(_cts.Token);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            _log.LogError(ex, "QR login init failed");
            SetStatus("Couldn't reach server. Check your connection.");
            RetryButton.Visibility = Visibility.Visible;
        }
    }

    private async Task PollLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && _sessionId is not null && _nonce is not null)
        {
            try
            {
                var poll = await _api.QrLoginPollAsync(_sessionId, _nonce, ct);
                switch (poll.Status)
                {
                    case "pending":
                        SetStatus($"Waiting for scan… expires in {RemainingSeconds()} s");
                        break;
                    case "scanned":
                        SetStatus("Scanned. Confirm on your phone…");
                        break;
                    case "approved":
                        SetStatus("Logged in! Loading your account…");
                        if (poll.UserId is not null && poll.Username is not null)
                        {
                            LoginCompleted?.Invoke(poll.UserId, poll.Username);
                        }
                        return;
                    case "denied":
                        SetStatus("Login was declined on your phone.");
                        RetryButton.Visibility = Visibility.Visible;
                        return;
                    case "expired":
                        SetStatus("QR code expired. Generate a new one.");
                        RetryButton.Visibility = Visibility.Visible;
                        return;
                }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex)
            {
                // Tolerate transient errors; keep polling unless the session
                // has expired locally.
                _log.LogDebug(ex, "Poll error (will retry)");
                if (DateTime.UtcNow > _expiresAt)
                {
                    SetStatus("QR code expired. Generate a new one.");
                    RetryButton.Visibility = Visibility.Visible;
                    return;
                }
            }
            try { await Task.Delay(TimeSpan.FromSeconds(2), ct); }
            catch (OperationCanceledException) { return; }
        }
    }

    private void OnRetryClick(object sender, RoutedEventArgs e) => _ = StartAsync();

    private void RenderQr(string payload)
    {
        try
        {
            using var generator = new QRCodeGenerator();
            using var data = generator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.M);
            var pngBytes = new PngByteQRCode(data).GetGraphic(20);
            var stream = new InMemoryStream(pngBytes);
            var bitmap = new BitmapImage();
            _ = bitmap.SetSourceAsync(stream.RandomAccessStream);
            QrImage.Source = bitmap;
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "QR render failed");
            SetStatus("Couldn't render QR code.");
        }
    }

    private void SetStatus(string text)
    {
        if (DispatcherQueue.HasThreadAccess) StatusLabel.Text = text;
        else DispatcherQueue.TryEnqueue(() => StatusLabel.Text = text);
    }

    private int RemainingSeconds()
    {
        var s = (int)Math.Max(0, (_expiresAt - DateTime.UtcNow).TotalSeconds);
        return s;
    }

    private static string ToBase64Url(byte[] bytes)
    {
        return Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }
}

// Tiny adapter so we can hand a byte[] off to a WinRT consumer that wants
// an IRandomAccessStream. WinUI's BitmapImage.SetSourceAsync needs one.
internal sealed class InMemoryStream
{
    public Windows.Storage.Streams.IRandomAccessStream RandomAccessStream { get; }

    public InMemoryStream(byte[] bytes)
    {
        var ms = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        using (var writer = new Windows.Storage.Streams.DataWriter(ms.GetOutputStreamAt(0)))
        {
            writer.WriteBytes(bytes);
            writer.StoreAsync().AsTask().GetAwaiter().GetResult();
        }
        RandomAccessStream = ms;
    }
}
