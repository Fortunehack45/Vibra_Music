package com.fortune.vibramusic.data

import com.fortune.vibramusic.data.DebugLog as Log
import com.fortune.vibramusic.data.model.ArtistPage
import com.fortune.vibramusic.data.model.ArtistRef
import com.fortune.vibramusic.data.model.HomeShelf
import com.fortune.vibramusic.data.model.ShelfItem
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.model.TopPick
import com.fortune.vibramusic.data.model.TopPickKind
import com.fortune.vibramusic.data.model.TopPickMood
import com.fortune.vibramusic.data.model.WatchTarget
import com.fortune.vibramusic.data.model.normalizedArtistName
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.time.LocalDateTime
import java.util.Locale
import kotlin.random.Random

/**
 * Builds Home's "Top Picks for You" row out of what the account already tells
 * YouTube Music, and starts the queue behind a card when it is tapped.
 */
object TopPicks {

    private const val TAG = "Vibra Music"

    /** How many artists get a page fetched — and so a card. */
    private const val ARTISTS = 3

    /**
     * How far down the listener's chart those artists are drawn from. Every
     * build draws afresh, weighted toward the top, so the row changes each
     * time it is built without leaving the listener's own taste.
     */
    private const val ARTIST_POOL = 10

    /** Below this, a filtered station would be over before it got going; keep it unfiltered. */
    private const val MIN_FILTERED_QUEUE = 12

    /**
     * What this app knows about the listener's taste without asking YouTube:
     * its own Replay chart. Second to the account's history when signed in,
     * and all there is when signed out.
     */
    data class LocalTaste(
        val artists: List<ArtistRef> = emptyList(),
        val songs: List<Song> = emptyList(),
        val genres: List<String> = emptyList(),
    )

    suspend fun build(
        homeShelves: List<HomeShelf>,
        local: LocalTaste,
        now: LocalDateTime = LocalDateTime.now(),
    ): List<TopPick> = coroutineScope {
        val historyAsync = async { YtMusicRepository.recentHistory().getOrNull().orEmpty() }
        val mixesAsync = async { findMixes(homeShelves) }

        val history = historyAsync.await()
        val ranked = weightedSample(rankArtists(history, local.artists).take(ARTIST_POOL), ARTISTS)
        val pages = ranked.map { artist ->
            async { YtMusicRepository.artistLanding(artist.browseId!!).getOrNull() }
        }.awaitAll()
        val artists = ranked.zip(pages).mapNotNull { (ref, page) ->
            page?.let { ArtistCard(it.copy(name = it.name ?: ref.name), ref.browseId!!) }
        }
            // One person can be two channels (an artist's own and a "Topic"
            // one, or a spelling of their name); two of them would be the
            // same face on two cards.
            .distinctBy { normalizedArtistName(it.name) }
        // Every artist face on the row is Apple Music's photo of them, not
        // YouTube's channel art: the artists themselves, and the people their
        // fans also play. Looked up together, a few at a time.
        val photos = applePhotos(artists)
        val mixes = mixesAsync.await()
        Log.d(TAG, "topPicks: history=${history.size} artists=${artists.map { it.name }} mixes=${mixes.keys}")

        // The first card is always the new release when there is one, as on
        // Apple Music; the rest come in a different order every build.
        val lead = latestRelease(artists)
        val rest = buildList {
            personalStation(mixes, history, local)?.let(::add)
            add(moodPick(now, local))
            artists.getOrNull(0)?.let { andSimilar(it, photos) }?.let(::add)
            artists.getOrNull(1)?.let { featured(it, photos) }?.let(::add)
            mixes[Mix.NEW_RELEASE]?.let { mix ->
                add(
                    TopPick(
                        kind = TopPickKind.NEW_RELEASE_MIX,
                        title = mix.title,
                        subtitle = mix.subtitle,
                        images = listOfNotNull(mix.thumbnailUrl),
                        watch = mix.watchTarget(),
                    ),
                )
            }
            artists.getOrNull(2)?.let { andSimilar(it, photos) }?.let(::add)
            discoveryStation(mixes, artists, history)?.let(::add)
        }.shuffled()
        listOfNotNull(lead) + rest
    }

