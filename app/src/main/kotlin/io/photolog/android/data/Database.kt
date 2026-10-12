package io.photolog.android.data

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import kotlinx.coroutines.flow.Flow

/**
 * Where a photo came from.
 *
 * Stored as the enum's name so a value written by a newer build is still readable by an older
 * one — the column is text, not an ordinal.
 */
enum class PhotoSource {
    /** Captured by the in-app CameraX screen. */
    CAMERA,

    /** Picked from the system photo picker. */
    GALLERY,

    /** Delivered by an `ACTION_SEND` / `ACTION_SEND_MULTIPLE` intent from another app. */
    SHARE,
}

/**
 * One photo plus the line of text that belongs to it.
 *
 * **The bytes are not in here.** `fileName` points at a file under `filesDir/originals`, which
 * holds exactly what the camera wrote or what the source app handed over. Keeping the original
 * file untouched is what makes 无损导出 possible at all: a re-encoded copy could never be
 * byte-identical to the source, and the whole point of the option is that it is.
 *
 * **`sortIndex` is the user's order, not a timestamp.** It is the only ordering the user can
 * change, and it is a dense 1..n sequence rather than a gap-based scheme because reordering
 * rewrites the whole list anyway — a list of photos is small enough that the simpler invariant
 * ("index equals position") is worth more than fewer writes.
 *
 * **`sha256` is the dedupe key.** Sharing the same image twice, or importing a photo that was
 * already shared in, must not produce two library entries with two independent captions.
 */
@Entity(
    tableName = "photos",
    indices = [
        Index(value = ["sortIndex"]),
        Index(value = ["capturedAt"]),
        Index(value = ["sha256"]),
    ],
)
data class PhotoEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0L,
    /** The user's text. Empty string, never null: "no caption yet" is a state, not a missing value. */
    val caption: String = "",
    /** Name of the file under `filesDir/originals`. App-generated, never user input. */
    val fileName: String,
    /**
     * What the source called it (`IMG_0001.jpg`, or the picker's display name). Used for
     * export file names, and shown in the detail screen. Null when the source had no name.
     */
    val originalName: String? = null,
    val mimeType: String,
    /** 0 when the container could not be decoded; the UI falls back to a square tile. */
    val width: Int,
    val height: Int,
    val sizeBytes: Long,
    val sha256: String,
    /** Epoch millis. EXIF `DateTimeOriginal` when present, otherwise the import time. */
    val capturedAt: Long,
    /** Epoch millis, always "now" at import. What 最近 20 张 sorts on. */
    val addedAt: Long,
    /** [PhotoSource] name. */
    val source: String,
    /** Dense 1..n ordering, rewritten in full on every reorder. */
    val sortIndex: Long,
)

@Dao
interface PhotoDao {

    /**
     * The library, in the user's order.
     *
     * `id ASC` is the tie-breaker so two rows that somehow share a `sortIndex` still come back
     * in a stable order instead of swapping places between reads.
     */
    @Query("SELECT * FROM photos ORDER BY sortIndex ASC, id ASC")
    fun observeAll(): Flow<List<PhotoEntity>>

    @Query("SELECT * FROM photos ORDER BY sortIndex ASC, id ASC")
    suspend fun allOnce(): List<PhotoEntity>

    @Query("SELECT * FROM photos WHERE id = :id LIMIT 1")
    fun observeOne(id: Long): Flow<PhotoEntity?>

    @Query("SELECT * FROM photos WHERE id = :id LIMIT 1")
    suspend fun findOne(id: Long): PhotoEntity?

    @Query("SELECT * FROM photos WHERE sha256 = :sha LIMIT 1")
    suspend fun findByHash(sha: String): PhotoEntity?

    @Insert
    suspend fun insert(row: PhotoEntity): Long

    @Query("UPDATE photos SET caption = :caption WHERE id = :id")
    suspend fun setCaption(id: Long, caption: String)

    @Query("UPDATE photos SET sortIndex = :sortIndex WHERE id = :id")
    suspend fun setSortIndex(id: Long, sortIndex: Long)

    @Query("DELETE FROM photos WHERE id IN (:ids)")
    suspend fun deleteByIds(ids: List<Long>)

    @Query("SELECT COUNT(*) FROM photos")
    fun observeCount(): Flow<Int>

    @Query("SELECT COALESCE(SUM(sizeBytes), 0) FROM photos")
    fun observeTotalBytes(): Flow<Long>

    @Query("SELECT MAX(sortIndex) FROM photos")
    suspend fun maxSortIndex(): Long?
}

@Database(
    entities = [PhotoEntity::class],
    version = 1,
    exportSchema = true,
)
abstract class PhotoLogDatabase : RoomDatabase() {

    abstract fun photoDao(): PhotoDao

    companion object {
        private const val NAME = "photolog.db"

        /**
         * No `fallbackToDestructiveMigration` here, deliberately.
         *
         * In the reading app this database was a regenerable cache and destroying it on an
         * upgrade cost one refresh. Here it is the index into the user's own photos, and the
         * captions live in it: a destructive migration would silently drop every caption and
         * leave the files orphaned. A future version must ship a real `Migration`.
         */
        fun build(context: Context): PhotoLogDatabase =
            Room.databaseBuilder(context.applicationContext, PhotoLogDatabase::class.java, NAME)
                .build()
    }
}
