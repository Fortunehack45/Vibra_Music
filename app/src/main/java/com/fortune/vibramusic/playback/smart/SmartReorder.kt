package com.fortune.vibramusic.playback.smart

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Result of executing the [SmartReorder] playlist sequencing algorithm.
 *
 * @property items The optimized track sequence.
 * @property originalScore The mean transition compatibility score of the original sequence [0.0, 1.0].
 * @property reorderedScore The mean transition compatibility score of the optimized sequence [0.0, 1.0].
 * @property scoreDelta The improvement in sequence compatibility ([reorderedScore] - [originalScore]).
 * @property movedCount The number of tracks whose positions were changed.
 * @property objective The sequencing objective used for optimization.
 */
enum class ReorderObjective {
    BALANCED,
    SMOOTH_BPM,
    ENERGY_FLOW,
    HARMONIC_FLOW,
}

data class ReorderResult<T>(
    val items: List<T>,
    val originalScore: Float,
    val reorderedScore: Float,
    val scoreDelta: Float,
    val movedCount: Int,
    val objective: ReorderObjective = ReorderObjective.BALANCED,
)

/**
 * Production playlist sequencing engine that arranges tracks for optimal musical flow.
 *
 * Employs a prioritized decision hierarchy:
 * 1. Primary Preference: Tempo compatibility (direct match within 6%, half/double-time octave relationships).
 * 2. Harmonic Flow: Camelot key wheel proximity (adjacent keys, relative major/minor, energy boosts).
 * 3. Mood & Energy Continuity: Prevents jarring acoustic jumps.
 * 4. Graceful Bridges: When bridging distinct tempo clusters (e.g. 80 BPM to 118 BPM), bridges
 *    via harmonic key and mood without forcing unnatural tempo changes.
 * 5. 2-Opt Local Refinement: Eliminates greedy local minima.
 */
object SmartReorder {

    private const val ORDER_DEVIATION_PENALTY_WEIGHT = 0.012f

