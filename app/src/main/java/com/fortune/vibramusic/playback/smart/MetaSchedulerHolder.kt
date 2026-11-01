package com.fortune.vibramusic.playback.smart

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Global provider for the MetaScheduler and TrackMetaDao instances.
 * Preloads the in-memory cache at application initialization.
 */
object MetaSchedulerHolder {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    @Volatile
    private var instance: MetaScheduler? = null
    @Volatile
    private var dao: TrackMetaDao? = null

    fun getDao(context: Context): TrackMetaDao {
        return dao ?: synchronized(this) {
            dao ?: TrackMetaDao(context.applicationContext).also { dao = it }
        }
    }

    fun init(context: Context) {
        if (instance == null) {
            synchronized(this) {
                if (instance == null) {
                    val appCtx = context.applicationContext
                    val metaDao = getDao(appCtx)
                    scope.launch(Dispatchers.IO) {
                        TrackMetaRepository.loadAll(metaDao)
                    }
                    val scheduler = MetaScheduler(
                        scope = scope,
                        analyzer = TrackAnalyzer.getInstance(appCtx),
                        tags = LocalTagReader(appCtx),
                        shared = SharedMetaClient(),
                        dao = metaDao,
                    )
                    instance = scheduler
                }
            }
        }
    }

    fun get(context: Context): MetaScheduler {
        init(context)
        return instance!!
    }

    fun getOrNull(): MetaScheduler? = instance
}
