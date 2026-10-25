package com.fortune.vibramusic.playback.smart

import kotlin.math.abs

/**
 * Result of executing the [SmartReorder] playlist sequencing algorithm.
 *
 * @property items The optimized track sequence.
 * @property originalScore The mean transition compatibility score of the original sequence [0.0, 1.0].
 * @property reorderedScore The mean transition compatibility score of the optimized sequence [0.0, 1.0].
 * @property scoreDelta The improvement in sequence compatibility ([reorderedScore] - [originalScore]).
 * @property movedCount The number of tracks whose positions were changed.
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
 * Playlist sequencing engine that optimizes transition compatibility across consecutive tracks
 * using BPM, Camelot harmonic key, and energy continuity.
 *
 * Guarantees:
 * 1. Pinned tracks remain strictly locked at their original positions.
 * 2. Zero track loss, zero duplication.
 * 3. Pure non-destructive calculation: never applies mutations without explicit confirmation.
 * 4. Penalizes excessive deviation from original track order when compatibility gains are minimal.
 */
object SmartReorder {

    private const val ORDER_DEVIATION_PENALTY_WEIGHT = 0.015f

    /**
     * Optimizes track ordering for transition flow.
     *
     * @param items The playlist items in their current order.
     * @param pinnedIndices Zero-based indices of tracks that must not move.
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

        // Build array of indexed items to track original positions
        data class IndexedItem(val originalIndex: Int, val item: T, val analysis: TrackAnalysis)

        val indexed = items.mapIndexed { idx, itm ->
            IndexedItem(idx, itm, analysisProvider(itm))
        }

        val resultSlots = arrayOfNulls<IndexedItem>(n)

        // 1. Lock pinned items into place
        val unpinned = mutableListOf<IndexedItem>()
        for (i in 0 until n) {
            if (i in pinnedIndices) {
                resultSlots[i] = indexed[i]
            } else {
                unpinned.add(indexed[i])
            }
        }

        // 2. Sequentially fill open slots with highest-scoring adjacent match
        for (slot in 0 until n) {
            if (resultSlots[slot] != null) continue // Pinned slot already locked

            // Find preceding track for transition evaluation
            val prevItem = if (slot > 0) resultSlots[slot - 1] else null

            var bestCandidateIndex = -1
            var bestScore = -Float.MAX_VALUE

            for (c in unpinned.indices) {
                val candidate = unpinned[c]
                val pairScore = if (prevItem != null) {
                    val eval = TransitionCompatibility.evaluate(prevItem.analysis, candidate.analysis)
                    when (objective) {
                        ReorderObjective.BALANCED -> eval.totalScore
                        ReorderObjective.SMOOTH_BPM -> eval.tempoScore * 0.65f + eval.totalScore * 0.35f
                        ReorderObjective.HARMONIC_FLOW -> eval.keyScore * 0.65f + eval.totalScore * 0.35f
                        ReorderObjective.ENERGY_FLOW -> eval.energyScore * 0.60f + eval.totalScore * 0.40f
                    }
                } else {
                    1.0f
                }

                // Small penalty for drifting far from original position
                val distance = abs(candidate.originalIndex - slot)
                val effectiveScore = pairScore - (distance * ORDER_DEVIATION_PENALTY_WEIGHT)

                if (effectiveScore > bestScore) {
                    bestScore = effectiveScore
                    bestCandidateIndex = c
                }
            }

            if (bestCandidateIndex >= 0) {
                resultSlots[slot] = unpinned.removeAt(bestCandidateIndex)
            } else if (unpinned.isNotEmpty()) {
                resultSlots[slot] = unpinned.removeAt(0)
            }
        }

        val reorderedList = resultSlots.map { requireNotNull(it).item }
        val reorderedScore = scoreSequence(reorderedList, objective, analysisProvider)

        var moved = 0
        for (i in 0 until n) {
            if (resultSlots[i]?.originalIndex != i) moved++
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
            val score = when (objective) {
                ReorderObjective.BALANCED -> eval.totalScore
                ReorderObjective.SMOOTH_BPM -> eval.tempoScore * 0.65f + eval.totalScore * 0.35f
                ReorderObjective.HARMONIC_FLOW -> eval.keyScore * 0.65f + eval.totalScore * 0.35f
                ReorderObjective.ENERGY_FLOW -> eval.energyScore * 0.60f + eval.totalScore * 0.40f
            }
            total += score
        }
        return (total / (items.size - 1)).coerceIn(0f, 1f)
    }
}
