package io.photolog.android.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import io.photolog.android.export.CaptionFormat
import io.photolog.android.export.ExportNaming
import io.photolog.android.export.ExportOptions
import io.photolog.android.export.ExportScope
import io.photolog.android.vm.ExportViewModel

/**
 * Everything about getting the photos out.
 *
 * The screen is organised as a single top-to-bottom decision: which photos, at what quality,
 * with what text, into what shape of output. The preview button exists because the caption
 * document is generated, not authored — the user cannot see it any other way before committing,
 * and finding out afterwards that the order is wrong means redoing the export.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExportScreen(
    viewModel: ExportViewModel,
    navController: NavHostController,
) {
    val photos by viewModel.photos.collectAsStateWithLifecycle()
    val settings by viewModel.settings.collectAsStateWithLifecycle()
    val progress by viewModel.progress.collectAsStateWithLifecycle()
    val preview by viewModel.preview.collectAsStateWithLifecycle()
    val message by viewModel.message.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }

    var exportScope by remember { mutableStateOf(ExportScope.ALL) }
    // Keyed on the stored value so the controls follow the persisted defaults as DataStore
    // finishes loading, and follow the user's own edits after that.
    var lossless by remember(settings.exportLossless) { mutableStateOf(settings.exportLossless) }
    var includeCaptions by remember(settings.exportIncludeCaptions) { mutableStateOf(settings.exportIncludeCaptions) }
    var numbered by remember(settings.exportNumbered) { mutableStateOf(settings.exportNumbered) }
    var nameFromCaption by remember(settings.exportNameFromCaption) { mutableStateOf(settings.exportNameFromCaption) }
    var quality by remember(settings.exportJpegQuality) { mutableStateOf(settings.exportJpegQuality) }
    var maxEdge by remember(settings.exportMaxLongEdge) { mutableStateOf(settings.exportMaxLongEdge) }
    val captionFormat = CaptionFormat.fromKey(settings.exportCaptionFormat)

    fun currentOptions(): ExportOptions = ExportOptions(
        lossless = lossless,
        jpegQuality = quality,
        maxLongEdge = maxEdge,
        includeCaptions = includeCaptions,
        captionFormat = captionFormat,
        numbered = numbered,
        useCaptionAsName = nameFromCaption,
    )

    val zipLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/zip"),
    ) { target ->
        if (target != null) viewModel.exportZip(target, exportScope, currentOptions())
    }

    val folderLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocumentTree(),
    ) { tree ->
        if (tree != null) viewModel.exportToTree(tree, exportScope, currentOptions())
    }

    val captionsLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("text/plain"),
    ) { target ->
        if (target != null) viewModel.exportCaptions(target, exportScope, currentOptions())
    }

    LaunchedEffect(message) {
        message?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.consumeMessage()
        }
    }

    val planned = remember(photos, exportScope, lossless, numbered, includeCaptions, captionFormat, nameFromCaption) {
        ExportNaming.plan(photos, exportScope, currentOptions()).size
    }
    val busy = progress != null

    Scaffold(
        topBar = { TopAppBar(title = { Text("导出") }) },
        bottomBar = { PhotoLogBottomBar(navController) },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (busy) {
                LinearProgressIndicator(
                    progress = { progress?.fraction ?: 0f },
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    text = progress?.let { p ->
                        if (p.total > 0) "${p.done} / ${p.total} · ${p.current}" else p.current
                    }.orEmpty(),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            SectionHeader("导出范围")
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ExportScope.entries.forEach { scope ->
                    FilterChip(
                        selected = exportScope == scope,
                        onClick = { exportScope = scope },
                        label = { Text(scope.label) },
                    )
                }
            }
            Hint("当前将导出 $planned 张，顺序就是「图库」里的顺序，可以在图库里上移下移调整。")

            HorizontalDivider(Modifier.padding(vertical = 10.dp))

            SectionHeader("图片质量")
            ToggleRow(
                label = "无损导出（推荐）",
                checked = lossless,
                onCheckedChange = {
                    lossless = it
                    viewModel.setExportLossless(it)
                },
            )
            Hint(
                if (lossless) {
                    "原样复制文件字节，不重新编码，EXIF、色彩信息和画质 100% 保留；文件大小与原图相同。"
                } else {
                    "会解码后重新编码为 JPEG，画质有损但文件更小。"
                },
            )

            if (!lossless) {
                Text("JPEG 质量", style = MaterialTheme.typography.bodyMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(80, 90, 95, 100).forEach { value ->
                        FilterChip(
                            selected = quality == value,
                            onClick = {
                                quality = value
                                viewModel.setExportJpegQuality(value)
                            },
                            label = { Text("$value") },
                        )
                    }
                }
                Text("最长边", style = MaterialTheme.typography.bodyMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(0 to "原始", 4096 to "4096", 2048 to "2048", 1280 to "1280").forEach { (value, label) ->
                        FilterChip(
                            selected = maxEdge == value,
                            onClick = {
                                maxEdge = value
                                viewModel.setExportMaxLongEdge(value)
                            },
                            label = { Text(label) },
                        )
                    }
                }
                Hint("限制最长边会在解码时就按倍数采样，避免超大图占用过多内存。")
            }

            HorizontalDivider(Modifier.padding(vertical = 10.dp))

            SectionHeader("文字说明")
            ToggleRow(
                label = "导出图片下方的文字说明",
                checked = includeCaptions,
                onCheckedChange = {
                    includeCaptions = it
                    viewModel.setExportIncludeCaptions(it)
                },
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                CaptionFormat.entries.forEach { format ->
                    FilterChip(
                        selected = captionFormat == format,
                        onClick = { viewModel.setExportCaptionFormat(format) },
                        label = { Text(format.label) },
                    )
                }
            }
            Hint(
                "说明文件的每一段都是「一张图 + 紧跟它下面的文字」，顺序与图库一致；" +
                    "Markdown 里的图片路径指向压缩包内的 ${ExportNaming.IMAGES_DIR}/ 目录。",
            )
            TextButton(onClick = { viewModel.showPreview(exportScope, currentOptions()) }) {
                Icon(Icons.Outlined.Description, contentDescription = null)
                Spacer(Modifier.width(6.dp))
                Text("预览说明文件")
            }

            HorizontalDivider(Modifier.padding(vertical = 10.dp))

            SectionHeader("文件命名")
            Text("文件名来源", style = MaterialTheme.typography.bodyMedium)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(
                    true to "用图片下方的说明文字",
                    false to "用原文件名",
                ).forEach { (fromCaption, label) ->
                    FilterChip(
                        selected = nameFromCaption == fromCaption,
                        onClick = {
                            nameFromCaption = fromCaption
                            viewModel.setExportNameFromCaption(fromCaption)
                        },
                        label = { Text(label) },
                    )
                }
            }
            Hint(
                if (nameFromCaption) {
                    "每张图以它下方的说明文字命名，例如「001_清晨的雾.jpg」；" +
                        "没有说明的照片回退到原文件名。说明里的换行、斜杠等非法字符会被替换成下划线，" +
                        "超长说明截断到 60 字，重名自动加 _2、_3。"
                } else {
                    "沿用相册里的原始文件名，例如「001_IMG_0001.jpg」。"
                },
            )
            ToggleRow(
                label = "加序号前缀（001_、002_…）",
                checked = numbered,
                onCheckedChange = {
                    numbered = it
                    viewModel.setExportNumbered(it)
                },
            )
            Hint("加上序号后，即使按文件名排序，图片顺序也和说明文件里的顺序一致。")

            HorizontalDivider(Modifier.padding(vertical = 10.dp))

            SectionHeader("输出方式")
            OutlinedButton(
                onClick = { zipLauncher.launch(defaultArchiveName()) },
                enabled = !busy && planned > 0,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Outlined.Archive, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("打包为 ZIP（图片 + 说明文件）")
            }
            OutlinedButton(
                onClick = { folderLauncher.launch(null) },
                enabled = !busy && planned > 0,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Outlined.FolderOpen, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("导出到文件夹（图片与说明分开放）")
            }
            OutlinedButton(
                onClick = { captionsLauncher.launch(captionFormat.fileName) },
                enabled = !busy && planned > 0,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Outlined.Description, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("只导出说明文件（${captionFormat.fileName}）")
            }
            Hint("ZIP 适合整包发给别人；文件夹适合自己归档，图片可以直接被其它应用打开。")

            Spacer(Modifier.padding(bottom = 24.dp))
        }
    }

    preview?.let { text ->
        AlertDialog(
            onDismissRequest = { viewModel.dismissPreview() },
            title = { Text("说明文件预览") },
            text = {
                Column(
                    modifier = Modifier
                        .heightIn(max = 420.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    Text(
                        text = text,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = { viewModel.dismissPreview() }) { Text("关闭") }
            },
        )
    }
}

/** `图志导出_20261012_093100.zip` — sorts chronologically next to other exports. */
private fun defaultArchiveName(): String =
    "图志导出_" + java.text.SimpleDateFormat("yyyyMMdd_HHmmss", java.util.Locale.US)
        .format(java.util.Date()) + ".zip"
