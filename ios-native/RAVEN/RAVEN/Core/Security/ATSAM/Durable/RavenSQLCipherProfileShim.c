// Task 0A.4 lab-only shim. Swift cannot call sqlite3_db_config's variadic ABI.
// Keep this wrapper integer-only and linked into the main app image.

typedef struct sqlite3 sqlite3;
extern int sqlite3_db_config(sqlite3 *, int, ...);

int raven_sqlcipher_db_config_int(sqlite3 *db, int op, int value, int *readback) {
    return sqlite3_db_config(db, op, value, readback);
}
