// ApiClient.cs
//
// Mirror of `Core/Network/NetworkService.swift`. Talks to the same FastAPI
// server at https://raven-server-516053629173.europe-west1.run.app.
//
// Auth flow:
//   - On login: POST /api/auth/login → access_token + refresh_token
//   - Tokens stored via TokenStore (separate file for now, future: Credential Manager).
//   - All authenticated requests carry `Authorization: Bearer <access_token>`.
//   - On 401, attempt refresh once; if that fails, surface AuthExpiredException.

using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;

namespace RAVEN.Windows.Network;

public sealed class ApiClient : IDisposable
{
    public const string DefaultBaseUrl = "https://raven-server-516053629173.europe-west1.run.app";

    private readonly ILogger<ApiClient> _log;
    private readonly HttpClient _http;
    private readonly TokenStore _tokens;
    private readonly SemaphoreSlim _refreshLock = new(1, 1);

    public ApiClient(ILogger<ApiClient> log, TokenStore tokens, string? baseUrl = null)
    {
        _log = log;
        _tokens = tokens;
        _http = new HttpClient { BaseAddress = new Uri(baseUrl ?? DefaultBaseUrl) };
        _http.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("RAVEN-Windows", "1.5.0"));
    }

    // ─── Auth ────────────────────────────────────────────────────────

    public async Task<LoginResponse> LoginAsync(string email, string password, CancellationToken ct = default)
    {
        var resp = await _http.PostAsJsonAsync("/api/auth/login",
            new { email, password }, ct).ConfigureAwait(false);
        resp.EnsureSuccessStatusCode();
        var login = await resp.Content.ReadFromJsonAsync<LoginResponse>(cancellationToken: ct).ConfigureAwait(false)
                    ?? throw new InvalidOperationException("Empty login response");
        await _tokens.SaveAsync(login.AccessToken, login.RefreshToken).ConfigureAwait(false);
        return login;
    }

    public async Task<bool> RefreshAsync(CancellationToken ct = default)
    {
        await _refreshLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var refreshToken = await _tokens.GetRefreshAsync().ConfigureAwait(false);
            if (string.IsNullOrEmpty(refreshToken)) return false;

            var resp = await _http.PostAsJsonAsync("/api/auth/refresh",
                new { refresh_token = refreshToken }, ct).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode) return false;

            var refreshed = await resp.Content.ReadFromJsonAsync<RefreshResponse>(cancellationToken: ct).ConfigureAwait(false);
            if (refreshed is null || string.IsNullOrEmpty(refreshed.AccessToken)) return false;
            await _tokens.SaveAsync(refreshed.AccessToken, refreshed.RefreshToken ?? refreshToken).ConfigureAwait(false);
            return true;
        }
        finally
        {
            _refreshLock.Release();
        }
    }

    public async Task LogoutAsync(CancellationToken ct = default)
    {
        try
        {
            await SendAuthenticatedAsync(HttpMethod.Post, "/api/auth/logout", body: null, ct).ConfigureAwait(false);
        }
        catch { /* best effort */ }
        await _tokens.ClearAsync().ConfigureAwait(false);
    }

    // ─── Generic authenticated request ───────────────────────────────

    public async Task<HttpResponseMessage> SendAuthenticatedAsync(
        HttpMethod method, string path, object? body, CancellationToken ct = default)
    {
        var token = await _tokens.GetAccessAsync().ConfigureAwait(false);

        async Task<HttpResponseMessage> SendOnce()
        {
            using var req = new HttpRequestMessage(method, path);
            if (!string.IsNullOrEmpty(token))
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            if (body is not null)
                req.Content = JsonContent.Create(body);
            return await _http.SendAsync(req, ct).ConfigureAwait(false);
        }

        var resp = await SendOnce().ConfigureAwait(false);
        if (resp.StatusCode == HttpStatusCode.Unauthorized)
        {
            // Single retry with refreshed token.
            resp.Dispose();
            if (await RefreshAsync(ct).ConfigureAwait(false))
            {
                token = await _tokens.GetAccessAsync().ConfigureAwait(false);
                resp = await SendOnce().ConfigureAwait(false);
            }
            else
            {
                throw new AuthExpiredException();
            }
        }
        return resp;
    }

    // ─── QR-code desktop login (mirrors `server/routers/qr_login.py`) ─

    public async Task<QrLoginInitResponse> QrLoginInitAsync(CancellationToken ct = default)
    {
        var resp = await _http.PostAsync("/api/auth/qr-login/init", content: null, ct).ConfigureAwait(false);
        resp.EnsureSuccessStatusCode();
        return await resp.Content.ReadFromJsonAsync<QrLoginInitResponse>(cancellationToken: ct).ConfigureAwait(false)
               ?? throw new InvalidOperationException("Empty qr-login init response");
    }

    public async Task<QrLoginPollResponse> QrLoginPollAsync(string sessionId, string nonce, CancellationToken ct = default)
    {
        var path = $"/api/auth/qr-login/poll/{Uri.EscapeDataString(sessionId)}?nonce={Uri.EscapeDataString(nonce)}";
        var resp = await _http.GetAsync(path, ct).ConfigureAwait(false);
        resp.EnsureSuccessStatusCode();
        var poll = await resp.Content.ReadFromJsonAsync<QrLoginPollResponse>(cancellationToken: ct).ConfigureAwait(false)
                   ?? throw new InvalidOperationException("Empty poll response");
        if (poll.Status == "approved" && !string.IsNullOrEmpty(poll.Token))
        {
            await _tokens.SaveAsync(poll.Token!, poll.RefreshToken ?? string.Empty).ConfigureAwait(false);
        }
        return poll;
    }

    // ─── Mesh-bridge endpoints (online uplink for ACKs) ──────────────

    public async Task BridgeAckDeliveredAsync(string originalMessageId, string senderId, string recipientId, CancellationToken ct = default)
    {
        var resp = await SendAuthenticatedAsync(HttpMethod.Post, "/api/messages/ack-delivered",
            new
            {
                original_message_id = originalMessageId,
                sender_id = senderId,
                recipient_id = recipientId,
                path_used = "mesh-bridge",
                idempotency_key = $"ack-{originalMessageId}|{senderId}|{recipientId}|delivered",
            }, ct).ConfigureAwait(false);
        resp.EnsureSuccessStatusCode();
    }

    public void Dispose() => _http.Dispose();
}

