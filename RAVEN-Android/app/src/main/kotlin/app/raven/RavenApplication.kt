package app.raven

import android.app.Application
import dagger.hilt.android.HiltAndroidApp

/**
 * Process-wide Application class. Hilt-annotated so the dependency
 * graph is generated at compile time and rooted here.
 *
 * Nothing else lives in this file by design — startup work goes into
 * dedicated initialisers (DI'd into here later) so we can profile
 * and lazily defer non-critical paths.
 */
@HiltAndroidApp
class RavenApplication : Application()
