#include "lmdb.h"
#include <stdint.h>

int sapiens_kv_open(const char *path, MDB_env **env) {
 int rc = mdb_env_create(env);
 if (rc) return rc;
 /* One writer, durable commits, reader slots not tied to GHC worker threads. */
 rc = mdb_env_set_mapsize(*env, (size_t)1024 * 1024 * 1024);
 if (!rc) rc = mdb_env_open(*env, path, MDB_NOTLS, 0600);
 if (rc) { mdb_env_close(*env); *env = 0; }
 return rc;
}
int sapiens_kv_begin(MDB_env *env, int write, MDB_txn **txn) {
 return mdb_txn_begin(env, 0, write ? 0 : MDB_RDONLY, txn);
}
int sapiens_kv_put(MDB_txn *txn, const void *key, size_t kn, const void *value, size_t vn, int append) {
 MDB_dbi db; int rc = mdb_dbi_open(txn, 0, 0, &db);
 if (rc) return rc;
 MDB_val k = {kn, (void *)key}, v = {vn, (void *)value};
 return mdb_put(txn, db, &k, &v, append ? MDB_NOOVERWRITE : 0);
}
int sapiens_kv_cursor(MDB_txn *txn, MDB_cursor **cursor) {
 MDB_dbi db; int rc = mdb_dbi_open(txn, 0, 0, &db);
 return rc ? rc : mdb_cursor_open(txn, db, cursor);
}
int sapiens_kv_next(MDB_cursor *cursor, int first, const void **key, size_t *kn, const void **value, size_t *vn) {
 MDB_val k, v; int rc = mdb_cursor_get(cursor, &k, &v, first ? MDB_FIRST : MDB_NEXT);
 if (!rc) { *key = k.mv_data; *kn = k.mv_size; *value = v.mv_data; *vn = v.mv_size; }
 return rc;
}
int sapiens_kv_grow(MDB_env *env) {
 MDB_envinfo info; int rc = mdb_env_info(env, &info);
 if (rc) return rc;
 if (info.me_mapsize > SIZE_MAX / 2) return MDB_MAP_FULL;
 return mdb_env_set_mapsize(env, info.me_mapsize * 2);
}
int sapiens_kv_seek(MDB_cursor *cursor, const void *prefix, size_t pn, const void **key, size_t *kn, const void **value, size_t *vn) {
 MDB_val k = {pn, (void *)prefix}, v;
 int rc = mdb_cursor_get(cursor, &k, &v, MDB_SET_RANGE);
 if (!rc) { *key = k.mv_data; *kn = k.mv_size; *value = v.mv_data; *vn = v.mv_size; }
 return rc;
}
