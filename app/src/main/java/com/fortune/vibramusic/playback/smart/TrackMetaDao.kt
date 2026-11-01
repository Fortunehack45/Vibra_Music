package com.fortune.vibramusic.playback.smart

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Lightweight native SQLite store for instantaneous track metadata lookup.
 * Single small table: track_meta(track_id PK, bpm REAL, bpm_conf REAL, bpm_src INT,
 *                                 key_code TEXT, key_conf REAL, key_src INT,
 *                                 version INT, updated_at INT).
 */
class TrackMetaDao(context: Context) : SQLiteOpenHelper(context, DATABASE_NAME, null, DATABASE_VERSION) {

    companion object {
        private const val DATABASE_NAME = "track_meta.db"
        private const val DATABASE_VERSION = 1
        private const val TABLE_NAME = "track_meta"

        private const val COL_TRACK_ID = "track_id"
        private const val COL_BPM = "bpm"
        private const val COL_BPM_CONF = "bpm_conf"
        private const val COL_BPM_SRC = "bpm_src"
        private const val COL_KEY_CODE = "key_code"
        private const val COL_KEY_CONF = "key_conf"
        private const val COL_KEY_SRC = "key_src"
        private const val COL_VERSION = "version"
        private const val COL_UPDATED_AT = "updated_at"
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS $TABLE_NAME (
                $COL_TRACK_ID TEXT PRIMARY KEY,
                $COL_BPM REAL,
                $COL_BPM_CONF REAL,
                $COL_BPM_SRC INTEGER,
                $COL_KEY_CODE TEXT,
                $COL_KEY_CONF REAL,
                $COL_KEY_SRC INTEGER,
                $COL_VERSION INTEGER,
                $COL_UPDATED_AT INTEGER
            )
            """.trimIndent()
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS idx_meta_updated ON $TABLE_NAME($COL_UPDATED_AT)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        db.execSQL("DROP TABLE IF EXISTS $TABLE_NAME")
        onCreate(db)
    }

    suspend fun all(): List<TrackMeta> = withContext(Dispatchers.IO) {
        val list = mutableListOf<TrackMeta>()
        val db = readableDatabase
        db.rawQuery("SELECT * FROM $TABLE_NAME", null).use { cursor ->
            val idIdx = cursor.getColumnIndexOrThrow(COL_TRACK_ID)
            val bpmIdx = cursor.getColumnIndexOrThrow(COL_BPM)
            val bpmConfIdx = cursor.getColumnIndexOrThrow(COL_BPM_CONF)
            val bpmSrcIdx = cursor.getColumnIndexOrThrow(COL_BPM_SRC)
            val keyIdx = cursor.getColumnIndexOrThrow(COL_KEY_CODE)
            val keyConfIdx = cursor.getColumnIndexOrThrow(COL_KEY_CONF)
            val keySrcIdx = cursor.getColumnIndexOrThrow(COL_KEY_SRC)
            val verIdx = cursor.getColumnIndexOrThrow(COL_VERSION)
            val updatedIdx = cursor.getColumnIndexOrThrow(COL_UPDATED_AT)

            val sources = MetaSource.entries

            while (cursor.moveToNext()) {
                val trackId = cursor.getString(idIdx)
                val bpm = if (!cursor.isNull(bpmIdx)) {
                    val b = cursor.getDouble(bpmIdx)
                    val conf = cursor.getFloat(bpmConfIdx)
                    val srcOrd = cursor.getInt(bpmSrcIdx)
                    val src = sources.getOrNull(srcOrd) ?: MetaSource.ANALYZED_FAST
                    Field(b, conf, src)
                } else null

                val key = if (!cursor.isNull(keyIdx)) {
                    val code = cursor.getString(keyIdx)
                    val camelot = CamelotKey.parse(code)
                    if (camelot != null) {
                        val conf = cursor.getFloat(keyConfIdx)
                        val srcOrd = cursor.getInt(keySrcIdx)
                        val src = sources.getOrNull(srcOrd) ?: MetaSource.ANALYZED_FAST
                        Field(camelot, conf, src)
                    } else null
                } else null

                val ver = cursor.getInt(verIdx)
                val updated = cursor.getLong(updatedIdx)

                list += TrackMeta(
                    trackId = trackId,
                    bpm = bpm,
                    key = key,
                    analyzerVersion = ver,
                    updatedAt = updated,
                )
            }
        }
        list
    }

    suspend fun upsert(meta: TrackMeta) = withContext(Dispatchers.IO) {
        val values = ContentValues().apply {
            put(COL_TRACK_ID, meta.trackId)
            if (meta.bpm != null) {
                put(COL_BPM, meta.bpm.value)
                put(COL_BPM_CONF, meta.bpm.confidence)
                put(COL_BPM_SRC, meta.bpm.source.ordinal)
            } else {
                putNull(COL_BPM)
                putNull(COL_BPM_CONF)
                putNull(COL_BPM_SRC)
            }
            if (meta.key != null) {
                put(COL_KEY_CODE, meta.key.value.code)
                put(COL_KEY_CONF, meta.key.confidence)
                put(COL_KEY_SRC, meta.key.source.ordinal)
            } else {
                putNull(COL_KEY_CODE)
                putNull(COL_KEY_CONF)
                putNull(COL_KEY_SRC)
            }
            put(COL_VERSION, meta.analyzerVersion)
            put(COL_UPDATED_AT, meta.updatedAt)
        }
        writableDatabase.insertWithOnConflict(
            TABLE_NAME,
            null,
            values,
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    suspend fun purge() = withContext(Dispatchers.IO) {
        writableDatabase.delete(TABLE_NAME, null, null)
    }

    suspend fun delete(trackId: String) = withContext(Dispatchers.IO) {
        writableDatabase.delete(TABLE_NAME, "$COL_TRACK_ID = ?", arrayOf(trackId))
    }
}
