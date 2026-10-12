package io.photolog.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.FileDownload
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import io.photolog.android.data.PhotoEntity
import io.photolog.android.data.PhotoSource
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * One entry in the library.
 *
 * Reading order is the feature: image → caption → metadata. The caption sits immediately under
 * the photo and is editable from the detail screen, which is what makes "照片下面可以打文字
 * 说明" true of the list view and not just of a form.
 *
 * The image is laid out at the photo's own aspect ratio rather than in a fixed-height box.
 * A gallery that crops every thumbnail hides what the photo actually is, and a fixed-height
 * `Fit` box would letterbox every one of them differently — the stored width and height make
 * the exact ratio available for free.
 */
@Composable
fun PhotoCard(
    photo: PhotoEntity,
    file: File,
    position: Int,
    manualOrder: Boolean,
    onOpen: () -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
    onExport: () -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var menuOpen by remember { mutableStateOf(false) }

    Card(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onOpen),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
    ) {
        Column {
            AsyncImage(
                model = file,
                contentDescription = photo.caption.ifBlank { null },
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(aspectRatioOf(photo))
                    .background(MaterialTheme.colorScheme.surface),
            )

            Column(
                modifier = Modifier.padding(start = 14.dp, end = 6.dp, top = 12.dp, bottom = 8.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CountBadge(
                        text = String.format(Locale.US, "%03d", position),
                        container = MaterialTheme.colorScheme.primaryContainer,
                        content = MaterialTheme.colorScheme.onPrimaryContainer,
                    )
                    Spacer(Modifier.width(6.dp))
                    SourceBadge(photo.source)
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = formatDateTime(photo.capturedAt),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    Box {
                        IconButton(onClick = { menuOpen = true }, modifier = Modifier.size(36.dp)) {
                            Icon(Icons.Outlined.MoreVert, contentDescription = "更多操作")
                        }
                        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                            if (manualOrder) {
                                DropdownMenuItem(
                                    text = { Text("上移") },
                                    leadingIcon = { Icon(Icons.Outlined.ArrowUpward, contentDescription = null) },
                                    onClick = {
                                        menuOpen = false
                                        onMoveUp()
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("下移") },
                                    leadingIcon = { Icon(Icons.Outlined.ArrowDownward, contentDescription = null) },
                                    onClick = {
                                        menuOpen = false
                                        onMoveDown()
                                    },
                                )
                            }
                            DropdownMenuItem(
                                text = { Text(if (photo.caption.isBlank()) "写文字说明" else "编辑文字说明") },
                                onClick = {
                                    menuOpen = false
                                    onOpen()
                                },
                            )
                            DropdownMenuItem(
                                text = { Text("无损导出这张") },
                                leadingIcon = { Icon(Icons.Outlined.FileDownload, contentDescription = null) },
                                onClick = {
                                    menuOpen = false
                                    onExport()
                                },
                            )
                            DropdownMenuItem(
                                text = { Text("删除") },
                                leadingIcon = { Icon(Icons.Outlined.Delete, contentDescription = null) },
                                onClick = {
                                    menuOpen = false
                                    onDelete()
                                },
                            )
                        }
                    }
                }

                Text(
                    text = photo.caption.ifBlank { "点这里给这张照片写一行文字说明" },
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (photo.caption.isBlank()) {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    } else {
                        MaterialTheme.colorScheme.onSurface
                    },
                    fontStyle = if (photo.caption.isBlank()) FontStyle.Italic else FontStyle.Normal,
                    maxLines = 4,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(end = 8.dp),
                )

                Text(
                    text = "${photo.width} × ${photo.height} · ${formatBytes(photo.sizeBytes)} · ${photo.mimeType}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(end = 8.dp),
                )
            }
        }
    }
}