public sealed class LoginResponse
{
    [JsonPropertyName("access_token")] public string AccessToken { get; set; } = string.Empty;
    [JsonPropertyName("refresh_token")] public string RefreshToken { get; set; } = string.Empty;
    [JsonPropertyName("user_id")] public string UserId { get; set; } = string.Empty;
}

public sealed class RefreshResponse
{
    [JsonPropertyName("access_token")] public string AccessToken { get; set; } = string.Empty;
    [JsonPropertyName("refresh_token")] public string? RefreshToken { get; set; }
}

public sealed class AuthExpiredException : Exception
{
    public AuthExpiredException() : base("Auth tokens expired; user must re-login.") { }
}

public sealed class QrLoginInitResponse
{
    [JsonPropertyName("sessionId")] public string SessionId { get; set; } = string.Empty;
    [JsonPropertyName("nonce")] public string Nonce { get; set; } = string.Empty;
    [JsonPropertyName("expiresAt")] public DateTime ExpiresAt { get; set; }
}

public sealed class QrLoginPollResponse
{
    [JsonPropertyName("status")] public string Status { get; set; } = string.Empty;
    [JsonPropertyName("token")] public string? Token { get; set; }
    [JsonPropertyName("refreshToken")] public string? RefreshToken { get; set; }
    [JsonPropertyName("userId")] public string? UserId { get; set; }
    [JsonPropertyName("username")] public string? Username { get; set; }
}
