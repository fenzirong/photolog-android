package io.photolog.android

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.photolog.android.data.AppSettings
import io.photolog.android.ui.PhotoLogRoot
import io.photolog.android.ui.PhotoLogTheme

/**
 * The single activity.
 *
 * It has three jobs: install the splash, hand any incoming share to the container before the
 * first frame, and host the Compose tree. Everything else belongs to a screen.
 */
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        // Must run before super.onCreate, per the splash-screen contract.
        installSplashScreen()
        // Lets Compose draw behind the system bars; Scaffold applies the insets.
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)

        val container = (application as PhotoLogApplication).container

        // Submitted before `setContent` so the import starts on the first frame rather than
        // after the navigation graph has finished composing.
        container.intake.submit(SharedImages.extract(intent))

        setContent {
            // The theme lives here rather than inside PhotoLogRoot because the theme mode is a
            // setting: switching it must recompose the window, not just the screen.
            val settings by container.settings.settings
                .collectAsStateWithLifecycle(initialValue = AppSettings())

            PhotoLogTheme(themeMode = settings.themeMode) {
                PhotoLogRoot(container = container)
            }
        }
    }

    /**
     * A second share while the app is already open.
     *
     * `singleTop` in the manifest routes it here instead of creating a second task, and
     * `setIntent` keeps `getIntent()` consistent with what the activity is actually showing.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        (application as PhotoLogApplication).container.intake.submit(SharedImages.extract(intent))
    }
}

/**
 * Pulls image URIs out of the intent that launched or resumed this activity.
 *
 * Four sources are read, because there is no single one that every sending app uses:
 *
 * - `ACTION_SEND` → `EXTRA_STREAM` — the ordinary "share one image".
 * - `ACTION_SEND_MULTIPLE` → `EXTRA_STREAM` as a list — "share several".
 * - `ACTION_VIEW` → `getData()` — "open with" from a file manager.
 * - `getClipData()` — what a sender that built the intent from a clipboard-style payload
 *   attaches instead. Reading only `EXTRA_STREAM` is the classic reason a share from a
 *   particular gallery app silently imports nothing.
 *
 * The result is de-duplicated because senders routinely put the same URI in both places.
 */
internal object SharedImages {

    fun extract(intent: Intent?): List<Uri> {
        if (intent == null) return emptyList()

        val direct = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(intent.stream())
            Intent.ACTION_SEND_MULTIPLE -> intent.streamList()
            Intent.ACTION_VIEW -> listOfNotNull(intent.data)
            else -> emptyList()
        }

        val fromClip = intent.clipData
            ?.let { clip -> (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri } }
            .orEmpty()

        return (direct + fromClip).distinct()
    }

    /**
     * `getParcelableExtra(String)` is deprecated on API 33+ in favour of a typed overload, but
     * the deprecated form still works on every level and does not need `IntentCompat` — one
     * fewer thing that can be missing from the runtime classpath.
     *
     * The list overload needs its type argument spelled out. Both methods are declared
     * `<T extends Parcelable> T get…`, and the list one's `T` appears only inside the return
     * type — the function's own `List<Uri>` signature constrains nothing, so the compiler has
     * no way to pick `T` and refuses with "Not enough information to infer type argument".
     */
    @Suppress("DEPRECATION")
    private fun Intent.stream(): Uri? = getParcelableExtra(Intent.EXTRA_STREAM)

    @Suppress("DEPRECATION")
    private fun Intent.streamList(): List<Uri> =
        getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
}
