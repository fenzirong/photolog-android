package io.photolog.android.export

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import android.provider.DocumentsContract
import androidx.exifinterface.media.ExifInterface
import io.photolog.android.data.PhotoEntity
import io.photolog.android.data.PhotoRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.BufferedOutputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

private const val COPY_BUFFER = 64 * 1024

/**
 * Writes the library out to wherever the user picked.
 *
 * Two output shapes, and they differ in more than packaging:
 *
 * - **ZIP** goes through a single `CreateDocument` grant and produces one self-contained file.
 *   This is the one to send to someone.
 * - **Folder** goes through `OpenDocumentTree` and writes loose images plus the captions file,
 *   so the result can be browsed, edited and re-imported by other apps. This is the one to keep.
 *
 * Both call the same [writeImageBytes], so the 无损 guarantee holds identically in either.
 */
class Exporter(
    private val context: Context,
    private val repository: PhotoRepository,
) {

    // --- single photo --------------------------------------------------------- //

    suspend fun exportSingle(
        photo: PhotoEntity,
        target: Uri,
        options: ExportOptions,
    ): ExportResult = withContext(Dispatchers.IO) {
        val source = repository.fileFor(photo)
        if (!source.exists()) return@withContext ExportResult.Failed("原图文件已丢失")
        try {
            val sink = openOutput(target) ?: return@withContext ExportResult.Failed("无法写入所选位置")
            sink.use { writeImageBytes(source, photo, it, options) }
            ExportResult.Success(1, 0, 1)
        } catch (t: Throwable) {
            ExportResult.Failed(t.message ?: "写入失败")
        }
    }

    // --- ZIP ------------------------------------------------------------------ //

    suspend fun exportZip(
        photos: List<PhotoEntity>,
        target: Uri,
        scope: ExportScope,
        options: ExportOptions,
        onProgress: (ExportProgress) -> Unit,
    ): ExportResult = withContext(Dispatchers.IO) {
        val plan = ExportNaming.plan(photos, scope, options)
        if (plan.isEmpty()) return@withContext ExportResult.Failed("没有符合条件的照片")

        try {
            val sink = openOutput(target) ?: return@withContext ExportResult.Failed("无法写入所选位置")
            // `use` owns the SAF stream; ArchiveWriter deliberately does not close it.
            val result = sink.use { raw ->
                ArchiveWriter.writeZip(
                    plan = plan,
                    sink = raw,
                    options = options,
                    source = { repository.fileFor(it) },
                    onProgress = onProgress,
                )
            }
            onProgress(ExportProgress(plan.size, plan.size, ""))
            result
        } catch (t: Throwable) {
            ExportResult.Failed(t.message ?: "打包失败")
        }
    }

    // --- folder --------------------------------------------------------------- //

    /**
     * Writes into a user-picked directory tree.
     *
     * `DocumentsContract.createDocument` is used rather than `DocumentFile.createFile` because
     * the latter appends an extension derived from the MIME type, which would turn
     * `001_IMG_0001.jpg` into `001_IMG_0001.jpg.jpg` on providers that already honour the name.
     * The contract call passes the display name through verbatim — which is also what makes a
     * Chinese caption survive as a file name.
     */
    suspend fun exportToTree(
        photos: List<PhotoEntity>,
        treeUri: Uri,
        scope: ExportScope,
        options: ExportOptions,
        onProgress: (ExportProgress) -> Unit,
    ): ExportResult = withContext(Dispatchers.IO) {
        val plan = ExportNaming.plan(photos, scope, options)
        if (plan.isEmpty()) return@withContext ExportResult.Failed("没有符合条件的照片")

        val resolver = context.contentResolver
        try {
            val rootId = DocumentsContract.getTreeDocumentId(treeUri)
            val root = DocumentsContract.buildDocumentUriUsingTree(treeUri, rootId)
            val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
            val folder = DocumentsContract.createDocument(
                resolver,
                root,
                DocumentsContract.Document.MIME_TYPE_DIR,
                "图志导出_$stamp",
            ) ?: return@withContext ExportResult.Failed("无法在所选位置创建文件夹")

            val imagesFolder = DocumentsContract.createDocument(
                resolver,
                folder,
                DocumentsContract.Document.MIME_TYPE_DIR,
                ExportNaming.IMAGES_DIR,
            ) ?: return@withContext ExportResult.Failed("无法创建 ${ExportNaming.IMAGES_DIR} 目录")

            var written = 0
            var skipped = 0

            for (entry in plan) {
                onProgress(ExportProgress(entry.index - 1, plan.size, entry.name))
                val source = repository.fileFor(entry.photo)
                if (!source.exists()) {
                    skipped++
                    continue
                }
                val document = DocumentsContract.createDocument(
                    resolver,
                    imagesFolder,
                    entry.mimeType,
                    entry.name,
                )
                if (document == null) {
                    skipped++
                    continue
                }
                val sink = resolver.openOutputStream(document, "w")
                if (sink == null) {
                    skipped++
                    continue
                }
                sink.use { writeImageBytes(source, entry.photo, it, options) }
                written++
            }

            if (options.includeCaptions) {
                val document = DocumentsContract.createDocument(
                    resolver,
                    folder,
                    options.captionFormat.mimeType,
                    options.captionFormat.fileName,
                )
                if (document != null) {
                    resolver.openOutputStream(document, "w")?.use { sink ->
                        sink.write(
                            CaptionDocument.build(plan, options, System.currentTimeMillis())
                                .toByteArray(Charsets.UTF_8),
                        )
                    }
                }
            }

            onProgress(ExportProgress(plan.size, plan.size, ""))
            ExportResult.Success(written, skipped, plan.size)
        } catch (t: Throwable) {
            ExportResult.Failed(t.message ?: "写入失败")
        }
    }

    // --- captions only -------------------------------------------------------- //

    /** The document on its own, for a user who already has the images somewhere else. */
    suspend fun exportCaptionsOnly(
        photos: List<PhotoEntity>,
        target: Uri,
        scope: ExportScope,
        options: ExportOptions,
    ): ExportResult = withContext(Dispatchers.IO) {
        val plan = ExportNaming.plan(photos, scope, options)
        if (plan.isEmpty()) return@withContext ExportResult.Failed("没有符合条件的照片")
        try {
            val sink = openOutput(target) ?: return@withContext ExportResult.Failed("无法写入所选位置")
            sink.use {
                it.write(CaptionDocument.build(plan, options, System.currentTimeMillis()).toByteArray(Charsets.UTF_8))
            }
            ExportResult.Success(plan.size, 0, plan.size)
        } catch (t: Throwable) {
            ExportResult.Failed(t.message ?: "写入失败")
        }
    }

    /** A head of the document, so the user can check the order and the format before writing. */
    fun captionPreview(photos: List<PhotoEntity>, scope: ExportScope, options: ExportOptions): String {
        val plan = ExportNaming.plan(photos, scope, options)
        if (plan.isEmpty()) return "没有符合条件的照片。"
        val document = CaptionDocument.build(plan, options, System.currentTimeMillis())
        val lines = document.lines()
        val head = lines.take(PREVIEW_LINES).joinToString("\n")
        return if (lines.size > PREVIEW_LINES) "$head\n\n…（共 ${lines.size} 行，此处只预览前 $PREVIEW_LINES 行）" else head
    }

    private fun openOutput(target: Uri): OutputStream? =
        context.contentResolver.openOutputStream(target, "w")

    private companion object {
        const val PREVIEW_LINES = 40
    }
}

