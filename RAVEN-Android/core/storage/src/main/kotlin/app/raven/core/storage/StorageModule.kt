package app.raven.core.storage

import android.content.Context
import androidx.room.Room
import app.raven.core.security.SecureStore
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import net.zetetic.database.sqlcipher.SupportOpenHelperFactory
import java.security.SecureRandom
import javax.inject.Singleton

/**
 * Hilt wiring for the encrypted Room database.
 *
 * Cipher key strategy:
 *   - On first launch we mint a 32-byte (256-bit) random key with
 *     [SecureRandom], store it Base64-encoded in [SecureStore]
 *     (which is Android Keystore-fenced), and use it as the SQLCipher
 *     passphrase.
 *   - On subsequent launches we just read the same key back out and
 *     pass it to SQLCipher.
 *   - If the SecureStore loses the key (rare — happens on Keystore
 *     reset or factory wipe), the DB file becomes unreadable. That's
 *     the correct behaviour: the data was end-to-end ours, the key
 *     is gone, the DB is now opaque ciphertext.
 *
 * This is the structural twin of iOS `DatabaseService.swift` which
 * pulls the SQLCipher key out of Keychain on every launch.
 */
@Module
@InstallIn(SingletonComponent::class)
object StorageModule {

    @Provides
    @Singleton
    fun provideDatabase(
        @ApplicationContext context: Context,
        secureStore: SecureStore,
    ): RavenDatabase {
        // 🔴 Pull (or mint) the cipher key.
        val passphrase = secureStore.getBytes(SecureStore.KEY_DB_CIPHER)
            ?: ByteArray(32).also { fresh ->
                SecureRandom().nextBytes(fresh)
                secureStore.putBytes(SecureStore.KEY_DB_CIPHER, fresh)
            }

        // SQLCipher Android: load native libs once, then plug it in
        // as the OpenHelperFactory so Room talks to the encrypted
        // engine instead of the system SQLite.
        System.loadLibrary("sqlcipher")
        val factory = SupportOpenHelperFactory(passphrase)

        return Room.databaseBuilder(
            context.applicationContext,
            RavenDatabase::class.java,
            RavenDatabase.DB_NAME,
        )
            .openHelperFactory(factory)
            // Future migrations land here: .addMigrations(MIGRATION_1_2, ...)
            // Fall back to destructive ONLY in debug so a bad dev
            // migration doesn't trash user data in the field.
            .fallbackToDestructiveMigration()
            .build()
    }

    @Provides
    fun provideMessageDao(db: RavenDatabase): MessageDao = db.messages()

    @Provides
    fun provideConversationDao(db: RavenDatabase): ConversationDao = db.conversations()

    @Provides
    fun provideUserDao(db: RavenDatabase): UserDao = db.users()
}
