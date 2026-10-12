package io.photolog.android.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import io.photolog.android.data.AppSettings

/**
 * A muted blue palette, used when the device cannot supply its own.
 *
 * Low-saturation on purpose. This is a photo app: every screen is mostly pictures, and a loud
 * accent competes with them. The blue is dark enough to read as a UI colour next to a bright
 * photo, and the surfaces are a neutral near-white rather than a tinted one, so a photo's own
 * white balance is not visibly shifted by the app around it.
 */
private val LightColors = lightColorScheme(
    primary = Color(0xFF1D4E89),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFD3E3FF),
    onPrimaryContainer = Color(0xFF001B3D),
    secondary = Color(0xFF54626F),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFD7E4F2),
    onSecondaryContainer = Color(0xFF111C27),
    tertiary = Color(0xFF6D5677),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFF6D9FF),
    onTertiaryContainer = Color(0xFF271430),
    background = Color(0xFFF8F9FC),
    onBackground = Color(0xFF191C20),
    surface = Color(0xFFF8F9FC),
    onSurface = Color(0xFF191C20),
    surfaceVariant = Color(0xFFE0E2EC),
    onSurfaceVariant = Color(0xFF43474E),
    outline = Color(0xFF73777F),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFFA6C8FF),
    onPrimary = Color(0xFF00325F),
    primaryContainer = Color(0xFF004689),
    onPrimaryContainer = Color(0xFFD3E3FF),
    secondary = Color(0xFFBBC7DB),
    onSecondary = Color(0xFF253140),
    secondaryContainer = Color(0xFF3B4858),
    onSecondaryContainer = Color(0xFFD7E4F2),
    tertiary = Color(0xFFDABDE3),
    onTertiary = Color(0xFF3C2946),
    tertiaryContainer = Color(0xFF543F5E),
    onTertiaryContainer = Color(0xFFF6D9FF),
    background = Color(0xFF111318),
    onBackground = Color(0xFFE2E2E6),
    surface = Color(0xFF111318),
    onSurface = Color(0xFFE2E2E6),
    surfaceVariant = Color(0xFF43474E),
    onSurfaceVariant = Color(0xFFC3C6CF),
    outline = Color(0xFF8D9199),
)

/**
 * Applies the user's theme choice.
 *
 * Material You is used on Android 12+ because a photo app has no brand colour worth overriding
 * the system's, and matching the rest of the device is a better default than imposing a blue.
 * Older devices get the palette above.
 */
@Composable
fun PhotoLogTheme(
    themeMode: String,
    content: @Composable () -> Unit,
) {
    val dark = when (themeMode) {
        AppSettings.THEME_LIGHT -> false
        AppSettings.THEME_DARK -> true
        else -> isSystemInDarkTheme()
    }

    val context = LocalContext.current
    val colorScheme = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)

        dark -> DarkColors
        else -> LightColors
    }

    MaterialTheme(colorScheme = colorScheme, content = content)
}
