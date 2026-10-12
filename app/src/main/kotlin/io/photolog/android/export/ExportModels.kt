package io.photolog.android.export

import io.photolog.android.data.AppSettings
import io.photolog.android.data.PhotoEntity
import io.photolog.android.data.extensionForMime
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The three shapes the caption file can take.
 *
 * Each carries its own file name and MIME type so the export path never has to branch on the
 * format a second time — and so a new format cannot be added without also deciding what to
 * call it and how a Storage Access Framework provider should type it.
 */
enum class CaptionFormat(
    val key: String,
    val label: String,
    val fileName: String,
    val mimeType: String,
) {
    /** Image and caption interleaved, in order. The default: readable as plain text too. */
    MARKDOWN("markdown", "Markdown", "captions.md", "text/markdown"),

    /** A self-contained page that renders the photos and their captions side by side. */
    HTML("html", "HTML 网页", "captions.html", "text/html"),

    /** One tab-separated line per photo, for spreadsheets and scripts. */
    TEXT("text", "纯文本", "captions.txt", "text/plain");

    companion object {
        fun fromKey(key: String?): CaptionFormat = entries.firstOrNull { it.key == key } ?: MARKDOWN
    }
}

/** Which photos go into an export. */
enum class ExportScope(val label: String) {
    ALL("全部照片"),
    WITH_CAPTION("仅有文字说明"),
    RECENT("最近 20 张"),
}

/**
 * The export knobs.
 *
 * [lossless] is the one that matters: `true` copies the stored original byte for byte, and
 * every other field is then ignored. `false` decodes and re-encodes, which is why the three
 * fields under it exist at all.
 */
data class ExportOptions(
    val lossless: Boolean = true,
    val jpegQuality: Int = 95,
    /** Long-edge cap for the re-encode path. `0` keeps the original pixel dimensions. */
    val maxLongEdge: Int = 0,
    val includeCaptions: Boolean = true,
    val captionFormat: CaptionFormat = CaptionFormat.MARKDOWN,
    /** `001_`-style prefix, so a plain file listing preserves the order. */
    val numbered: Boolean = true,
    /**
     * Names each exported image after the caption under it.
     *
     * On by default, and the reason the option exists at all: a folder of `IMG_0001.jpg` tells
     * you nothing, while a folder of `001_清晨的雾.jpg` *is* the library. Photos without a
     * caption fall back to their original name either way.
     */
    val useCaptionAsName: Boolean = true,
)

/** One photo's place in an export: where it sits, and what it is called once written. */
data class ExportEntry(
    val photo: PhotoEntity,
    val index: Int,
    val name: String,
    val mimeType: String,
) {
    /** The path used inside the ZIP and inside the captions document. */
    val archivePath: String get() = "${ExportNaming.IMAGES_DIR}/$name"
}

data class ExportProgress(val done: Int, val total: Int, val current: String) {
    val fraction: Float get() = if (total <= 0) 0f else (done.toFloat() / total).coerceIn(0f, 1f)
}

sealed interface ExportResult {
    data class Success(val written: Int, val skipped: Int, val total: Int) : ExportResult

    data class Failed(val reason: String) : ExportResult

    fun describe(): String = when (this) {
        is Success -> when {
            written == 0 -> "没有写出任何文件（$skipped 张原图缺失）"
            skipped == 0 -> "已导出 $written / $total 张"
            else -> "已导出 $written / $total 张，$skipped 张原图缺失被跳过"
        }

        is Failed -> "导出失败：$reason"
    }
}

/** Turns the stored defaults into this run's options. */
fun AppSettings.toExportOptions(): ExportOptions = ExportOptions(
    lossless = exportLossless,
    jpegQuality = exportJpegQuality,
    maxLongEdge = exportMaxLongEdge,
    includeCaptions = exportIncludeCaptions,
    captionFormat = CaptionFormat.fromKey(exportCaptionFormat),
    numbered = exportNumbered,
    useCaptionAsName = exportNameFromCaption,
)

