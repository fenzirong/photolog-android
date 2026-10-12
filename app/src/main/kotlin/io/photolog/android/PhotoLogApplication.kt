package io.photolog.android

import android.app.Application

/**
 * The process-level owner of [AppContainer].
 *
 * Nothing else is created here. Building the database or the export engine at startup would
 * pay their cost on every cold start, including the ones that end in the user backing out
 * immediately — the container's `by lazy` members are what defer that.
 */
class PhotoLogApplication : Application() {

    val container: AppContainer by lazy { AppContainer(this) }
}
