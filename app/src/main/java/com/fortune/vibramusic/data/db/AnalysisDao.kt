package com.fortune.vibramusic.data.db

data class TrackAnalysisMeta(
    val trackId: String,
    val fingerprint: String,
    val analysisVersion: Int
)

interface AnalysisDao {
    suspend fun getTrackAnalysis(trackId: String): TrackAnalysis?
    suspend fun getTrackAnalyses(trackIds: List<String>): List<TrackAnalysis>
    suspend fun upsert(analysis: TrackAnalysis)
    suspend fun getMixPlan(fromId: String, toId: String, preset: String): MixPlanEntity?
    suspend fun upsertMixPlan(plan: MixPlanEntity)
    suspend fun invalidatePlansForTrack(trackId: String)
    suspend fun getAllAnalyses(): List<TrackAnalysis>
    suspend fun getAllMeta(): List<TrackAnalysisMeta>
    suspend fun getOutdatedAnalyses(version: Int): List<TrackAnalysis>
    suspend fun deleteTrackAnalysis(trackId: String)
}
