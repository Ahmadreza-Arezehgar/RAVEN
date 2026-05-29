package app.raven.core.network

/**
 * Production / staging server URLs — mirror of
 * `AppConfig.serverList` in
 * `ios-native/RAVEN/RAVEN/Core/Config/AppConfig.swift`.
 *
 * Single region today (Belgium). When the iOS app re-adds regional
 * failovers, drop them in [ALL] and the routing layer (a future
 * `ServerFailover` class) will sweep them in latency order.
 */
object RavenServer {
    const val PRODUCTION_BELGIUM = "https://raven-server-516053629173.europe-west1.run.app"
    val ALL: List<String> = listOf(PRODUCTION_BELGIUM)

    /** Local dev override — flip this to your laptop IP if you want
     *  to point a debug build at a Cloud-Run-on-localhost. */
    const val LOCAL_DEV = "http://10.0.2.2:8000"  // 10.0.2.2 = host loopback on emulator

    fun activeBaseUrl(useLocal: Boolean = false): String =
        if (useLocal) LOCAL_DEV else PRODUCTION_BELGIUM
}
