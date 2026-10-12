package io.photolog.android.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.FileDownload
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import io.photolog.android.vm.DetailViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * One photo, its text, and everything that can be done to it.
 *
 * The caption field is the point of this screen: it writes through to the database on a short
 * debounce, so the text survives the user swiping back mid-sentence without a save button that
 * they would have to remember to press.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DetailScreen(
    viewModel: DetailViewModel,
    onBack: () -> Unit,
) {
    val photo by viewModel.photo.collectAsStateWithLifecycle()
    val message by viewModel.message.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }
    val coroutineScope = rememberCoroutineScope()

    var confirmDelete by remember { mutableStateOf(false) }
    var exporting by remember { mutableStateOf(false) }

    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("image/*"),
    ) { target ->
        val current = photo
        if (target == null || current == null) return@rememberLauncherForActivityResult
        coroutineScope.launch {
            exporting = true
            val result = viewModel.exportSingle(current, target)
            exporting = false
            snackbarHostState.showSnackbar(result.describe())
        }
    }

    LaunchedEffect(message) {
        message?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.consumeMessage()
        }
    }

    val current = photo

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(current?.let { "第 ${it.sortIndex} 张" } ?: "照片") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "返回")
                    }
                },
                actions = {
                    IconButton(onClick = { viewModel.move(-1) }, enabled = current != null) {
                        Icon(Icons.Outlined.ArrowUpward, contentDescription = "在导出顺序里上移")
                    }
                    IconButton(onClick = { viewModel.move(1) }, enabled = current != null) {
                        Icon(Icons.Outlined.ArrowDownward, contentDescription = "在导出顺序里下移")
                    }
                    IconButton(
                        onClick = {
                            current?.let { exportLauncher.launch(viewModel.suggestedExportName(it)) }
                        },
                        enabled = current != null,
                    ) {
                        Icon(Icons.Outlined.FileDownload, contentDescription = "无损导出这张")
                    }
                    IconButton(onClick = { confirmDelete = true }, enabled = current != null) {
                        Icon(Icons.Outlined.Delete, contentDescription = "删除")
                    }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
        if (current == null) {
            Box(
                modifier = Modifier
                    .padding(padding)
                    .fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Text("这张照片已经不在图库里了")
            }
            return@Scaffold
        }

        CaptionEditor(
            photoId = current.id,
            storedCaption = current.caption,
            onSave = { viewModel.saveCaption(it) },
        ) { caption, setCaption ->
            Column(
                modifier = Modifier
                    .padding(padding)
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                if (exporting) {
                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                }

                AsyncImage(
                    model = viewModel.fileFor(current),
                    contentDescription = current.caption.ifBlank { null },
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 8.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant),
                )

                OutlinedTextField(
                    value = caption,
                    onValueChange = setCaption,
                    label = { Text("图片下方的文字说明") },
                    placeholder = { Text("这是什么时候、在哪、拍的什么？") },
                    minLines = 3,
                    modifier = Modifier.fillMaxWidth(),
                )
                Hint("输入后自动保存；导出时这段文字会跟在对应图片下面，按顺序一起写进说明文件。")

                Text("照片信息", style = MaterialTheme.typography.titleMedium)
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    MetaRow("文件名", current.originalName ?: current.fileName)
                    MetaRow("尺寸", if (current.width > 0) "${current.width} × ${current.height}" else "未知")
                    MetaRow("大小", formatBytes(current.sizeBytes))
                    MetaRow("格式", current.mimeType)
                    MetaRow("拍摄时间", formatDateTime(current.capturedAt))
                    MetaRow("导入方式", sourceLabel(current.source))
                    MetaRow("顺序", "${current.sortIndex}（导出时按此顺序）")
                    MetaRow("校验值", "${current.sha256.take(16)}…")
                }

                Text(
                    text = "无损导出会把上面这份原始文件按字节复制一份，不做任何重新编码，EXIF 与画质完全保留。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 24.dp),
                )
            }
        }
    }

    if (confirmDelete && current != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("删除这张照片？") },
            text = { Text("照片文件和它的文字说明会一起删除，无法撤销。") },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmDelete = false
                        viewModel.delete(onBack)
                    },
                ) {
                    Text("删除")
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = false }) { Text("取消") }
            },
        )
    }
}

/**
 * Holds the caption being typed and writes it back after a pause.
 *
 * Keyed on the photo id so navigating from one photo to the next cannot carry the previous
 * photo's text into the new field — the classic bug in an editor that uses a plain `remember`.
 */
@Composable
private fun CaptionEditor(
    photoId: Long,
    storedCaption: String,
    onSave: (String) -> Unit,
    content: @Composable (String, (String) -> Unit) -> Unit,
) {
    var caption by remember(photoId) { mutableStateOf(storedCaption) }

    LaunchedEffect(photoId, caption) {
        if (caption == storedCaption) return@LaunchedEffect
        delay(SAVE_DEBOUNCE_MS)
        onSave(caption)
    }

    content(caption) { caption = it }
}

private const val SAVE_DEBOUNCE_MS = 400L
