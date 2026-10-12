package io.photolog.android.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.MutablePreferences
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

/** Everything the user can change, in one immutable snapshot. */
data class AppSettings(
    val themeMode: String = THEME_SYSTEM,

    /**
     * Default for the export screen's 无损开关.
     *
     * Defaults to `true` because it is the safe answer: a lossless export is a byte-for-byte
     * copy, so the worst case is a larger file. A lossy default would silently degrade the
     * user's photos, and the loss is not recoverable afterwards.
     */
    val exportLossless: Boolean = true,
    val exportIncludeCaptions: Boolean = true,
    /** [io.photolog.android.export.CaptionFormat] key. Stored as text so a rename cannot corrupt it. */
    val exportCaptionFormat: String = "markdown",
    /** Prefixes export file names with `001_`, `002_` … so the order survives a plain file listing. */
    val exportNumbered: Boolean = true,
    /**
     * Names each exported image after its caption.
     *
     * On by default: the folder a user gets should be readable on its own, and `001_清晨的雾.jpg`
     * says what `IMG_0001.jpg` cannot. Photos with no caption keep their original name.
     */
    val exportNameFromCaption: Boolean = true,
    /** Only used when [exportLossless] is off. */
    val exportJpegQuality: Int = 95,
    /** Only used when [exportLossless] is off. `0` means "do not downsample". */
    val exportMaxLongEdge: Int = 4096,
) {
    companion object {
        const val THEME_SYSTEM = "system"
        const val THEME_LIGHT = "light"
        const val THEME_DARK = "dark"
    }
}

/**
 * The `preferencesDataStore` delegate must be a top-level property: it is what guarantees a
 * single [DataStore] instance per file, and two instances writing the same file is a
 * documented corruption path.
 */
private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "photolog_settings")

/**
 * Persisted user preferences.
 *
 * Defaults are applied on read rather than written on first launch, so an app that is never
 * configured never has to touch disk — and so that adding a new setting later does not need
 * a migration.
 */
class SettingsStore(private val context: Context) {

    val settings: Flow<AppSettings> = context.dataStore.data.map { it.toAppSettings() }

    /** One-shot read, for work that has no reason to observe changes. */
    suspend fun snapshot(): AppSettings = settings.first()

    suspend fun setThemeMode(mode: String) = edit { it[Keys.THEME_MODE] = mode }

    suspend fun setExportLossless(lossless: Boolean) = edit { it[Keys.EXPORT_LOSSLESS] = lossless }

    suspend fun setExportIncludeCaptions(include: Boolean) = edit { it[Keys.EXPORT_INCLUDE_CAPTIONS] = include }

    suspend fun setExportCaptionFormat(format: String) = edit { it[Keys.EXPORT_CAPTION_FORMAT] = format }

    suspend fun setExportNumbered(numbered: Boolean) = edit { it[Keys.EXPORT_NUMBERED] = numbered }

    suspend fun setExportNameFromCaption(fromCaption: Boolean) =
        edit { it[Keys.EXPORT_NAME_FROM_CAPTION] = fromCaption }

    suspend fun setExportJpegQuality(quality: Int) = edit { it[Keys.EXPORT_JPEG_QUALITY] = quality.coerceIn(50, 100) }

    /**
     * `0` means "keep the original pixel dimensions" and is stored as-is; anything else is
     * clamped to a range that still leaves a usable image.
     */
    suspend fun setExportMaxLongEdge(edge: Int) =
        edit { it[Keys.EXPORT_MAX_LONG_EDGE] = if (edge <= 0) 0 else edge.coerceIn(480, 16384) }

    private suspend fun edit(block: (MutablePreferences) -> Unit) {
        context.dataStore.edit(block)
    }

    private object Keys {
        val THEME_MODE = stringPreferencesKey("theme_mode")
        val EXPORT_LOSSLESS = booleanPreferencesKey("export_lossless")
        val EXPORT_INCLUDE_CAPTIONS = booleanPreferencesKey("export_include_captions")
        val EXPORT_CAPTION_FORMAT = stringPreferencesKey("export_caption_format")
        val EXPORT_NUMBERED = booleanPreferencesKey("export_numbered")
        val EXPORT_NAME_FROM_CAPTION = booleanPreferencesKey("export_name_from_caption")
        val EXPORT_JPEG_QUALITY = intPreferencesKey("export_jpeg_quality")
        val EXPORT_MAX_LONG_EDGE = intPreferencesKey("export_max_long_edge")
    }

    private fun Preferences.toAppSettings(): AppSettings {
        val defaults = AppSettings()
        return AppSettings(
            themeMode = this[Keys.THEME_MODE] ?: defaults.themeMode,
            exportLossless = this[Keys.EXPORT_LOSSLESS] ?: defaults.exportLossless,
            exportIncludeCaptions = this[Keys.EXPORT_INCLUDE_CAPTIONS] ?: defaults.exportIncludeCaptions,
            exportCaptionFormat = this[Keys.EXPORT_CAPTION_FORMAT] ?: defaults.exportCaptionFormat,
            exportNumbered = this[Keys.EXPORT_NUMBERED] ?: defaults.exportNumbered,
            exportNameFromCaption = this[Keys.EXPORT_NAME_FROM_CAPTION] ?: defaults.exportNameFromCaption,
            exportJpegQuality = this[Keys.EXPORT_JPEG_QUALITY] ?: defaults.exportJpegQuality,
            exportMaxLongEdge = this[Keys.EXPORT_MAX_LONG_EDGE] ?: defaults.exportMaxLongEdge,
        )
    }
}
