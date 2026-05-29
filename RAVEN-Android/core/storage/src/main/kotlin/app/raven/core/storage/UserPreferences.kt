package app.raven.core.storage

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Non-secret user preferences: chosen theme, locale override, tab
 * positions, "do not disturb" mode. Equivalent of the iOS
 * `AppSettings.shared` UserDefaults bag.
 *
 * Anything actually sensitive (tokens, identity keys, DB cipher) does
 * NOT come through here — that's [app.raven.core.security.SecureStore].
 */
private val Context.preferencesDataStore by preferencesDataStore(name = "raven.prefs")

@Singleton
class UserPreferences @Inject constructor(
    @ApplicationContext private val context: Context,
) {

    private val store get() = context.preferencesDataStore

    val themeMode: Flow<ThemeMode> = store.data.map { prefs ->
        when (prefs[KEY_THEME]) {
            "light" -> ThemeMode.LIGHT
            "system" -> ThemeMode.SYSTEM
            else -> ThemeMode.DARK
        }
    }

    val locale: Flow<String?> = store.data.map { it[KEY_LOCALE] }

    val dndEnabled: Flow<Boolean> = store.data.map { it[KEY_DND] ?: false }

    suspend fun setThemeMode(mode: ThemeMode) {
        store.edit { it[KEY_THEME] = mode.name.lowercase() }
    }

    suspend fun setLocale(tag: String?) {
        store.edit {
            if (tag.isNullOrBlank()) it.remove(KEY_LOCALE) else it[KEY_LOCALE] = tag
        }
    }

    suspend fun setDnd(enabled: Boolean) {
        store.edit { it[KEY_DND] = enabled }
    }

    enum class ThemeMode { DARK, LIGHT, SYSTEM }

    private companion object {
        val KEY_THEME: Preferences.Key<String> = stringPreferencesKey("theme")
        val KEY_LOCALE: Preferences.Key<String> = stringPreferencesKey("locale")
        val KEY_DND: Preferences.Key<Boolean> = booleanPreferencesKey("dnd")
    }
}