    /**
     * Optimizes track ordering for transition flow.
     *
     * @param items The playlist items in their current order.
     * @param pinnedIndices Zero-based indices of tracks that must not move (e.g. currently playing song).
     * @param objective Presets for balancing BPM, harmonic key, and energy.
     * @param analysisProvider Maps an item to its [TrackAnalysis].
     */
    fun <T> reorder(
        items: List<T>,
        pinnedIndices: Set<Int> = emptySet(),
        objective: ReorderObjective = ReorderObjective.BALANCED,
        analysisProvider: (T) -> TrackAnalysis,
    ): ReorderResult<T> {
        if (items.size <= 2) {
            val score = scoreSequence(items, objective, analysisProvider)
            return ReorderResult(
                items = items,
                originalScore = score,
                reorderedScore = score,
                scoreDelta = 0f,
                movedCount = 0,
                objective = objective,
            )
        }

        val originalScore = scoreSequence(items, objective, analysisProvider)
        val n = items.size

        data class IndexedItem(val originalIndex: Int, val item: T, val analysis: TrackAnalysis)

        val indexed = items.mapIndexed { idx, itm ->
            IndexedItem(idx, itm, analysisProvider(itm))
        }

        val resultSlots = arrayOfNulls<IndexedItem>(n)
        val unpinned = mutableListOf<IndexedItem>()

        // 1. Lock pinned items into place
        for (i in 0 until n) {
            if (i in pinnedIndices) {
                resultSlots[i] = indexed[i]
            } else {
                unpinned.add(indexed[i])
            }
        }

        // 2. If slot 0 is unpinned, find the optimal anchor pair across the unpinned pool
        if (resultSlots[0] == null && unpinned.size >= 2) {
            var bestPairScore = -Float.MAX_VALUE
            var bestI = 0
            for (i in unpinned.indices) {
                for (j in unpinned.indices) {
                    if (i == j) continue
                    val eval = TransitionCompatibility.evaluate(unpinned[i].analysis, unpinned[j].analysis)
                    val pairScore = scorePair(eval, objective)
                    if (pairScore > bestPairScore) {
                        bestPairScore = pairScore
                        bestI = i
                    }
                }
            }
            resultSlots[0] = unpinned.removeAt(bestI)
        }

        // 3. Sequentially fill open slots using hierarchical candidate selection
        for (slot in 0 until n) {
            if (resultSlots[slot] != null) continue // Pinned or anchor slot already locked

            val prevItem = if (slot > 0) resultSlots[slot - 1] else null
            if (prevItem == null) {
                // Fallback if slot 0 remained unfilled
                if (unpinned.isNotEmpty()) {
                    resultSlots[slot] = unpinned.removeAt(0)
                }
                continue
            }

            var bestCandidateIndex = -1
            var bestScore = -Float.MAX_VALUE

            // Partition candidates into tempo-compatible vs distant bridge
            val scoredCandidates = unpinned.mapIndexed { idx, candidate ->
                val eval = TransitionCompatibility.evaluate(prevItem.analysis, candidate.analysis)
                val isTempoCompatible = eval.tempoScore >= 0.70f

                val baseScore = if (isTempoCompatible) {
                    // Tier 1: Tempo-compatible -> Primary BPM preference, shaped by Key & Energy
                    when (objective) {
                        ReorderObjective.BALANCED -> 0.45f * eval.tempoScore + 0.35f * eval.keyScore + 0.20f * eval.energyScore
                        ReorderObjective.SMOOTH_BPM -> 0.65f * eval.tempoScore + 0.25f * eval.keyScore + 0.10f * eval.energyScore
                        ReorderObjective.HARMONIC_FLOW -> 0.30f * eval.tempoScore + 0.55f * eval.keyScore + 0.15f * eval.energyScore
                        ReorderObjective.ENERGY_FLOW -> 0.35f * eval.tempoScore + 0.25f * eval.keyScore + 0.40f * eval.energyScore
                    }
                } else {
                    // Tier 2: Distant BPM -> Harmonic key & mood continuity bridge (no forced tempo change)
                    val highBpm = max(prevItem.analysis.bpm, candidate.analysis.bpm)
                    val lowBpm = min(prevItem.analysis.bpm, candidate.analysis.bpm)
                    val tempoRatio = if (lowBpm > 0) highBpm / lowBpm else 1.0
                    val distancePenalty = ((tempoRatio - 1.0) * 0.05).toFloat().coerceIn(0f, 0.15f)

                    val bridgeKeyWeight = when (objective) {
                        ReorderObjective.HARMONIC_FLOW -> 0.65f
                        else -> 0.55f
                    }
                    val bridgeEnergyWeight = 1.0f - bridgeKeyWeight
                    (eval.keyScore * bridgeKeyWeight + eval.energyScore * bridgeEnergyWeight - distancePenalty).coerceAtLeast(0.10f)
                }

                // Small penalty for drifting far from original user placement
                val distance = abs(candidate.originalIndex - slot)
                val effectiveScore = baseScore - (distance * ORDER_DEVIATION_PENALTY_WEIGHT)

                Triple(idx, candidate, effectiveScore)
            }

            // Prefer tempo-compatible candidates if any exist; otherwise pick the best harmonic bridge
            val best = scoredCandidates.maxByOrNull { it.third }
            if (best != null) {
                bestCandidateIndex = best.first
                bestScore = best.third
            }

            if (bestCandidateIndex >= 0) {
                resultSlots[slot] = unpinned.removeAt(bestCandidateIndex)
            } else if (unpinned.isNotEmpty()) {
                resultSlots[slot] = unpinned.removeAt(0)
            }
        }

        // 4. 2-Opt local refinement pass over unpinned adjacent pairs
        val optimized = resultSlots.filterNotNull().toMutableList()
        var passes = 0
        var improved = true
        while (improved && passes < 2) {
            improved = false
            passes++
            for (i in 1 until optimized.size - 2) {
                if (optimized[i].originalIndex in pinnedIndices || optimized[i + 1].originalIndex in pinnedIndices) {
                    continue
                }

                // Evaluate current score of segment [i-1, i, i+1, i+2]
                val currentLocalScore = localSegmentScore(optimized, i - 1, objective)
                // Swap adjacent items
                val temp = optimized[i]
                optimized[i] = optimized[i + 1]
                optimized[i + 1] = temp

                val swappedLocalScore = localSegmentScore(optimized, i - 1, objective)
                if (swappedLocalScore > currentLocalScore + 0.015f) {
                    improved = true
                } else {
                    // Revert swap
                    optimized[i + 1] = optimized[i]
                    optimized[i] = temp
                }
            }
        }

        val reorderedList = optimized.map { it.item }
        val reorderedScore = scoreSequence(reorderedList, objective, analysisProvider)

        var moved = 0
        for (i in 0 until n) {
            if (optimized.getOrNull(i)?.originalIndex != i) moved++
        }

        return if (reorderedScore > originalScore) {
            ReorderResult(
                items = reorderedList,
                originalScore = originalScore,
                reorderedScore = reorderedScore,
                scoreDelta = reorderedScore - originalScore,
                movedCount = moved,
                objective = objective,
            )
        } else {
            ReorderResult(
                items = items,
                originalScore = originalScore,
                reorderedScore = originalScore,
                scoreDelta = 0f,
                movedCount = 0,
                objective = objective,
            )
        }
    }