/**
 * Decides the order and the file names of an export.
 *
 * Pure, so the same function can be called to build the document, to name the ZIP entries and
 * to render the preview the user checks before committing — and those three can never
 * disagree about what the export will contain.
 *
 * Naming rule, in one line: **the image is named after the caption under it** when the photo
 * has one, otherwise after the source file name. See [baseName].
 */
object ExportNaming {

    const val IMAGES_DIR = "images"

    fun plan(photos: List<PhotoEntity>, scope: ExportScope, options: ExportOptions): List<ExportEntry> {
        // `photos` arrives in the user's order (sortIndex ASC), which is the order the export
        // must preserve — that ordering is the whole point of the feature.
        val ordered = when (scope) {
            ExportScope.ALL -> photos
            ExportScope.WITH_CAPTION -> photos.filter { it.caption.isNotBlank() }
            ExportScope.RECENT ->
                photos.sortedWith(compareByDescending<PhotoEntity> { it.addedAt }.thenByDescending { it.id })
                    .take(20)
                    .sortedBy { it.sortIndex }
        }

        val used = mutableSetOf<String>()
        return ordered.mapIndexed { position, photo ->
            val extension = if (options.lossless) extensionForMime(photo.mimeType) else "jpg"
            val base = baseName(photo, options)
            val prefix = if (options.numbered) String.format(Locale.US, "%03d_", position + 1) else ""
            var name = "$prefix$base.$extension"
            var suffix = 2
            // Case-insensitive: a ZIP with both `Photo.JPG` and `photo.jpg` is a support ticket
            // on Windows and macOS, where the two collide on extraction.
            while (!used.add(name.lowercase(Locale.US))) {
                name = "$prefix${base}_$suffix.$extension"
                suffix++
            }
            ExportEntry(
                photo = photo,
                index = position + 1,
                name = name,
                mimeType = if (options.lossless) photo.mimeType else "image/jpeg",
            )
        }
    }

    /** A file name for the single-photo export, without an order prefix. */
    fun suggestedName(photo: PhotoEntity, options: ExportOptions = ExportOptions()): String {
        val extension = extensionForMime(photo.mimeType)
        return "${baseName(photo, options)}.$extension"
    }

    /**
     * What the file is called, before the order prefix and the extension are attached.
     *
     * The caption wins when there is one — that is the point of the feature. Everything else is
     * a fallback chain: the source app's own file name, then the name this app generated, and
     * finally the literal `photo` if even that sanitises away to nothing.
     *
     * A caption is *not* required to be a valid file name, so it always goes through
     * [sanitize]; a name derived from a caption can therefore collide with another, which the
     * caller's de-duplication handles.
     */
    private fun baseName(photo: PhotoEntity, options: ExportOptions): String {
        if (options.useCaptionAsName) {
            val caption = photo.caption.trim()
            if (caption.isNotEmpty()) return sanitize(caption)
        }
        val original = photo.originalName?.substringBeforeLast('.')?.takeIf { it.isNotBlank() }
        return sanitize(original ?: photo.fileName.substringBeforeLast('.'))
    }

    /**
     * Characters that are illegal in a file name on at least one platform this archive may be
     * opened on. `/` and `\` matter most: a name containing one would create a directory
     * instead of a file. The `\u0000-\u001F` range covers the newlines and tabs a multi-line
     * caption contains, which are illegal on every platform rather than just awkward.
     */
    private val UNSAFE = Regex("[\\\\/:*?\"<>|\\u0000-\\u001F]")

    /** Runs of spaces left behind by a caption like `早上   在阳台拍的`. */
    private val SPACE_RUN = Regex(" +")

    /**
     * Device names that Windows resolves to hardware rather than to a file, so a caption of
     * `CON` would produce an image nobody can open on a Windows machine. Prefixing with `_`
     * keeps the caption recognisable instead of replacing it.
     */
    private val WINDOWS_RESERVED = setOf(
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    )

    /**
     * Longest name kept, in characters.
     *
     * The number is chosen for Chinese, which is the worst case: one CJK character is 3 UTF-8
     * bytes, so 60 of them is 180 bytes — still inside the 255-byte limit most filesystems
     * impose, with room left for the order prefix and the extension. Counting characters rather
     * than bytes is deliberate: truncating a UTF-8 string by bytes is how a file name ends up
     * with a broken character in it.
     */
    private const val MAX_NAME_CHARS = 60

