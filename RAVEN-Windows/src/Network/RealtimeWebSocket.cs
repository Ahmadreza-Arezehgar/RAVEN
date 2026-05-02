// RealtimeWebSocket.cs
//
// Mirror of `Core/Realtime/RealtimeEngine.swift`. Persistent WebSocket to
// the FastAPI server's /ws/inbox endpoint for real-time message + ACK
// delivery while online.
//
// IMPORTANT: this version puts the auth token in the URL query string —
// matching iOS today. That's a known security issue (audit finding #4)
// and should move to Sec-WebSocket-Protocol header in v2.

using System;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;

namespace RAVEN.Windows.Network;

public sealed class RealtimeWebSocket : IAsyncDisposable
{
    private readonly ILogger<RealtimeWebSocket> _log;
    private readonly TokenStore _tokens;
    private readonly Uri _wsUri;
    private ClientWebSocket? _socket;
    private CancellationTokenSource? _cts;
    private Task? _receiveLoop;

    public event Action<string>? OnTextMessage;
    public event Action<bool>? OnConnectionStateChanged;

    public RealtimeWebSocket(ILogger<RealtimeWebSocket> log, TokenStore tokens, string baseUrl = ApiClient.DefaultBaseUrl)
    {
        _log = log;
        _tokens = tokens;
        var wsBase = baseUrl.Replace("https://", "wss://", StringComparison.OrdinalIgnoreCase)
                            .Replace("http://", "ws://", StringComparison.OrdinalIgnoreCase);
        _wsUri = new Uri($"{wsBase}/ws/inbox");
    }

    public async Task ConnectAsync(CancellationToken ct = default)
    {
        if (_socket?.State == WebSocketState.Open) return;

        var token = await _tokens.GetAccessAsync().ConfigureAwait(false);
        if (string.IsNullOrEmpty(token))
        {
            _log.LogWarning("RealtimeWebSocket: no access token; cannot connect.");
            return;
        }

        _socket = new ClientWebSocket();
        // Reconnect-friendly keepalive.
        _socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(30);

        var uri = new UriBuilder(_wsUri) { Query = $"token={Uri.EscapeDataString(token)}" }.Uri;
        _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        await _socket.ConnectAsync(uri, _cts.Token).ConfigureAwait(false);
        OnConnectionStateChanged?.Invoke(true);
        _log.LogInformation("RealtimeWebSocket connected.");

        _receiveLoop = Task.Run(() => ReceiveLoopAsync(_cts.Token), _cts.Token);
    }

    public async Task SendTextAsync(string json, CancellationToken ct = default)
    {
        if (_socket is null || _socket.State != WebSocketState.Open)
            throw new InvalidOperationException("WebSocket not connected");
        var bytes = Encoding.UTF8.GetBytes(json);
        await _socket.SendAsync(bytes, WebSocketMessageType.Text, endOfMessage: true, ct).ConfigureAwait(false);
    }

    public async Task DisconnectAsync()
    {
        if (_cts is not null) await _cts.CancelAsync().ConfigureAwait(false);

        if (_socket is { State: WebSocketState.Open or WebSocketState.CloseReceived })
        {
            try
            {
                await _socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "client closing", CancellationToken.None)
                    .ConfigureAwait(false);
            }
            catch { /* best effort */ }
        }
        _socket?.Dispose();
        _socket = null;
        OnConnectionStateChanged?.Invoke(false);
    }

    private async Task ReceiveLoopAsync(CancellationToken ct)
    {
        var buffer = new byte[64 * 1024];
        var msgBuffer = new System.IO.MemoryStream();
        try
        {
            while (!ct.IsCancellationRequested && _socket?.State == WebSocketState.Open)
            {
                msgBuffer.SetLength(0);
                WebSocketReceiveResult result;
                do
                {
                    result = await _socket.ReceiveAsync(buffer, ct).ConfigureAwait(false);
                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        OnConnectionStateChanged?.Invoke(false);
                        return;
                    }
                    msgBuffer.Write(buffer, 0, result.Count);
                } while (!result.EndOfMessage);

                var text = Encoding.UTF8.GetString(msgBuffer.ToArray());
                try
                {
                    OnTextMessage?.Invoke(text);
                }
                catch (Exception ex)
                {
                    _log.LogError(ex, "OnTextMessage handler threw");
                }
            }
        }
        catch (OperationCanceledException) { /* expected */ }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Receive loop ended");
            OnConnectionStateChanged?.Invoke(false);
        }
    }

    public async ValueTask DisposeAsync()
    {
        await DisconnectAsync().ConfigureAwait(false);
        _cts?.Dispose();
    }
}
