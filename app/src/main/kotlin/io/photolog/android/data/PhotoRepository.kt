package io.photolog.android.data

import android.content.ContentResolver
import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import androidx.exifinterface.media.ExifInterface
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** What happened to one incoming image. */
sealed interface ImportOutcome {
    data class Added(val id: Long) : ImportOutcome
    data class Duplicate(val id: Long) : ImportOutcome
    data class Failed(val reason: String) : ImportOutcome
}

/**
 * The tally for a batch, plus the sentence to show the user.
 *
 * `firstAddedId` is what lets a share jump straight to the photo it just added instead of
 * dumping the user on the library list with no idea which item is new.
 */
data class ImportSummary(
    val added: Int,
    val duplicates: Int,
    val failed: Int,
    val firstAddedId: Long?,
) {
    fun describe(): String = when {
        added == 0 && duplicates == 0 && failed == 0 -> "没有可导入的图片"
        failed == 0 && duplicates == 0 -> "已导入 $added 张照片"
        failed == 0 && added == 0 -> "这 $duplicates 张已经在图库里了"
        failed == 0 -> "已导入 $added 张，跳过重复 $duplicates 张"
        added == 0 -> "导入失败 $failed 张"
        else -> "已导入 $added 张，跳过重复 $duplicates 张，失败 $failed 张"
    }
}

/**
 * The library: the files, and the rows that index them.
 *
 * Every method that touches a file or the database runs on [Dispatchers.IO]. The repository is
 * the only place in the app that knows where the originals live, which is what keeps the
 * "never re-encode the original" rule enforceable — the export path can only read bytes
 * through [fileFor], so it cannot accidentally overwrite the source.
 */
