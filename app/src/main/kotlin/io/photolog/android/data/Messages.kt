package io.photolog.android.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * One-shot user-facing text, posted from wherever the work finished.
 *
 * An import started by a share is not owned by any screen — the user may be on the export tab
 * by the time it lands — so the message cannot be a ViewModel field. It lives here and the
 * currently visible screen picks it up.
 *
 * Overwriting is intentional: two messages in flight means the older one is already stale, and
 * a queue would show the user a notification about a share they made two screens ago.
 */
class Messages {

    private val _current = MutableStateFlow<String?>(null)

    val current: StateFlow<String?> = _current.asStateFlow()

    fun post(text: String) {
        _current.value = text
    }

    fun consume() {
        _current.value = null
    }
}