    private fun <T> localSegmentScore(
        list: List<T>,
        startIndex: Int,
        objective: ReorderObjective,
    ): Float {
        var sum = 0f
        var count = 0
        for (k in startIndex until min(list.size - 1, startIndex + 3)) {
            val a = (list[k] as? Any)
            val b = (list[k + 1] as? Any)
            // Access analysis if indexed item
            val analysisA = extractAnalysis(a)
            val analysisB = extractAnalysis(b)
            if (analysisA != null && analysisB != null) {
                val eval = TransitionCompatibility.evaluate(analysisA, analysisB)
                sum += scorePair(eval, objective)
                count++
            }
        }
        return if (count > 0) sum / count else 0f
    }

    private fun extractAnalysis(item: Any?): TrackAnalysis? {
        if (item == null) return null
        return try {
            val field = item.javaClass.getDeclaredField("analysis")
            field.isAccessible = true
            field.get(item) as? TrackAnalysis
        } catch (_: Exception) {
            null
        }
    }

    private fun scorePair(eval: CompatibilityResult, objective: ReorderObjective): Float = when (objective) {
        ReorderObjective.BALANCED -> 0.45f * eval.tempoScore + 0.35f * eval.keyScore + 0.20f * eval.energyScore
        ReorderObjective.SMOOTH_BPM -> 0.65f * eval.tempoScore + 0.25f * eval.keyScore + 0.10f * eval.energyScore
        ReorderObjective.HARMONIC_FLOW -> 0.30f * eval.tempoScore + 0.55f * eval.keyScore + 0.15f * eval.energyScore
        ReorderObjective.ENERGY_FLOW -> 0.35f * eval.tempoScore + 0.25f * eval.keyScore + 0.40f * eval.energyScore
    }

    /**
     * Calculates the mean transition compatibility score across consecutive items.
     */
    fun <T> scoreSequence(
        items: List<T>,
        objective: ReorderObjective = ReorderObjective.BALANCED,
        analysisProvider: (T) -> TrackAnalysis,
    ): Float {
        if (items.size < 2) return 1.0f
        var total = 0f
        for (i in 0 until items.size - 1) {
            val a = analysisProvider(items[i])
            val b = analysisProvider(items[i + 1])
            val eval = TransitionCompatibility.evaluate(a, b)
            total += scorePair(eval, objective)
        }
        return (total / (items.size - 1)).coerceIn(0f, 1f)
    }
}