class PhotoRepository(
    private val context: Context,
    private val dao: PhotoDao,
) {

    /**
     * Serialises file-name allocation.
     *
     * Two imports started at once — a share arriving while the picker is still resolving — would
     * otherwise be able to pick the same millisecond-stamped name, and the second `renameTo`
     * would silently replace the first photo's bytes.
     */
    private val fileLock = Mutex()

    val originalsDir: File
        get() = File(context.filesDir, ORIGINALS).also { if (!it.exists()) it.mkdirs() }

    // --- reads ---------------------------------------------------------------- //

    fun observeAll(): Flow<List<PhotoEntity>> = dao.observeAll()

    fun observeOne(id: Long): Flow<PhotoEntity?> = dao.observeOne(id)

    fun observeCount(): Flow<Int> = dao.observeCount()

    fun observeTotalBytes(): Flow<Long> = dao.observeTotalBytes()

    suspend fun allOnce(): List<PhotoEntity> = dao.allOnce()

    suspend fun findOne(id: Long): PhotoEntity? = dao.findOne(id)

    /** The untouched original. Read-only by convention — nothing in this app writes to it. */
    fun fileFor(photo: PhotoEntity): File = File(originalsDir, photo.fileName)

    // --- capture -------------------------------------------------------------- //

    /**
     * Reserves a file for CameraX to write into.
     *
     * The file must exist as a path *before* the capture starts, because `ImageCapture` writes
     * to it directly — which is the point: the JPEG the sensor produced reaches disk without
     * passing through a bitmap, so it is the original by construction.
     */
    fun newCaptureFile(): File = allocate("c", "jpg")

    /**
     * Indexes a file the camera already wrote.
     *
     * The hash is computed here rather than during capture so the shutter stays responsive;
     * a 12 MP JPEG hashes in a few milliseconds on IO.
     */
    suspend fun registerCapture(file: File): Long = withContext(Dispatchers.IO) {
        val size = file.length()
        val sha = digestOf(file)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        val now = System.currentTimeMillis()
        dao.insert(
            PhotoEntity(
                caption = "",
                fileName = file.name,
                originalName = null,
                mimeType = resolveMime(null, bounds.outMimeType, file.name),
                width = bounds.outWidth.coerceAtLeast(0),
                height = bounds.outHeight.coerceAtLeast(0),
                sizeBytes = size,
                sha256 = sha,
                capturedAt = readCapturedAt(file) ?: now,
                addedAt = now,
                source = PhotoSource.CAMERA.name,
                sortIndex = nextSortIndex(),
            ),
        )
    }

    // --- import --------------------------------------------------------------- //

    suspend fun importUris(uris: List<Uri>, source: PhotoSource): ImportSummary {
        var added = 0
        var duplicates = 0
        var failed = 0
        var firstAddedId: Long? = null
        for (uri in uris) {
            when (val outcome = importUri(uri, source)) {
                is ImportOutcome.Added -> {
                    added++
                    if (firstAddedId == null) firstAddedId = outcome.id
                }

                is ImportOutcome.Duplicate -> duplicates++
                is ImportOutcome.Failed -> failed++
            }
        }
        return ImportSummary(added, duplicates, failed, firstAddedId)
    }

    /**
     * Copies one incoming image into the library.
     *
     * The whole file is streamed to a cache file first, hashing as it goes, and only then
     * promoted into `originals`. Two consequences are deliberate:
     *
     * - Nothing half-written can ever become a library entry. A provider that dies mid-read
     *   leaves a temp file, not a truncated photo with a caption attached.
     * - The duplicate check runs before the file is promoted, so re-sharing an image costs a
     *   hash and a delete rather than a second copy on disk.
     */
    suspend fun importUri(uri: Uri, source: PhotoSource): ImportOutcome = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val declared = resolver.getType(uri)
        val displayName = queryDisplayName(resolver, uri)
        val temp = File(context.cacheDir, "photolog_import_${System.nanoTime()}.tmp")

        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var size = 0L
            val opened = resolver.openInputStream(uri)
                ?: return@withContext ImportOutcome.Failed(displayName ?: "无法读取来源")

            opened.use { input ->
                temp.outputStream().use { output ->
                    val buffer = ByteArray(COPY_BUFFER)
                    var read = input.read(buffer)
                    while (read > 0) {
                        digest.update(buffer, 0, read)
                        output.write(buffer, 0, read)
                        size += read
                        read = input.read(buffer)
                    }
                }
            }
            if (size <= 0L) return@withContext ImportOutcome.Failed(displayName ?: "空文件")

            val sha = digest.digest().toHex()
            dao.findByHash(sha)?.let { return@withContext ImportOutcome.Duplicate(it.id) }

            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(temp.absolutePath, bounds)
            val width = bounds.outWidth.coerceAtLeast(0)
            val height = bounds.outHeight.coerceAtLeast(0)

            // A declared `image/*` is enough to accept the file even when the header could not
            // be decoded — HEIC on API 24-27 is a real case, and rejecting it would drop a
            // perfectly good photo.
            val looksLikeImage = declared?.startsWith("image/") == true || width > 0
            if (!looksLikeImage) return@withContext ImportOutcome.Failed(displayName ?: "不是图片")

            val mime = resolveMime(declared, bounds.outMimeType, displayName)
            val extension = extensionForMime(mime).takeIf { it != "bin" }
                ?: extensionFromName(displayName)
                ?: "bin"
            val now = System.currentTimeMillis()

            val target = fileLock.withLock {
                val allocated = allocate("g", extension)
                if (!temp.renameTo(allocated)) {
                    temp.inputStream().use { input ->
                        allocated.outputStream().use { input.copyTo(it, COPY_BUFFER) }
                    }
                }
                allocated
            }

            val id = dao.insert(
                PhotoEntity(
                    caption = "",
                    fileName = target.name,
                    originalName = displayName,
                    mimeType = mime,
                    width = width,
                    height = height,
                    sizeBytes = size,
                    sha256 = sha,
                    capturedAt = readCapturedAt(temp) ?: now,
                    addedAt = now,
                    source = source.name,
                    sortIndex = nextSortIndex(),
                ),
            )
            ImportOutcome.Added(id)
        } catch (t: Throwable) {
            ImportOutcome.Failed(t.message ?: (displayName ?: "读取失败"))
        } finally {
            // A no-op after a successful rename, which is why it is unconditional here.
            if (temp.exists()) temp.delete()
        }
    }

    // --- edits ---------------------------------------------------------------- //

    suspend fun setCaption(id: Long, caption: String) = dao.setCaption(id, caption)

    /**
     * Moves one photo `delta` places in the user's order.
     *
     * The whole list is renumbered rather than swapping two values. Swapping is only correct
     * while every `sortIndex` is distinct, and one row left at 0 by an interrupted write would
     * turn a swap into a silent no-op. Renumbering restores that invariant on every move.
     */
    suspend fun move(id: Long, delta: Int) = withContext(Dispatchers.IO) {
        val ordered = dao.allOnce().toMutableList()
        val from = ordered.indexOfFirst { it.id == id }
        if (from < 0) return@withContext
        val to = (from + delta).coerceIn(0, ordered.lastIndex)
        if (to == from) return@withContext
        ordered.add(to, ordered.removeAt(from))
        ordered.forEachIndexed { index, row -> dao.setSortIndex(row.id, index + 1L) }
    }

    suspend fun sortByCapturedAt() = withContext(Dispatchers.IO) {
        dao.allOnce()
            .sortedWith(compareBy({ it.capturedAt }, { it.id }))
            .forEachIndexed { index, row -> dao.setSortIndex(row.id, index + 1L) }
    }

    /** Deletes the rows and the files behind them. */
    suspend fun delete(ids: List<Long>) = withContext(Dispatchers.IO) {
        if (ids.isEmpty()) return@withContext
        val doomed = dao.allOnce().filter { it.id in ids }
        dao.deleteByIds(ids)
        doomed.forEach { photo -> runCatching { fileFor(photo).delete() } }
        dao.allOnce().forEachIndexed { index, row -> dao.setSortIndex(row.id, index + 1L) }
    }

    suspend fun deleteAll() = withContext(Dispatchers.IO) {
        val rows = dao.allOnce()
        if (rows.isNotEmpty()) dao.deleteByIds(rows.map { it.id })
        // Sweeps orphans too: a file whose row was lost by an older build should not survive
        // a "delete everything".
        originalsDir.listFiles()?.forEach { it.delete() }
    }

    // --- internals ------------------------------------------------------------ //

    private suspend fun nextSortIndex(): Long = (dao.maxSortIndex() ?: 0L) + 1L

    private fun allocate(prefix: String, extension: String): File {
        val dir = originalsDir
        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US).format(Date())
        var candidate = File(dir, "${prefix}_$stamp.$extension")
        var suffix = 1
        while (candidate.exists()) {
            candidate = File(dir, "${prefix}_${stamp}_$suffix.$extension")
            suffix++
        }
        return candidate
    }

    private fun queryDisplayName(resolver: ContentResolver, uri: Uri): String? = runCatching {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getString(0) else null
        }
    }.getOrNull()

    private fun digestOf(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(COPY_BUFFER)
            var read = input.read(buffer)
            while (read > 0) {
                digest.update(buffer, 0, read)
                read = input.read(buffer)
            }
        }
        return digest.digest().toHex()
    }

    /**
     * When the photo was taken, from EXIF.
     *
     * `DateTimeOriginal` is preferred over `DateTime`: the latter is when the file was last
     * written, which for a photo that has been through an editor is the edit, not the shot.
     * EXIF has no timezone, so the value is interpreted in the device's zone — the same
     * assumption every gallery app makes.
     */
    private fun readCapturedAt(file: File): Long? = runCatching {
        val exif = ExifInterface(file.absolutePath)
        val raw = exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL)
            ?: exif.getAttribute(ExifInterface.TAG_DATETIME)
        if (raw.isNullOrBlank()) {
            null
        } else {
            SimpleDateFormat("yyyy:MM:dd HH:mm:ss", Locale.US).parse(raw.trim())?.time
        }
    }.getOrNull()

    private fun ByteArray.toHex(): String {
        val builder = StringBuilder(size * 2)
        for (byte in this) {
            val value = byte.toInt() and 0xFF
            builder.append(HEX[value ushr 4]).append(HEX[value and 0x0F])
        }
        return builder.toString()
    }

    private companion object {
        const val ORIGINALS = "originals"
        const val COPY_BUFFER = 64 * 1024
        const val HEX = "0123456789abcdef"
    }
}