/** A small numbered chip, used for the position in the library. */
@Composable
fun CountBadge(text: String, container: Color, content: Color) {
    Surface(color = container, contentColor = content, shape = RoundedCornerShape(6.dp)) {
        Text(
            text = text,
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}

/** Where the photo came from, so the user can tell a shot from a shared image at a glance. */
@Composable
fun SourceBadge(source: String) {
    val container: Color
    val content: Color
    when (source) {
        PhotoSource.CAMERA.name -> {
            container = MaterialTheme.colorScheme.tertiaryContainer
            content = MaterialTheme.colorScheme.onTertiaryContainer
        }

        PhotoSource.SHARE.name -> {
            container = MaterialTheme.colorScheme.secondaryContainer
            content = MaterialTheme.colorScheme.onSecondaryContainer
        }

        else -> {
            container = MaterialTheme.colorScheme.surface
            content = MaterialTheme.colorScheme.onSurfaceVariant
        }
    }
    Surface(color = container, contentColor = content, shape = RoundedCornerShape(6.dp)) {
        Text(
            text = sourceLabel(source),
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}

/**
 * What a screen shows before there is anything in it.
 *
 * The detail line always names a way forward — a library that says "no photos" with no mention
 * of the share sheet is hiding its own most useful entrance.
 */
@Composable
fun EmptyState(
    title: String,
    detail: String,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 40.dp, horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            imageVector = Icons.Outlined.Image,
            contentDescription = null,
            modifier = Modifier.size(40.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(text = title, style = MaterialTheme.typography.titleMedium)
        Text(
            text = detail,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** A full-screen spinner, used while a screen has nothing to show yet. */
@Composable
fun CenteredProgress(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        CircularProgressIndicator()
    }
}

/** A section heading in the settings and export screens. */
@Composable
fun SectionHeader(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.titleMedium,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(top = 6.dp),
    )
}

/** Explanatory text under a control. */
@Composable
fun Hint(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

/** A label plus a switch, the shape every toggle in this app takes. */
@Composable
fun ToggleRow(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    enabled: Boolean = true,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodyLarge,
        )
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            enabled = enabled,
        )
    }
}

/** A key/value line in the detail screen's metadata block. */
@Composable
fun MetaRow(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(76.dp),
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.weight(1f),
        )
    }
}

/** A refresh button that shows its own progress, used by the empty library state. */
@Composable
fun RefreshAction(label: String, busy: Boolean, onClick: () -> Unit) {
    TextButton(onClick = onClick, enabled = !busy) {
        if (busy) {
            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
        } else {
            Icon(Icons.Outlined.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
        }
        Spacer(Modifier.width(6.dp))
        Text(label)
    }
}

// --------------------------------------------------------------------------- //
// Formatting
// --------------------------------------------------------------------------- //

/** The photo's aspect ratio, clamped so a corrupt or unknown size cannot produce a 0-height tile. */
internal fun aspectRatioOf(photo: PhotoEntity): Float {
    if (photo.width <= 0 || photo.height <= 0) return 1f
    return (photo.width.toFloat() / photo.height.toFloat()).coerceIn(0.35f, 3.2f)
}

fun sourceLabel(source: String): String = when (source) {
    PhotoSource.CAMERA.name -> "拍照"
    PhotoSource.GALLERY.name -> "相册"
    PhotoSource.SHARE.name -> "分享"
    else -> source
}

/** `2026-10-12 09:31` — the minute is the useful precision when scanning a library. */
fun formatDateTime(millis: Long): String =
    SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()).format(Date(millis))

/**
 * Byte counts a person can compare.
 *
 * `Locale.US` for the format call specifically: a locale that uses a comma as the decimal
 * separator would render "1,5 MB", which reads as one and a half thousand to an en-US reader.
 */
fun formatBytes(bytes: Long): String = when {
    bytes >= 1024L * 1024 * 1024 -> String.format(Locale.US, "%.2f GB", bytes / 1024.0 / 1024.0 / 1024.0)
    bytes >= 1024L * 1024 -> String.format(Locale.US, "%.1f MB", bytes / 1024.0 / 1024.0)
    bytes >= 1024L -> String.format(Locale.US, "%.0f KB", bytes / 1024.0)
    else -> "$bytes B"
}