    /**
     * [count] of [ranked] at random, the higher an artist sits the likelier —
     * the top of the chart turns up most builds, the rest often enough to
     * keep the row moving.
     */
    private fun <T> weightedSample(ranked: List<T>, count: Int): List<T> {
        val pool = ranked.withIndex().toMutableList()
        val picked = mutableListOf<T>()
        while (picked.size < count && pool.isNotEmpty()) {
            val weights = pool.map { (ranked.size - it.index).toDouble() }
            var roll = Random.nextDouble() * weights.sum()
            val index = weights.indexOfFirst { roll -= it; roll <= 0 }.coerceAtLeast(0)
            picked += pool.removeAt(index).value
        }
        return picked
    }

    /** The queue a card starts. Never called for [TopPickKind.LATEST_RELEASE], which opens a page. */
    suspend fun queue(pick: TopPick): Result<List<Song>> {
        if (pick.kind == TopPickKind.MOOD) return moodQueue(pick)
        val target = pick.watch ?: return Result.failure(IllegalStateException("no queue behind ${pick.kind}"))
        if (pick.kind == TopPickKind.PERSONAL_STATION || pick.kind == TopPickKind.DISCOVERY_STATION) {
            return freshStation(pick, target)
        }
        return YtMusicRepository.watchQueue(target)
    }

    /**
     * A Made for You station that sounds different on every tap.
     */
    private suspend fun freshStation(pick: TopPick, target: WatchTarget): Result<List<Song>> = coroutineScope {
        val mixAsync = async { YtMusicRepository.watchQueue(target) }
        val history = YtMusicRepository.recentHistory().getOrNull().orEmpty()
        val seeds = history.take(SEED_POOL).shuffled().take(SEED_RADIOS)
        val radios = seeds.map { seed ->
            async {
                YtMusicRepository.watchQueue(WatchTarget(playlistId = "RDAMVM${seed.videoId}", videoId = seed.videoId))
                    .getOrNull().orEmpty()
            }
        }
        val mix = mixAsync.await().getOrElse { failure ->
            if (seeds.isEmpty()) return@coroutineScope Result.failure(failure)
            emptyList()
        }
        val around = radios.awaitAll().flatten()

        val discovery = pick.kind == TopPickKind.DISCOVERY_STATION
        val heard = if (discovery) history.mapTo(HashSet()) { it.videoId } + pick.exclude else emptySet()
        val seedArtist = pick.artistName?.takeIf { discovery }?.lowercase(Locale.ROOT)
        fun keep(song: Song): Boolean =
            song.videoId !in heard &&
                (seedArtist == null || !song.artist.lowercase(Locale.ROOT).contains(seedArtist))
        val core = mix.filter(::keep).shuffled().take(STATION_FROM_MIX)
        val coreIds = core.mapTo(HashSet()) { it.videoId }
        val extra = around.filter { keep(it) && it.videoId !in coreIds }
            .distinctBy { it.videoId }
            .shuffled()
            .take(STATION_SIZE - core.size)
        val station = (core + extra).shuffled()
        Log.d(TAG, "station ${pick.kind}: mix=${mix.size} core=${core.size} radios=${seeds.size} extra=${extra.size}")
        when {
            station.size >= MIN_FILTERED_QUEUE -> Result.success(station)
            mix.isNotEmpty() -> Result.success(mix.shuffled())
            else -> Result.failure(IllegalStateException("${pick.kind} came back empty"))
        }
    }

    /** History tracks a station's extra radios are seeded from: the recent end of it. */
    private const val SEED_POOL = 40
    private const val SEED_RADIOS = 3
    private const val STATION_FROM_MIX = 30
    private const val STATION_SIZE = 60

    // ---- Cards --------------------------------------------------------------

    private class ArtistCard(val page: ArtistPage, val browseId: String) {
        val name: String get() = page.name.orEmpty()

        val relatedNames: List<String> get() = related.keys.toList()

