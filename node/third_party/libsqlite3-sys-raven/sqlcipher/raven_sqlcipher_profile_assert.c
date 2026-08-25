/*
 * Raven Task 0A.2 — compile-time SQLCipher profile freeze assertion.
 *
 * Compiled with the same cc::Build flags as sqlcipher/sqlite3.c so that any
 * injected -D / -include / response-file override that reaches the compiler
 * fails closed here even if env scanning missed it.
 */

#if !defined(SQLITE_HAS_CODEC)
#error "RAVEN_SQLCIPHER_PROFILE: SQLITE_HAS_CODEC required"
#endif

#if !defined(SQLITE_TEMP_STORE) || (SQLITE_TEMP_STORE != 2)
#error "RAVEN_SQLCIPHER_PROFILE: SQLITE_TEMP_STORE must equal 2"
#endif

#if defined(PBKDF2_ITER) && (PBKDF2_ITER != 256000)
#error "RAVEN_SQLCIPHER_PROFILE: PBKDF2_ITER override forbidden (must be unset or 256000)"
#endif

#if defined(FAST_PBKDF2_ITER) && (FAST_PBKDF2_ITER != 2)
#error "RAVEN_SQLCIPHER_PROFILE: FAST_PBKDF2_ITER override forbidden (must be unset or 2)"
#endif

#ifdef SQLCIPHER_CRYPTO_CC
#error "RAVEN_SQLCIPHER_PROFILE: SQLCIPHER_CRYPTO_CC forbidden in terminal OpenSSL lab"
#endif

#ifdef SQLCIPHER_CRYPTO_LIBTOMCRYPT
#error "RAVEN_SQLCIPHER_PROFILE: SQLCIPHER_CRYPTO_LIBTOMCRYPT forbidden in terminal OpenSSL lab"
#endif

#ifdef SQLCIPHER_CRYPTO_CUSTOM
#error "RAVEN_SQLCIPHER_PROFILE: SQLCIPHER_CRYPTO_CUSTOM forbidden in terminal OpenSSL lab"
#endif

#if !defined(SQLCIPHER_CRYPTO_OPENSSL)
#error "RAVEN_SQLCIPHER_PROFILE: SQLCIPHER_CRYPTO_OPENSSL required"
#endif

#if !defined(SQLITE_EXTRA_INIT)
#error "RAVEN_SQLCIPHER_PROFILE: SQLITE_EXTRA_INIT required"
#endif

#if !defined(SQLITE_EXTRA_SHUTDOWN)
#error "RAVEN_SQLCIPHER_PROFILE: SQLITE_EXTRA_SHUTDOWN required"
#endif

#if !defined(HAVE_STDINT_H) || (HAVE_STDINT_H != 1)
#error "RAVEN_SQLCIPHER_PROFILE: HAVE_STDINT_H=1 required"
#endif

#if !defined(SQLITE_THREADSAFE) || (SQLITE_THREADSAFE != 1)
#error "RAVEN_SQLCIPHER_PROFILE: SQLITE_THREADSAFE must equal 1"
#endif

/* Keep a tiny symbol so the TU is not empty on picky compilers. */
int raven_sqlcipher_profile_assert_anchor(void) { return 256000; }
