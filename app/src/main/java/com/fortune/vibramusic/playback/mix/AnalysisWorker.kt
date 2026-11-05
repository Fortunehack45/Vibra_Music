package com.fortune.vibramusic.playback.mix

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.fortune.vibramusic.data.LocalMediaRepository
import com.fortune.vibramusic.data.db.AnalysisDao
import com.fortune.vibramusic.data.db.VibraDb
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.download.Downloads
import java.io.File

const val ANALYSIS_VERSION = 1

data class AnalysisTaskTarget(
    val id: String,
    val path: String,
    val fingerprint: String
)

class AnalysisWorker(
    ctx: Context,
    params: WorkerParameters
) : CoroutineWorker(ctx, params) {

    override suspend fun doWork(): Result {
        val context = applicationContext
        val dao = VibraDb.get(context).analysisDao()

        val targets = gatherTracksNeedingAnalysis(context, dao, ANALYSIS_VERSION)
        for (t in targets) {
            if (isStopped) break
            val r = NativeAnalyzer.analyze(t.path) ?: continue
            dao.upsert(r.toEntity(trackId = t.id, fingerprint = t.fingerprint, version = ANALYSIS_VERSION))
            setProgress(workDataOf("done" to t.id))
        }

        return Result.success()
    }

    companion object {
        suspend fun gatherTracksNeedingAnalysis(
            context: Context,
            dao: AnalysisDao,
            version: Int
        ): List<AnalysisTaskTarget> {
            val existingMeta = dao.getAllMeta().associateBy { it.trackId }
            val targets = mutableListOf<AnalysisTaskTarget>()

            // Local music files
            val localSongs: List<Song> = try {
                LocalMediaRepository.getLocalMusic(context)
            } catch (_: Exception) {
                emptyList()
            }
            for (song in localSongs) {
                val path = song.localUri ?: song.videoId
                val file = File(path)
                val fp = if (file.exists()) "${file.length()}_${file.lastModified()}" else "local_${song.videoId}"
                val current = existingMeta[song.videoId]
                if (current == null || current.analysisVersion < version || current.fingerprint != fp) {
                    targets.add(AnalysisTaskTarget(song.videoId, path, fp))
                }
            }

            // Downloads
            val downloads: List<Song> = try {
                Downloads.getDownloadedSongs(context)
            } catch (_: Exception) {
                emptyList()
            }
            for (song in downloads) {
                val path = song.localUri ?: song.videoId
                val file = File(path)
                val fp = if (file.exists()) "${file.length()}_${file.lastModified()}" else "dl_${song.videoId}"
                val current = existingMeta[song.videoId]
                if (current == null || current.analysisVersion < version || current.fingerprint != fp) {
                    targets.add(AnalysisTaskTarget(song.videoId, path, fp))
                }
            }

            return targets.distinctBy { it.id }
        }
    }
}