        val related: Map<String, String> by lazy {
            val own = normalizedArtistName(name)
            page.sections
                .firstOrNull { shelf -> shelf.items.isNotEmpty() && shelf.items.all { it.browseId?.startsWith("UC") == true } }
                ?.items.orEmpty()
                .filter { it.browseId != browseId }
                .filter { normalizedArtistName(it.title).let { key -> key.isNotEmpty() && key != own } }
                .distinctBy { normalizedArtistName(it.title) }
                .take(RELATED_CANDIDATES)
                .associate { it.title to it.browseId!! }
        }
    }

    private const val RELATED_CANDIDATES = 4
    private const val PHOTO_LOOKUPS_AT_ONCE = 4

    private suspend fun applePhotos(artists: List<ArtistCard>): Map<String, String> = coroutineScope {
        val catalogues = LinkedHashMap<String, suspend () -> Collection<String>>()
        artists.forEach { artist -> catalogues.putIfAbsent(artist.name) { AppleCatalogue.titlesOf(artist.page) } }
        artists.forEach { artist ->
            artist.related.forEach { (name, channel) ->
                catalogues.putIfAbsent(name) {
                    YtMusicRepository.artistLanding(channel).getOrNull()?.let(AppleCatalogue::titlesOf).orEmpty()
                }
            }
        }
        val limiter = Semaphore(PHOTO_LOOKUPS_AT_ONCE)
        catalogues.map { (name, catalogue) ->
            async { limiter.withPermit { AppleArtistPhotos.photoFor(name, catalogue)?.let { name to it } } }
        }.awaitAll().filterNotNull().toMap()
    }

    private fun latestRelease(artists: List<ArtistCard>): TopPick? {
        data class Candidate(val rank: Int, val artist: ArtistCard, val item: ShelfItem, val year: Int, val single: Boolean)
        val candidates = artists.flatMapIndexed { rank, artist ->
            artist.page.sections
                .mapNotNull { shelf -> shelf.items.firstOrNull()?.takeIf { it.browseId?.startsWith("MPRE") == true } }
                .map { item ->
                    Candidate(rank, artist, item, yearOf(item.subtitle), SINGLE.containsMatchIn(item.subtitle))
                }
        }
        val best = candidates.maxWithOrNull(
            compareBy<Candidate> { it.year }.thenBy { it.single }.thenByDescending { it.rank },
        ) ?: return null
        return TopPick(
            kind = TopPickKind.LATEST_RELEASE,
            title = best.item.title,
            subtitle = best.item.subtitle,
            artistName = best.artist.name,
            images = listOfNotNull(best.item.thumbnailUrl),
            browseId = best.item.browseId,
        )
    }

    private fun personalStation(mixes: Map<Mix, ShelfItem>, history: List<Song>, local: LocalTaste): TopPick? {
        val watch = mixes[Mix.SUPERMIX]?.watchTarget()
            ?: (local.songs.firstOrNull() ?: history.firstOrNull())?.let { song ->
                WatchTarget(playlistId = "RDAMVM${song.videoId}", videoId = song.videoId)
            }
            ?: return null
        return TopPick(kind = TopPickKind.PERSONAL_STATION, watch = watch)
    }

    private fun moodPick(now: LocalDateTime, local: LocalTaste): TopPick =
        TopPick(
            kind = TopPickKind.MOOD,
            mood = moodFor(now),
            hints = (local.genres.map { it.lowercase(Locale.ROOT) } + regionHints()).distinct(),
        )

    private fun andSimilar(artist: ArtistCard, photos: Map<String, String>): TopPick? {
        val radio = artist.page.radio ?: return null
        val face = photos[artist.name] ?: return null
        val related = artist.relatedNames
            .mapNotNull { photos[it] }
            .filter { it != face }
            .distinct()
            .take(2)
        return TopPick(
            kind = TopPickKind.ARTIST_AND_SIMILAR,
            title = artist.name,
            artistName = artist.name,
            artistBrowseId = artist.browseId,
            images = listOf(face) + related,
            watch = radio,
        )
    }

