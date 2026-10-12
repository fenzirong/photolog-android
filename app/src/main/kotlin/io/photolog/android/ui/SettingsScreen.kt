package io.photolog.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.DeleteSweep
import androidx.compose.material.icons.outlined.Sort
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
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
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import io.photolog.android.data.AppSettings
import io.photolog.android.export.CaptionFormat
import io.photolog.android.vm.SettingsViewModel

/**
 * Settings.
 *
 * Grouped by what the user is trying to change rather than by which subsystem implements it:
 * "how does it look", "what do my exports default to", "how much space is this using".
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    viewModel: SettingsViewModel,
    navController: NavHostController,
) {
    val settings by viewModel.settings.collectAsStateWithLifecycle()
    val count by viewModel.count.collectAsStateWithLifecycle()
    val totalBytes by viewModel.totalBytes.collectAsStateWithLifecycle()
    val message by viewModel.message.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }
    var confirmClear by remember { mutableStateOf(false) }

    LaunchedEffect(message) {
        message?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.consumeMessage()
        }
    }

    Scaffold(
        topBar = { TopAppBar(title = { Text("设置") }) },
        bottomBar = { PhotoLogBottomBar(navController) },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            SectionHeader("外观")
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(
                    AppSettings.THEME_SYSTEM to "跟随系统",
                    AppSettings.THEME_LIGHT to "浅色",
                    AppSettings.THEME_DARK to "深色",
                ).forEach { (mode, label) ->
                    FilterChip(
                        selected = settings.themeMode == mode,
                        onClick = { viewModel.setThemeMode(mode) },
                        label = { Text(label) },
                    )
                }
            }

            HorizontalDivider(Modifier.padding(vertical = 10.dp))

            SectionHeader("导出默认值")
            Hint("这里是「导出」页每次打开时的初始值，导出时仍然可以临时改动。")
            ToggleRow(
                label = "默认无损导出",
                checked = settings.exportLossless,
                onCheckedChange = { viewModel.setExportLossless(it) },
            )
            ToggleRow(
                label = "默认包含文字说明",
                checked = settings.exportIncludeCaptions,
                onCheckedChange = { viewModel.setExportIncludeCaptions(it) },
            )
            ToggleRow(
                label = "默认给文件名加序号前缀",
                checked = settings.exportNumbered,
                onCheckedChange = { viewModel.setExportNumbered(it) },
            )
            Text("导出图片的文件名来源", style = MaterialTheme.typography.bodyMedium)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(
                    true to "用图片下方的说明文字",
                    false to "用原文件名",
                ).forEach { (fromCaption, label) ->
                    FilterChip(
                        selected = settings.exportNameFromCaption == fromCaption,
                        onClick = { viewModel.setExportNameFromCaption(fromCaption) },
                        label = { Text(label) },
                    )
                }
            }
            Hint(
                if (settings.exportNameFromCaption) {
                    "有说明的照片以说明命名，没有说明的回退到原文件名；非法字符会替换、超长截断、重名加后缀。"
                } else {
                    "沿用相册里的原始文件名。"
                },
            )
            Text("说明文件格式", style = MaterialTheme.typography.bodyMedium)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                CaptionFormat.entries.forEach { format ->
                    FilterChip(
                        selected = CaptionFormat.fromKey(settings.exportCaptionFormat) == format,
                        onClick = { viewModel.setExportCaptionFormat(format) },
                        label = { Text(format.label) },
                    )
                }
            }
            if (!settings.exportLossless) {
                Text("JPEG 质量", style = MaterialTheme.typography.bodyMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(80, 90, 95, 100).forEach { value ->
                        FilterChip(
                            selected = settings.exportJpegQuality == value,
                            onClick = { viewModel.setExportJpegQuality(value) },
                            label = { Text("$value") },
                        )
                    }
                }
                Text("最长边", style = MaterialTheme.typography.bodyMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(0 to "原始", 4096 to "4096", 2048 to "2048", 1280 to "1280").forEach { (value, label) ->
                        FilterChip(
                            selected = settings.exportMaxLongEdge == value,
                            onClick = { viewModel.setExportMaxLongEdge(value) },
                            label = { Text(label) },
                        )
                    }
                }
            }

            HorizontalDivider(Modifier.padding(vertical = 10.dp))

            SectionHeader("存储")
            Hint("共 $count 张照片，占用 ${formatBytes(totalBytes)}。原图保存在应用私有目录，卸载应用会一并删除。")
            OutlinedButton(onClick = { viewModel.sortByCapturedAt() }) {
                Icon(Icons.Outlined.Sort, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("按拍摄时间重排导出顺序")
            }
            Spacer(Modifier.padding(bottom = 4.dp))
            OutlinedButton(onClick = { confirmClear = true }) {
                Icon(Icons.Outlined.DeleteSweep, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("清空图库（删除全部照片与说明）")
            }

            HorizontalDivider(Modifier.padding(vertical = 10.dp))

            SectionHeader("关于")
            Hint(
                "图志把「照片 + 它下面的一行文字」当作一个整体：拍下或收下的图片原样保存，" +
                    "说明写在图片下方，导出时可以按当前顺序把图片和说明一起带走。",
            )
            Hint(
                "接收分享：在相册、文件管理器或聊天应用里选中图片，用「分享」发送到「图志」即可入库；" +
                    "支持一次分享多张。",
            )
            Hint(
                "无损导出：导出时默认按字节复制原始文件，不重新编码，EXIF 与画质完全保留；" +
                    "也可以切换为压缩导出以减小体积。",
            )
            Hint(
                "隐私：应用只申请相机权限。相册导入使用系统照片选择器，不需要存储权限；" +
                    "导出走系统文件选择器，由你指定写入位置。",
            )
            Hint(
                "备份：图库（照片与说明）不参与系统云备份，避免出现「有说明没有图」的半份数据。" +
                    "需要长期留存请用「导出 → 打包为 ZIP」。",
            )
            Text(
                text = "版本 1.0.0",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.padding(bottom = 24.dp))
        }
    }

    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("清空图库？") },
            text = { Text("将删除全部 $count 张照片及其文字说明，占用 ${formatBytes(totalBytes)}，无法撤销。") },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmClear = false
                        viewModel.deleteAll()
                    },
                ) {
                    Text("全部删除")
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmClear = false }) { Text("取消") }
            },
        )
    }
}