    private const val FALLBACK_NAME = "photo"

    /**
     * Turns arbitrary user text into a name that survives every filesystem this archive may
     * land on.
     *
     * Chinese needs no special handling and gets none: CJK ideographs, full-width punctuation
     * (`：`, `？`, `｜`) and emoji are all legal in a file name on Android, Windows, macOS and
     * Linux, so the filter below only removes what is actually illegal. Notably it does **not**
     * touch `：` — the ASCII `:` is illegal on Windows, the full-width one is a different
     * character and is fine, and rewriting it would mangle a Chinese sentence for nothing.
     *
     * The `trim('.')` calls are not cosmetic: a name ending in a dot is silently stripped by
     * Windows and refused outright by some servers, and `.` / `..` are not files at all.
     */
    fun sanitize(raw: String): String {
        val cleaned = raw
            .replace(UNSAFE, "_")
            .replace(SPACE_RUN, " ")
            .trim()
            .trim('.')
            .takeCodePoints(MAX_NAME_CHARS)
            .trim()
            .trim('.')
            .ifEmpty { FALLBACK_NAME }
        return if (cleaned.uppercase(Locale.US) in WINDOWS_RESERVED) "_$cleaned" else cleaned
    }

    /**
     * Truncates without splitting a surrogate pair.
     *
     * `String.take` counts UTF-16 code units, so cutting an emoji in half leaves an unpaired
     * surrogate — and `toByteArray(UTF_8)` silently turns that into `?`. A caption like
     * `第一天🌅` is an ordinary thing to write, and the exported file name should not end in a
     * question mark because of it.
     */
    private fun String.takeCodePoints(limit: Int): String {
        if (length <= limit) return this
        var end = limit
        if (end > 0 && Character.isHighSurrogate(this[end - 1])) end--
        return substring(0, end)
    }
}

/**
 * The "图片 + 图下文字说明" document.
 *
 * The order of the entries in the file is the order of the photos, and each caption sits
 * directly under its image — which is the requirement, and also the only arrangement that
 * survives being copied into a chat or a document.
 */
object CaptionDocument {

    fun build(plan: List<ExportEntry>, options: ExportOptions, exportedAt: Long): String =
        when (options.captionFormat) {
            CaptionFormat.MARKDOWN -> markdown(plan, options, exportedAt)
            CaptionFormat.HTML -> html(plan, options, exportedAt)
            CaptionFormat.TEXT -> text(plan, options, exportedAt)
        }

    // --- formats -------------------------------------------------------------- //

    private fun markdown(plan: List<ExportEntry>, options: ExportOptions, exportedAt: Long): String =
        buildString {
            appendLine("# 图志导出")
            appendLine()
            metadata(plan, options, exportedAt).forEach { (key, value) -> appendLine("- $key：$value") }
            plan.forEach { entry ->
                appendLine()
                appendLine("---")
                appendLine()
                appendLine("## ${indexLabel(entry.index)} · ${formatStamp(entry.photo.capturedAt)}")
                appendLine()
                appendLine("![${indexLabel(entry.index)}](${entry.archivePath})")
                appendLine()
                appendLine(entry.photo.caption.ifBlank { NO_CAPTION })
            }
            appendLine()
        }