    private fun featured(artist: ArtistCard, photos: Map<String, String>): TopPick? {
        val shuffle = artist.page.shuffle ?: artist.page.radio ?: return null
        val face = photos[artist.name] ?: return null
        return TopPick(
            kind = TopPickKind.FEATURED_ARTIST,
            title = artist.name,
            subtitle = artist.page.monthlyListenerCount ?: artist.page.subscriberCountText.orEmpty(),
            artistName = artist.name,
            artistBrowseId = artist.browseId,
            images = listOf(face),
            watch = shuffle,
        )
    }

    private fun discoveryStation(
        mixes: Map<Mix, ShelfItem>,
        artists: List<ArtistCard>,
        history: List<Song>,
    ): TopPick? {
        mixes[Mix.DISCOVER]?.watchTarget()?.let { watch ->
            return TopPick(kind = TopPickKind.DISCOVERY_STATION, watch = watch)
        }
        val seed = artists.firstOrNull() ?: return null
        val radio = seed.page.radio ?: return null
        return TopPick(
            kind = TopPickKind.DISCOVERY_STATION,
            artistName = seed.name,
            watch = radio,
            exclude = history.take(200).map { it.videoId },
        )
    }

    // ---- Artists ------------------------------------------------------------

    private fun rankArtists(history: List<Song>, local: List<ArtistRef>): List<ArtistRef> {
        val scores = LinkedHashMap<String, Pair<String, Double>>()
        fun credit(id: String?, name: String, weight: Double) {
            if (id == null || !id.startsWith("UC") || name.isBlank()) return
            if (name.equals("Various Artists", ignoreCase = true)) return
            val (_, score) = scores[id] ?: (name to 0.0)
            scores[id] = name to score + weight
        }
        history.forEachIndexed { index, song ->
            val recency = 1.0 - index.toDouble() / history.size.coerceAtLeast(1)
            val lead = song.artists.firstOrNull { it.browseId != null }
            if (lead != null) credit(lead.browseId, lead.name, 1.0 + recency * 0.5)
            else credit(song.artistId, song.artist, 1.0 + recency * 0.5)
        }
        local.forEachIndexed { index, artist ->
            credit(artist.browseId, artist.name, (local.size - index).toDouble() * 0.5)
        }
        return scores.entries
            .sortedByDescending { it.value.second }
            .map { ArtistRef(name = it.value.first, browseId = it.key) }
    }

    // ---- Mixes --------------------------------------------------------------

    private enum class Mix { SUPERMIX, DISCOVER, NEW_RELEASE }

    private suspend fun findMixes(homeShelves: List<HomeShelf>): Map<Mix, ShelfItem> {
        val onHome = homeShelves.flatMap { it.items }.filter { it.isMix() }
        val mixes = onHome.takeIf { it.isNotEmpty() }
            ?: YtMusicRepository.mixedForYou().getOrNull().orEmpty().filter { it.isMix() }
        if (mixes.isEmpty()) return emptyMap()
        val found = mutableMapOf<Mix, ShelfItem>()
        mixes.forEach { item ->
            val title = item.title.lowercase(Locale.ROOT)
            val kind = when {
                "supermix" in title -> Mix.SUPERMIX
                "discover" in title -> Mix.DISCOVER
                "new release" in title -> Mix.NEW_RELEASE
                else -> null
            }
            if (kind != null) found.putIfAbsent(kind, item)
        }
        if (found.isEmpty()) found[Mix.SUPERMIX] = mixes.first()
        return found
    }

    private fun ShelfItem.isMix(): Boolean =
        browseId?.removePrefix("VL")?.startsWith("RDTMAK") == true

    private fun ShelfItem.watchTarget(): WatchTarget? =
        browseId?.removePrefix("VL")?.let { WatchTarget(playlistId = it) }

    // ---- Moods --------------------------------------------------------------

