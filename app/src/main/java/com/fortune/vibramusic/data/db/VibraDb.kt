package com.fortune.vibramusic.data.db

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class VibraDb private constructor(context: Context) : SQLiteOpenHelper(context, DATABASE_NAME, null, DATABASE_VERSION) {

    private val converters = MixTypeConverters()

    private val dao = object : AnalysisDao {
        override suspend fun getTrackAnalysis(trackId: String): TrackAnalysis? = withContext(Dispatchers.IO) {
            val db = readableDatabase
            db.rawQuery("SELECT * FROM track_analysis WHERE trackId = ? LIMIT 1", arrayOf(trackId)).use { cursor ->
                if (!cursor.moveToFirst()) return@withContext null
                readTrackAnalysis(cursor)
            }
        }

        override suspend fun getTrackAnalyses(trackIds: List<String>): List<TrackAnalysis> = withContext(Dispatchers.IO) {
            if (trackIds.isEmpty()) return@withContext emptyList()
            val list = mutableListOf<TrackAnalysis>()
            val db = readableDatabase
            val placeholders = trackIds.joinToString(",") { "?" }
            db.rawQuery("SELECT * FROM track_analysis WHERE trackId IN ($placeholders)", trackIds.toTypedArray()).use { cursor ->
                while (cursor.moveToNext()) {
                    readTrackAnalysis(cursor)?.let { list.add(it) }
                }
            }
            list
        }

        override suspend fun upsert(analysis: TrackAnalysis) = withContext(Dispatchers.IO) {
            val db = writableDatabase
            val cv = ContentValues().apply {
                put("trackId", analysis.trackId)
                put("fingerprint", analysis.fingerprint)
                put("analysisVersion", analysis.analysisVersion)
                put("durationMs", analysis.durationMs)
                put("startMs", analysis.startMs)
                put("bpm", analysis.bpm)
                put("bpmConfidence", analysis.bpmConfidence)
                put("bpmAmbiguous", if (analysis.bpmAmbiguous) 1 else 0)
                put("beatsMs", converters.fromFloatArray(analysis.beatsMs))
                put("downbeatsMs", converters.fromFloatArray(analysis.downbeatsMs))
                put("camelot", analysis.camelot)
                put("keyConfidence", analysis.keyConfidence)
                put("lufs", analysis.lufs)
                put("energyPerBar", converters.fromFloatArray(analysis.energyPerBar))
                put("introEndMs", analysis.introEndMs)
                put("outroStartMs", analysis.outroStartMs)
                put("vocalRegionsMs", converters.fromLongArray(analysis.vocalRegionsMs))
                put("phraseStartsMs", converters.fromFloatArray(analysis.phraseStartsMs))
            }
            db.insertWithOnConflict("track_analysis", null, cv, SQLiteDatabase.CONFLICT_REPLACE)
            Unit
        }

        override suspend fun getMixPlan(fromId: String, toId: String, preset: String): MixPlanEntity? = withContext(Dispatchers.IO) {
            val db = readableDatabase
            db.rawQuery(
                "SELECT * FROM mix_plan WHERE fromId = ? AND toId = ? AND preset = ? LIMIT 1",
                arrayOf(fromId, toId, preset)
            ).use { cursor ->
                if (!cursor.moveToFirst()) return@withContext null
                MixPlanEntity(
                    fromId = cursor.getString(cursor.getColumnIndexOrThrow("fromId")),
                    toId = cursor.getString(cursor.getColumnIndexOrThrow("toId")),
                    preset = cursor.getString(cursor.getColumnIndexOrThrow("preset")),
                    planVersion = cursor.getInt(cursor.getColumnIndexOrThrow("planVersion")),
                    score = cursor.getFloat(cursor.getColumnIndexOrThrow("score")),
                    style = cursor.getString(cursor.getColumnIndexOrThrow("style")),
                    bars = cursor.getInt(cursor.getColumnIndexOrThrow("bars")),
                    outAlignDownbeat = cursor.getInt(cursor.getColumnIndexOrThrow("outAlignDownbeat")),
                    inAlignDownbeat = cursor.getInt(cursor.getColumnIndexOrThrow("inAlignDownbeat")),
                    rampBars = cursor.getInt(cursor.getColumnIndexOrThrow("rampBars")),
                    targetBpm = cursor.getFloat(cursor.getColumnIndexOrThrow("targetBpm")),
                    cutOutMs = cursor.getLong(cursor.getColumnIndexOrThrow("cutOutMs"))
                )
            }
        }

        override suspend fun upsertMixPlan(plan: MixPlanEntity) = withContext(Dispatchers.IO) {
            val db = writableDatabase
            val cv = ContentValues().apply {
                put("fromId", plan.fromId)
                put("toId", plan.toId)
                put("preset", plan.preset)
                put("planVersion", plan.planVersion)
                put("score", plan.score)
                put("style", plan.style)
                put("bars", plan.bars)
                put("outAlignDownbeat", plan.outAlignDownbeat)
                put("inAlignDownbeat", plan.inAlignDownbeat)
                put("rampBars", plan.rampBars)
                put("targetBpm", plan.targetBpm)
                put("cutOutMs", plan.cutOutMs)
            }
            db.insertWithOnConflict("mix_plan", null, cv, SQLiteDatabase.CONFLICT_REPLACE)
            Unit
        }

        override suspend fun invalidatePlansForTrack(trackId: String) = withContext(Dispatchers.IO) {
            val db = writableDatabase
            db.delete("mix_plan", "fromId = ? OR toId = ?", arrayOf(trackId, trackId))
            Unit
        }

        override suspend fun getAllAnalyses(): List<TrackAnalysis> = withContext(Dispatchers.IO) {
            val list = mutableListOf<TrackAnalysis>()
            val db = readableDatabase
            db.rawQuery("SELECT * FROM track_analysis", null).use { cursor ->
                while (cursor.moveToNext()) {
                    readTrackAnalysis(cursor)?.let { list.add(it) }
                }
            }
            list
        }

        override suspend fun getAllMeta(): List<TrackAnalysisMeta> = withContext(Dispatchers.IO) {
            val list = mutableListOf<TrackAnalysisMeta>()
            val db = readableDatabase
            db.rawQuery("SELECT trackId, fingerprint, analysisVersion FROM track_analysis", null).use { cursor ->
                val idIdx = cursor.getColumnIndexOrThrow("trackId")
                val fpIdx = cursor.getColumnIndexOrThrow("fingerprint")
                val verIdx = cursor.getColumnIndexOrThrow("analysisVersion")
                while (cursor.moveToNext()) {
                    list.add(TrackAnalysisMeta(cursor.getString(idIdx), cursor.getString(fpIdx), cursor.getInt(verIdx)))
                }
            }
            list
        }

        override suspend fun getOutdatedAnalyses(version: Int): List<TrackAnalysis> = withContext(Dispatchers.IO) {
            val list = mutableListOf<TrackAnalysis>()
            val db = readableDatabase
            db.rawQuery("SELECT * FROM track_analysis WHERE analysisVersion < ?", arrayOf(version.toString())).use { cursor ->
                while (cursor.moveToNext()) {
                    readTrackAnalysis(cursor)?.let { list.add(it) }
                }
            }
            list
        }

        override suspend fun deleteTrackAnalysis(trackId: String) = withContext(Dispatchers.IO) {
            val db = writableDatabase
            db.delete("track_analysis", "trackId = ?", arrayOf(trackId))
            Unit
        }
    }

    private fun readTrackAnalysis(cursor: android.database.Cursor): TrackAnalysis? {
        return runCatching {
            TrackAnalysis(
                trackId = cursor.getString(cursor.getColumnIndexOrThrow("trackId")),
                fingerprint = cursor.getString(cursor.getColumnIndexOrThrow("fingerprint")),
                analysisVersion = cursor.getInt(cursor.getColumnIndexOrThrow("analysisVersion")),
                durationMs = cursor.getLong(cursor.getColumnIndexOrThrow("durationMs")),
                startMs = cursor.getLong(cursor.getColumnIndexOrThrow("startMs")),
                bpm = cursor.getFloat(cursor.getColumnIndexOrThrow("bpm")),
                bpmConfidence = cursor.getFloat(cursor.getColumnIndexOrThrow("bpmConfidence")),
                bpmAmbiguous = cursor.getInt(cursor.getColumnIndexOrThrow("bpmAmbiguous")) == 1,
                beatsMs = converters.toFloatArray(cursor.getBlob(cursor.getColumnIndexOrThrow("beatsMs"))) ?: FloatArray(0),
                downbeatsMs = converters.toFloatArray(cursor.getBlob(cursor.getColumnIndexOrThrow("downbeatsMs"))) ?: FloatArray(0),
                camelot = cursor.getString(cursor.getColumnIndexOrThrow("camelot")),
                keyConfidence = cursor.getFloat(cursor.getColumnIndexOrThrow("keyConfidence")),
                lufs = cursor.getFloat(cursor.getColumnIndexOrThrow("lufs")),
                energyPerBar = converters.toFloatArray(cursor.getBlob(cursor.getColumnIndexOrThrow("energyPerBar"))) ?: FloatArray(0),
                introEndMs = cursor.getLong(cursor.getColumnIndexOrThrow("introEndMs")),
                outroStartMs = cursor.getLong(cursor.getColumnIndexOrThrow("outroStartMs")),
                vocalRegionsMs = converters.toLongArray(cursor.getBlob(cursor.getColumnIndexOrThrow("vocalRegionsMs"))) ?: LongArray(0),
                phraseStartsMs = converters.toFloatArray(cursor.getBlob(cursor.getColumnIndexOrThrow("phraseStartsMs"))) ?: FloatArray(0)
            )
        }.getOrNull()
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS track_analysis (
                trackId TEXT PRIMARY KEY,
                fingerprint TEXT,
                analysisVersion INTEGER,
                durationMs INTEGER,
                startMs INTEGER,
                bpm REAL,
                bpmConfidence REAL,
                bpmAmbiguous INTEGER,
                beatsMs BLOB,
                downbeatsMs BLOB,
                camelot TEXT,
                keyConfidence REAL,
                lufs REAL,
                energyPerBar BLOB,
                introEndMs INTEGER,
                outroStartMs INTEGER,
                vocalRegionsMs BLOB,
                phraseStartsMs BLOB
            )
        """.trimIndent())

        db.execSQL("""
            CREATE TABLE IF NOT EXISTS mix_plan (
                fromId TEXT,
                toId TEXT,
                preset TEXT,
                planVersion INTEGER,
                score REAL,
                style TEXT,
                bars INTEGER,
                outAlignDownbeat INTEGER,
                inAlignDownbeat INTEGER,
                rampBars INTEGER,
                targetBpm REAL,
                cutOutMs INTEGER,
                PRIMARY KEY (fromId, toId, preset)
            )
        """.trimIndent())

        db.execSQL("CREATE INDEX IF NOT EXISTS idx_analysis_version ON track_analysis(analysisVersion)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        db.execSQL("DROP TABLE IF EXISTS track_analysis")
        db.execSQL("DROP TABLE IF EXISTS mix_plan")
        onCreate(db)
    }

    fun analysisDao(): AnalysisDao = dao

    companion object {
        private const val DATABASE_NAME = "vibra_music_mix.db"
        private const val DATABASE_VERSION = 1

        @Volatile
        private var instance: VibraDb? = null

        fun get(context: Context): VibraDb {
            return instance ?: synchronized(this) {
                instance ?: VibraDb(context.applicationContext).also { instance = it }
            }
        }
    }
}
