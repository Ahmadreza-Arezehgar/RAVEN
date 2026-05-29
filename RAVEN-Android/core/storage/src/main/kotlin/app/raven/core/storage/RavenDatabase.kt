package app.raven.core.storage

import androidx.room.Database
import androidx.room.RoomDatabase

/**
 * The single Room database. We bump [VERSION] when the schema
 * changes and add a Migration in [RavenDatabaseModule].
 *
 * Encryption: the database is opened through SQLCipher's
 * `SupportFactory` — see `RavenDatabaseModule.provideDatabase`. The
 * passphrase comes from [app.raven.core.security.SecureStore] which
 * itself is Android Keystore-backed. Net result: at-rest DB file is
 * AES-256 ciphertext, and the passphrase never leaves the Keystore-
 * fenced shared-prefs. Mirror of iOS SQLCipher + Keychain.
 */
@Database(
    entities = [
        MessageEntity::class,
        ConversationEntity::class,
        UserEntity::class,
    ],
    version = RavenDatabase.VERSION,
    exportSchema = true,
)
abstract class RavenDatabase : RoomDatabase() {

    abstract fun messages(): MessageDao
    abstract fun conversations(): ConversationDao
    abstract fun users(): UserDao

    companion object {
        /**
         * v2 (Phase 2b): adds reply + denormalised sender on
         * [MessageEntity], and mute / group / denormalised-peer
         * columns on [ConversationEntity]. The module is configured
         * with `fallbackToDestructiveMigration()` for the pre-1.0
         * phase, so an existing dev install just nukes its cache on
         * the bump — no production-data risk.
         */
        const val VERSION = 2
        const val DB_NAME = "raven.db"
    }
}
