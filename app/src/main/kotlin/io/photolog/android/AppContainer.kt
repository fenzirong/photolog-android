package io.photolog.android

import android.content.Context
import io.photolog.android.data.Messages
import io.photolog.android.data.PhotoDao
import io.photolog.android.data.PhotoLogDatabase
import io.photolog.android.data.PhotoRepository
import io.photolog.android.data.SettingsStore
import io.photolog.android.data.ShareIntake
import io.photolog.android.export.Exporter

/**
 * Manual dependency container.
 *
 * A DI framework would be several hundred lines of configuration to wire eight objects that
 * have exactly one implementation each. `by lazy` gives the same single-instance guarantee
 * with none of the build-time cost.
 */
class AppContainer(context: Context) {

    /**
     * Application context, exposed for the repository's file work. Holding the application
     * context (never an Activity) is what keeps this container safe to keep for the process
     * lifetime.
     */
    val appContext: Context = context.applicationContext

    val database: PhotoLogDatabase by lazy { PhotoLogDatabase.build(appContext) }

    val dao: PhotoDao get() = database.photoDao()

    val settings: SettingsStore by lazy { SettingsStore(appContext) }

    val repository: PhotoRepository by lazy { PhotoRepository(appContext, dao) }

    val exporter: Exporter by lazy { Exporter(appContext, repository) }

    /**
     * Incoming shares, handed over by [MainActivity] and drained by the navigation root.
     *
     * A channel rather than a callback because a share can arrive while no screen is composed
     * yet — the activity is created *by* the share intent, so the producer always runs first.
     */
    val intake: ShareIntake = ShareIntake()

    /** One-shot user-facing text, posted from anywhere and shown by whichever screen is up. */
    val messages: Messages = Messages()
}
