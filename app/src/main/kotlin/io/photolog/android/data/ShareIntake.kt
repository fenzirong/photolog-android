package io.photolog.android.data

import android.net.Uri
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow

/**
 * Images handed over by another app's share sheet.
 *
 * A channel rather than a `StateFlow` because these are events, not state: a share that
 * arrived once must be imported once, and a state-holder would either replay it on every new
 * collector or lose it if the collector was not attached yet. Both failure modes are real here
 * — the activity is created *by* the share intent, so the producer always runs before the
 * consumer exists.
 *
 * `BUFFERED` capacity is 64 batches, far beyond anything the share sheet produces.
 */
class ShareIntake {

    private val channel = Channel<List<Uri>>(Channel.BUFFERED)

    val batches: Flow<List<Uri>> = channel.receiveAsFlow()

    fun submit(uris: List<Uri>) {
        if (uris.isEmpty()) return
        channel.trySend(uris)
    }
}
