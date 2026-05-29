package app.raven.core.network

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/**
 * Long-lived WebSocket client for the inbox event stream.
 *
 * Server endpoint: `wss://<host>/ws/inbox`
 *   - Phase 1 (round-5 hardening) made `/ws/inbox` accept
 *     `Authorization: Bearer <JWT>` on the upgrade request — same
 *     header path the Windows client uses. We never put the token
 *     in the URL.
 *
 * Lifecycle:
 *   - [connect] — fire-once entrypoint. Idempotent: while a socket
 *     is open or being-opened, repeated calls are no-ops.
 *   - [disconnect] — graceful close + cancels the supervisor scope
 *     so the reconnect loop stops.
 *
 * Reconnect: exponential back-off capped at 30s. The OS network
 * stack tells us when connectivity drops; we just keep retrying
 * until either we succeed or the caller disconnects.
 *
 * Out: every payload arrives via [events] as a raw JSON string —
 * the consumer (chat repository) decodes into the right model. We
 * don't bind to a specific schema here so future event shapes
 * (typing indicators, read receipts) don't need a core-network
 * change.
 *
 * State: [connectionState] is a one-source-of-truth flag the
 * caller can render as a network-status pill (matches iOS
 * `ConnectionStatusPill`).
 */
class RealtimeWebSocket(
    private val baseHttpUrl: String,
    private val okHttp: OkHttpClient,
    private val tokenProvider: TokenProvider,
) {
    enum class State { Disconnected, Connecting, Connected }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _state = MutableStateFlow(State.Disconnected)
    val connectionState: StateFlow<State> = _state.asStateFlow()

    private val _events = MutableSharedFlow<String>(
        replay = 0,
        extraBufferCapacity = 64,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    val events: SharedFlow<String> = _events.asSharedFlow()

    @Volatile
    private var currentSocket: WebSocket? = null
    private var loopJob: Job? = null

    /**
     * Open the socket (if not already) and keep it open with auto-
     * reconnect. Safe to call multiple times — extra calls are
     * dropped while the connection is healthy.
     */
    fun connect() {
        if (loopJob?.isActive == true) return
        loopJob = scope.launch {
            var backoffMs = 1_000L
            while (isLoopRunning()) {
                val token = tokenProvider.accessToken()
                if (token.isNullOrBlank()) {
                    // No session — back off, then re-check. The
                    // caller usually calls disconnect on logout
                    // anyway, but this protects against a startup
                    // race where the bootstrap hasn't finished.
                    delay(backoffMs)
                    backoffMs = (backoffMs * 2).coerceAtMost(30_000L)
                    continue
                }
                val url = wsUrlFromHttp(baseHttpUrl)
                val request = Request.Builder()
                    .url(url)
                    .header("Authorization", "Bearer $token")
                    .header("X-Raven-Client", "android")
                    .build()

                _state.value = State.Connecting
                val signal = WaitForClose()
                val socket = okHttp.newWebSocket(request, RavenListener(signal))
                currentSocket = socket

                // Block this loop iteration until the socket closes.
                val closedCleanly = signal.await()
                _state.value = State.Disconnected

                // Reset back-off on clean close (logout), keep it
                // climbing on transient failures.
                backoffMs = if (closedCleanly) 1_000L else (backoffMs * 2).coerceAtMost(30_000L)
                delay(backoffMs)
            }
        }
    }

    /** Graceful shutdown. After this the socket stays closed until
     *  the caller invokes [connect] again. */
    fun disconnect() {
        loopJob?.cancel()
        loopJob = null
        currentSocket?.close(1000, "client disconnect")
        currentSocket = null
        _state.value = State.Disconnected
    }

    /**
     * Optional client-to-server send. Phase 2b doesn't use it
     * (everything goes via REST), but typing-indicators in 2c
     * will. Returns false when no socket is open.
     */
    fun sendText(payload: String): Boolean {
        val s = currentSocket ?: return false
        return s.send(payload)
    }

    private fun isLoopRunning(): Boolean = loopJob?.isActive == true

    private inner class RavenListener(
        private val signal: WaitForClose,
    ) : WebSocketListener() {

        override fun onOpen(webSocket: WebSocket, response: Response) {
            _state.value = State.Connected
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            _events.tryEmit(text)
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(code, reason)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            currentSocket = null
            signal.complete(closedCleanly = (code == 1000))
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            currentSocket = null
            signal.complete(closedCleanly = false)
        }
    }

    /** Single-shot completer — the connect loop awaits this so each
     *  socket runs to completion before the next reconnect cycle. */
    private class WaitForClose {
        private val deferred = CompletableDeferred<Boolean>()
        suspend fun await(): Boolean = deferred.await()
        fun complete(closedCleanly: Boolean) {
            deferred.complete(closedCleanly)
        }
    }
}

/** Convert https:// → wss:// and append the inbox path. */
private fun wsUrlFromHttp(httpUrl: String): String {
    val trimmed = httpUrl.trimEnd('/')
    val withScheme = when {
        trimmed.startsWith("https://") -> "wss://" + trimmed.removePrefix("https://")
        trimmed.startsWith("http://") -> "ws://" + trimmed.removePrefix("http://")
        else -> trimmed
    }
    return "$withScheme/ws/inbox"
}
