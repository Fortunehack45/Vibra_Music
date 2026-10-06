package com.fortune.vibramusic.playback

import kotlin.math.sqrt

/**
 * How far both faders are scaled down while two tracks overlap:
 * `1 / sqrt(incomingGain + outgoingGain)` while the two sum past 1, and 1
 * otherwise.
 *
 * Equal-power gains sum to more than 1 (up to 1.41 at the midpoint, and 2
 * where Automix's DJ curves hold both faders up), so two loud masters peaking
 * together pass full scale in the platform mixer and are hard-clipped into a
 * crackle. This holds the pair's summed power at or under one track's, and
 * their summed amplitude to the square root of the fader sum: 1.19 at an
 * equal-power midpoint, for at most 1.5 dB off both songs there. A plain gain
 * rather than a lower limiter ceiling on purpose. Limiting each side to
 * `1 / (in + out)` was tried first, and on modern masters, which peak near
 * 0 dBFS almost continuously, it limited both songs by 3 dB for the whole
 * blend: audible pumping and grit, heard as the two songs clashing.
 *
 * ## Why on the faders
 *
 * A fader acts where the sound is heard, so multiplying this into the
 * two fader gains lands it on exactly the audio it was computed for, however
 * far ahead either player has buffered.
 *
 * Exactly 1 at both ends of a blend (one fader at 0, the other at 1), so
 * taking it on and off is never heard as a step.
 */
internal fun blendHeadroom(incomingGain: Float, outgoingGain: Float): Float {
    val sum = incomingGain + outgoingGain
    return if (sum <= 1f) 1f else 1f / sqrt(sum)
}
