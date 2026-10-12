package io.photolog.android.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AddPhotoAlternate
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material.icons.outlined.Sort
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import io.photolog.android.data.PhotoEntity
import io.photolog.android.vm.GalleryViewModel
import io.photolog.android.vm.SortMode
import kotlinx.coroutines.launch

/**
 * The library.
 *
 * The list is drawn straight from Room, so it is populated the instant the screen appears and
 * updates itself after every import, caption edit, reorder and delete — there is no "reload"
 * step anywhere in this app, and no state that can drift from what is on disk.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GalleryScreen(
    viewModel: GalleryViewModel,
    navController: NavHostController,
    onOpenCamera: () -> Unit,
) {
    val photos by viewModel.photos.collectAsStateWithLifecycle()
    val sortMode by viewModel.sortMode.collectAsStateWithLifecycle()
    val count by viewModel.count.collectAsStateWithLifecycle()
    val totalBytes by viewModel.totalBytes.collectAsStateWithLifecycle()
    val message by viewModel.message.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }
    val coroutineScope = rememberCoroutineScope()

    var sortMenuOpen by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf<PhotoEntity?>(null) }
    var pendingExport by remember { mutableStateOf<PhotoEntity?>(null) }
    var exporting by remember { mutableStateOf(false) }

    /*
     * The single-photo export goes through the Storage Access Framework, which means the write
     * happens in the callback, after the user has chosen a destination. The photo being written
     * is held in `pendingExport` because the launcher itself only carries a file name.
     */
    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("image/*"),
    ) { target ->
        val photo = pendingExport
        pendingExport = null
        if (target == null || photo == null) return@rememberLauncherForActivityResult
        coroutineScope.launch {
            exporting = true
            val result = viewModel.exportSingle(photo, target)
            exporting = false
            snackbarHostState.showSnackbar(result.describe())
        }
    }

    // `PickMultipleVisualMedia` uses the system photo picker, so no storage permission is
    // involved and the user chooses exactly which images this app may read.
    val pickLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(50),
    ) { uris ->
        if (uris.isNotEmpty()) viewModel.importFromPicker(uris)
    }

    LaunchedEffect(message) {
        message?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.consumeMessage()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("图库") },
                actions = {
                    IconButton(
                        onClick = {
                            pickLauncher.launch(
                                PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                            )
                        },
                    ) {
                        Icon(Icons.Outlined.AddPhotoAlternate, contentDescription = "从相册导入")
                    }
                    Box {
                        IconButton(onClick = { sortMenuOpen = true }) {
                            Icon(Icons.Outlined.Sort, contentDescription = "排序方式")
                        }
                        DropdownMenu(expanded = sortMenuOpen, onDismissRequest = { sortMenuOpen = false }) {
                            SortMode.entries.forEach { mode ->
                                DropdownMenuItem(
                                    text = { Text(mode.label) },
                                    onClick = {
                                        sortMenuOpen = false
                                        viewModel.setSortMode(mode)
                                    },
                                )
                            }
                        }
                    }
                },
            )
        },
        bottomBar = { PhotoLogBottomBar(navController) },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = onOpenCamera,
                icon = { Icon(Icons.Outlined.PhotoCamera, contentDescription = null) },
                text = { Text("拍照") },
            )
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize(),
            // Bottom padding clears the extended FAB so the last card is never half-covered.
            contentPadding = PaddingValues(start = 12.dp, end = 12.dp, top = 12.dp, bottom = 104.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (exporting) {
                item {
                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                }
            }

            item {
                Row {
                    Text(
                        text = "共 $count 张",
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(
                        text = "占用 ${formatBytes(totalBytes)}",
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(
                        text = "顺序：${sortMode.label}",
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            if (photos.isEmpty()) {
                item {
                    EmptyState(
                        title = "图库还是空的",
                        detail = "点右下角「拍照」，或用右上角从相册导入；" +
                            "也可以在其他应用里选中图片，用「分享」发送到「图志」。",
                    )
                }
            } else {
                itemsIndexed(photos, key = { _, photo -> photo.id }) { index, photo ->
                    PhotoCard(
                        photo = photo,
                        file = viewModel.fileFor(photo),
                        position = index + 1,
                        manualOrder = sortMode == SortMode.MANUAL,
                        onOpen = { navController.navigate(Routes.detail(photo.id)) },
                        onMoveUp = { viewModel.move(photo.id, -1) },
                        onMoveDown = { viewModel.move(photo.id, 1) },
                        onExport = {
                            pendingExport = photo
                            exportLauncher.launch(viewModel.suggestedExportName(photo))
                        },
                        onDelete = { pendingDelete = photo },
                    )
                }
            }
        }
    }

    pendingDelete?.let { photo ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("删除这张照片？") },
            text = { Text("照片文件和它的文字说明会一起删除，无法撤销。") },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.delete(listOf(photo.id))
                        pendingDelete = null
                    },
                ) {
                    Text("删除")
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("取消") }
            },
        )
    }
}