    fun moodFor(now: LocalDateTime): TopPickMood {
        val suited = when (now.hour) {
            in 5..8 -> listOf(TopPickMood.ENERGY, TopPickMood.FEEL_GOOD, TopPickMood.FOCUS)
            in 9..11 -> listOf(TopPickMood.FOCUS, TopPickMood.FEEL_GOOD, TopPickMood.ENERGY)
            in 12..16 -> listOf(TopPickMood.FEEL_GOOD, TopPickMood.FOCUS, TopPickMood.ENERGY, TopPickMood.RELAX)
            in 17..19 -> listOf(TopPickMood.ENERGY, TopPickMood.FEEL_GOOD, TopPickMood.RELAX)
            in 20..22 -> listOf(TopPickMood.LOVE, TopPickMood.RELAX, TopPickMood.HEARTBREAK, TopPickMood.FEEL_GOOD)
            else -> listOf(TopPickMood.RELAX, TopPickMood.FEELING_BLUE, TopPickMood.HEARTBREAK, TopPickMood.LOVE)
        }
        return if (Random.nextFloat() < 0.7f) suited.random()
        else TopPickMood.entries.filter { it.isCoreMood }.random()
    }

    private suspend fun moodQueue(pick: TopPick): Result<List<Song>> = coroutineScope {
        val mood = pick.mood ?: return@coroutineScope Result.failure(IllegalStateException("mood card without a mood"))
        val shelves = YtMusicRepository.moodGenreShelves(TopPickMood.CATEGORY_BROWSE_ID, mood.params)
            .getOrElse { return@coroutineScope Result.failure(it) }
        val playlists = { shelf: HomeShelf -> shelf.items.filter { it.browseId?.startsWith("VL") == true } }
        val candidates = shelves.filter { playlists(it).isNotEmpty() }
        val score = { shelf: HomeShelf ->
            val title = shelf.title.lowercase(Locale.ROOT)
            2 * mood.shelfWords.count { it in title } + pick.hints.count { it.isNotBlank() && it in title }
        }
        val best = candidates.maxOfOrNull(score)
            ?: return@coroutineScope Result.failure(IllegalStateException("no playlists for $mood"))
        val shelf = candidates.filter { score(it) == best }.random()
        val chosen = playlists(shelf).take(6).shuffled().take(MOOD_PLAYLISTS)
        val songs = chosen.map { item ->
            async {
                val playlistId = item.browseId!!.removePrefix("VL")
                YtMusicRepository.playlistAsAudio(playlistId).getOrNull()?.takeIf { it.isNotEmpty() }
                    ?: YtMusicRepository.browseSongs(item.browseId!!).getOrNull()?.songs.orEmpty()
            }
        }.awaitAll().flatten()
            .distinctBy { it.videoId }
            .shuffled()
            .take(MOOD_QUEUE)
        if (songs.isEmpty()) Result.failure(IllegalStateException("$mood playlists were empty"))
        else Result.success(songs)
    }

    private const val MOOD_PLAYLISTS = 3
    private const val MOOD_QUEUE = 60

    fun moodStation(mood: TopPickMood, hints: List<String> = regionHints()): TopPick =
        TopPick(kind = TopPickKind.MOOD, mood = mood, hints = hints)

    fun regionHints(): List<String> = when (Locale.getDefault().country) {
        "IN" -> listOf("bollywood", "indian", "hindi", "punjabi", "desi")
        "PK" -> listOf("pakistani", "urdu", "punjabi")
        "KR" -> listOf("k-pop", "korean")
        "JP" -> listOf("j-pop", "japanese")
        "BR" -> listOf("brazil", "sertanejo", "funk")
        "MX", "ES", "AR", "CO", "CL", "PE" -> listOf("latin", "latino", "reggaeton")
        else -> emptyList()
    }

    private val YEAR = Regex("""\b(19|20)\d{2}\b""")
    private val SINGLE = Regex("""\b(Single|EP)\b""")

    private fun yearOf(subtitle: String): Int =
        YEAR.findAll(subtitle).lastOrNull()?.value?.toIntOrNull() ?: 0

    // ---- Storage ------------------------------------------------------------

    /** A day's row as stored on disk, so Home can paint it before any request. */
    @Serializable
    data class Stored(
        val listener: String?,
        val day: String,
        val picks: List<TopPick>,
        val photos: Map<String, String> = emptyMap(),
    )

    private val json = Json { ignoreUnknownKeys = true }

    fun encode(stored: Stored): String = json.encodeToString(Stored.serializer(), stored)

    fun decode(text: String): Stored? = runCatching { json.decodeFromString(Stored.serializer(), text) }.getOrNull()
}