/**
 * Builds the ZIP.
 *
 * Split out of [Exporter] and free of Android types on purpose: the two things most likely to
 * be wrong about an archive — the order of its entries, and whether a Chinese file name inside
 * it survives the round trip — are exactly the two things a JVM unit test can prove and a
 * device screenshot cannot.
 *
 * **It does not close [sink].** The caller owns the stream, and closing it here would close the
 * Storage Access Framework stream twice — once from `ZipOutputStream`'s own close and once from
 * the caller's `use`.
 */
internal object ArchiveWriter {

    fun writeZip(
        plan: List<ExportEntry>,
        sink: OutputStream,
        options: ExportOptions,
        source: (PhotoEntity) -> File,
        onProgress: (ExportProgress) -> Unit,
    ): ExportResult {
        var written = 0
        var skipped = 0

        val zip = ZipOutputStream(BufferedOutputStream(sink, COPY_BUFFER))
        for (entry in plan) {
            onProgress(ExportProgress(entry.index - 1, plan.size, entry.name))
            val file = source(entry.photo)
            if (!file.exists()) {
                skipped++
                continue
            }
            // `ZipEntry(String)` is written with the stream's UTF-8 charset and the language
            // encoding flag set, which is what stops a Chinese name from turning into mojibake
            // when the archive is opened on Windows.
            zip.putNextEntry(ZipEntry(entry.archivePath))
            writeImageBytes(file, entry.photo, zip, options)
            zip.closeEntry()
            written++
        }

        if (options.includeCaptions) {
            zip.putNextEntry(ZipEntry(options.captionFormat.fileName))
            zip.write(
                CaptionDocument.build(plan, options, System.currentTimeMillis()).toByteArray(Charsets.UTF_8),
            )
            zip.closeEntry()
        }

        // Writes the central directory without closing the caller's stream.
        zip.finish()
        zip.flush()

        return ExportResult.Success(written, skipped, plan.size)
    }
}