    private fun html(plan: List<ExportEntry>, options: ExportOptions, exportedAt: Long): String =
        buildString {
            appendLine("<!DOCTYPE html>")
            appendLine("<html lang=\"zh-CN\">")
            appendLine("<head>")
            appendLine("<meta charset=\"utf-8\">")
            appendLine("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
            appendLine("<title>图志导出</title>")
            appendLine("<style>")
            appendLine(":root{color-scheme:light dark}")
            appendLine("body{margin:0;padding:24px;background:#f8f9fc;color:#191c20;line-height:1.7;")
            appendLine("font-family:system-ui,-apple-system,\"PingFang SC\",\"Microsoft YaHei\",sans-serif}")
            appendLine("h1{font-size:22px;margin:0 0 12px}")
            appendLine(".meta{color:#43474e;font-size:14px;margin:0 0 28px}")
            appendLine("figure{margin:0 0 32px;background:#fff;border-radius:12px;overflow:hidden;")
            appendLine("box-shadow:0 1px 3px rgba(0,0,0,.12)}")
            appendLine("figure img{display:block;width:100%;height:auto;background:#e0e2ec}")
            appendLine("figcaption{padding:14px 16px;font-size:15px}")
            appendLine("figcaption .idx{display:inline-block;min-width:2.6em;color:#1d4e89;font-weight:600}")
            appendLine("@media (prefers-color-scheme:dark){body{background:#111318;color:#e2e2e6}")
            appendLine(".meta{color:#c3c6cf}figure{background:#1c1f24;box-shadow:none}")
            appendLine("figure img{background:#43474e}figcaption .idx{color:#a6c8ff}}")
            appendLine("</style>")
            appendLine("</head>")
            appendLine("<body>")
            appendLine("<h1>图志导出</h1>")
            appendLine("<p class=\"meta\">")
            metadata(plan, options, exportedAt).forEach { (key, value) ->
                appendLine("${escape(key)}：${escape(value)}<br>")
            }
            appendLine("</p>")
            plan.forEach { entry ->
                appendLine("<figure>")
                appendLine(
                    "<img src=\"${escape(entry.archivePath)}\" alt=\"${indexLabel(entry.index)}\" loading=\"lazy\">",
                )
                appendLine(
                    "<figcaption><span class=\"idx\">${indexLabel(entry.index)}</span>" +
                        "${escape(entry.photo.caption.ifBlank { NO_CAPTION })}</figcaption>",
                )
                appendLine("</figure>")
            }
            appendLine("</body>")
            appendLine("</html>")
        }

    /**
     * The plain-text document, prefixed with a UTF-8 byte-order mark.
     *
     * `.txt` is the one format with nowhere in-band to declare its encoding. Without the mark,
     * a Chinese caption opened in Notepad on Windows, or double-clicked straight into Excel,
     * comes out as mojibake — the classic 「中文乱码」 complaint. Markdown and HTML both declare
     * their encoding, so they are left alone; a BOM there would only be an invisible character
     * in every diff.
     */
    private fun text(plan: List<ExportEntry>, options: ExportOptions, exportedAt: Long): String =
        buildString {
            append(BOM)
            appendLine("图志导出")
            metadata(plan, options, exportedAt).forEach { (key, value) -> appendLine("$key：$value") }
            appendLine()
            appendLine("# 序号\t图片路径\t文字说明")
            plan.forEach { entry ->
                val caption = entry.photo.caption.replace('\n', ' ').replace('\t', ' ').ifBlank { NO_CAPTION }
                appendLine("${indexLabel(entry.index)}\t${entry.archivePath}\t$caption")
            }
        }

    // --- shared --------------------------------------------------------------- //

    private const val NO_CAPTION = "（无说明）"

    /** U+FEFF, written out as EF BB BF by `toByteArray(UTF_8)`. */
    private const val BOM = '\uFEFF'

    private fun metadata(
        plan: List<ExportEntry>,
        options: ExportOptions,
        exportedAt: Long,
    ): List<Pair<String, String>> = listOf(
        "导出时间" to formatStamp(exportedAt),
        "照片数量" to "${plan.size}",
        "图片目录" to "${ExportNaming.IMAGES_DIR}/",
        "图片模式" to if (options.lossless) {
            "无损（原样复制，未重新编码，EXIF 保留）"
        } else {
            "重新编码 JPEG（质量 ${options.jpegQuality}" +
                (if (options.maxLongEdge > 0) "，最长边 ${options.maxLongEdge}px" else "，原始尺寸") + "）"
        },
        "已写说明" to "${plan.count { it.photo.caption.isNotBlank() }} / ${plan.size}",
    )

    private fun indexLabel(index: Int): String = String.format(Locale.US, "%03d", index)

    private fun formatStamp(millis: Long): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(millis))

    private fun escape(raw: String): String = raw
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
}