/**
 * The one place image bytes reach an output.
 *
 * The lossless branch is a raw stream copy: the file on disk is exactly what the camera or the
 * source app produced, so the copy is bit-identical, EXIF and all. That is the whole feature —
 * it cannot be implemented by decoding and re-encoding, because a JPEG encoder is lossy even
 * at quality 100.
 *
 * It is also the branch that never touches an Android graphics class, which is what makes the
 * lossless path testable off-device.
 */
private fun writeImageBytes(
    source: File,
    photo: PhotoEntity,
    sink: OutputStream,
    options: ExportOptions,
) {
    if (options.lossless) {
        source.inputStream().use { it.copyTo(sink, COPY_BUFFER) }
        return
    }

    val decoded = decodeScaled(source, options.maxLongEdge)
        ?: throw IOException("无法解码 ${photo.fileName}")
    try {
        val oriented = applyExifOrientation(source, decoded)
        try {
            if (!oriented.compress(Bitmap.CompressFormat.JPEG, options.jpegQuality.coerceIn(1, 100), sink)) {
                throw IOException("JPEG 编码失败")
            }
        } finally {
            if (oriented !== decoded) oriented.recycle()
        }
    } finally {
        decoded.recycle()
    }
}

/**
 * Decodes at a bounded size.
 *
 * `inSampleSize` is the only downsample that does not allocate the full bitmap first — a
 * 108 MP photo is 430 MB as ARGB_8888, and asking for it before scaling would OOM on any
 * phone. The power-of-two sampling means the result is at most [maxLongEdge] on the long edge,
 * and at worst half of it.
 */
private fun decodeScaled(file: File, maxLongEdge: Int): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.absolutePath, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

    val options = BitmapFactory.Options().apply {
        inSampleSize = if (maxLongEdge > 0) sampleSizeFor(bounds.outWidth, bounds.outHeight, maxLongEdge) else 1
        inPreferredConfig = Bitmap.Config.ARGB_8888
    }
    return BitmapFactory.decodeFile(file.absolutePath, options)
}

private fun sampleSizeFor(width: Int, height: Int, maxLongEdge: Int): Int {
    var sample = 1
    while (maxOf(width, height) / sample > maxLongEdge && sample < 64) sample *= 2
    return sample
}

/**
 * Bakes the EXIF rotation into the pixels.
 *
 * Only on the re-encode path. A lossless copy keeps the EXIF tag and the untouched pixels,
 * which is correct — the viewer is supposed to apply it. Rotating the pixels *and* leaving the
 * tag would double the rotation on a viewer that honours it.
 */
private fun applyExifOrientation(file: File, bitmap: Bitmap): Bitmap {
    val orientation = runCatching {
        ExifInterface(file.absolutePath)
            .getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
    }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)

    val matrix = Matrix()
    when (orientation) {
        ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
        ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
        ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
        ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
        ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
        else -> return bitmap
    }
    return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
}
