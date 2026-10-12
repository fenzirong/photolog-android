package io.photolog.android.vm

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import io.photolog.android.AppContainer
import io.photolog.android.data.AppSettings
import io.photolog.android.data.PhotoEntity
import io.photolog.android.data.PhotoSource
import io.photolog.android.export.CaptionFormat
import io.photolog.android.export.ExportNaming
import io.photolog.android.export.ExportOptions
import io.photolog.android.export.ExportProgress
import io.photolog.android.export.ExportResult
import io.photolog.android.export.ExportScope
import io.photolog.android.export.toExportOptions
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** How the library list is ordered on screen. Only [MANUAL] can be reordered by hand. */
enum class SortMode(val label: String) {
    MANUAL("手动顺序"),
    CAPTURED("按拍摄时间"),
    ADDED("按导入时间"),
}

/** A just-captured photo, with its file, so the capture screen can show a thumbnail. */
data class CapturedPhoto(val photo: PhotoEntity, val file: File)

/**
 * The library list.
 *
 * Everything here is derived from the database flow rather than cached in the ViewModel: an
 * import, a caption edit or a delete made anywhere in the app is reflected without a reload
 * call, because there is no second copy of the truth to keep in sync.
 */
class GalleryViewModel(private val container: AppContainer) : ViewModel() {

    private val repository = container.repository
    private val _sortMode = MutableStateFlow(SortMode.MANUAL)

    val sortMode: StateFlow<SortMode> = _sortMode.asStateFlow()

    val photos: StateFlow<List<PhotoEntity>> =
        combine(repository.observeAll(), _sortMode) { rows, mode -> sortRows(rows, mode) }
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(SUBSCRIPTION_TIMEOUT), emptyList())

    val count: StateFlow<Int> =
        repository.observeCount()
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(SUBSCRIPTION_TIMEOUT), 0)

    val totalBytes: StateFlow<Long> =
        repository.observeTotalBytes()
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(SUBSCRIPTION_TIMEOUT), 0L)

    val message = container.messages.current

    /**
     * The last-known export defaults, so a single-photo export is named by exactly the same
     * rule as a batch one.
     *
     * `Eagerly` rather than `WhileSubscribed`: this value is read from a click handler, not
     * observed by a screen, and a lazily-started flow would still be sitting on the initial
     * default at the moment the user taps export.
     */
    private val exportDefaults: StateFlow<AppSettings> =
        container.settings.settings.stateIn(viewModelScope, SharingStarted.Eagerly, AppSettings())

    fun setSortMode(mode: SortMode) {
        _sortMode.value = mode
    }

    fun fileFor(photo: PhotoEntity): File = repository.fileFor(photo)

    fun importFromPicker(uris: List<Uri>) {
        viewModelScope.launch {
            container.messages.post(repository.importUris(uris, PhotoSource.GALLERY).describe())
        }
    }

    fun move(id: Long, delta: Int) {
        viewModelScope.launch { repository.move(id, delta) }
    }

    fun delete(ids: List<Long>) {
        viewModelScope.launch {
            repository.delete(ids)
            container.messages.post("已删除 ${ids.size} 张照片")
        }
    }

    fun suggestedExportName(photo: PhotoEntity): String =
        ExportNaming.suggestedName(photo, exportDefaults.value.toExportOptions())

    suspend fun exportSingle(photo: PhotoEntity, target: Uri): ExportResult =
        container.exporter.exportSingle(photo, target, container.settings.snapshot().toExportOptions())

    fun consumeMessage() = container.messages.consume()

    private fun sortRows(rows: List<PhotoEntity>, mode: SortMode): List<PhotoEntity> = when (mode) {
        SortMode.MANUAL -> rows
        SortMode.CAPTURED ->
            rows.sortedWith(compareByDescending<PhotoEntity> { it.capturedAt }.thenByDescending { it.id })

        SortMode.ADDED ->
            rows.sortedWith(compareByDescending<PhotoEntity> { it.addedAt }.thenByDescending { it.id })
    }

    private companion object {
        const val SUBSCRIPTION_TIMEOUT = 5_000L
    }
}

/** The camera tab. Owns the capture file and the row that indexes it. */
class CaptureViewModel(private val container: AppContainer) : ViewModel() {

    private val repository = container.repository
    private val _capturing = MutableStateFlow(false)
    private val _lastSaved = MutableStateFlow<CapturedPhoto?>(null)

    val capturing: StateFlow<Boolean> = _capturing.asStateFlow()

    val lastSaved: StateFlow<CapturedPhoto?> = _lastSaved.asStateFlow()

    val message = container.messages.current

    fun newCaptureFile(): File = repository.newCaptureFile()

    fun onCaptured(file: File) {
        viewModelScope.launch {
            _capturing.value = true
            try {
                val id = repository.registerCapture(file)
                _lastSaved.value = repository.findOne(id)?.let { CapturedPhoto(it, repository.fileFor(it)) }
                container.messages.post("已保存到图库")
            } catch (t: Throwable) {
                container.messages.post("保存失败：${t.message ?: "未知错误"}")
            } finally {
                _capturing.value = false
            }
        }
    }

    fun onCaptureFailed(reason: String?) {
        container.messages.post("拍照失败：${reason ?: "未知错误"}")
    }

    fun clearLastSaved() {
        _lastSaved.value = null
    }

    fun consumeMessage() = container.messages.consume()
}

/** One photo's editor. */
class DetailViewModel(
    private val container: AppContainer,
    private val photoId: Long,
) : ViewModel() {

    private val repository = container.repository

    val photo: StateFlow<PhotoEntity?> = repository.observeOne(photoId)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    val message = container.messages.current

    private val exportDefaults: StateFlow<AppSettings> =
        container.settings.settings.stateIn(viewModelScope, SharingStarted.Eagerly, AppSettings())

    fun fileFor(entity: PhotoEntity): File = repository.fileFor(entity)

    fun saveCaption(caption: String) {
        viewModelScope.launch { repository.setCaption(photoId, caption) }
    }

    fun move(delta: Int) {
        viewModelScope.launch { repository.move(photoId, delta) }
    }

    fun delete(onDeleted: () -> Unit) {
        viewModelScope.launch {
            repository.delete(listOf(photoId))
            container.messages.post("已删除")
            onDeleted()
        }
    }

    fun suggestedExportName(photo: PhotoEntity): String =
        ExportNaming.suggestedName(photo, exportDefaults.value.toExportOptions())

    suspend fun exportSingle(photo: PhotoEntity, target: Uri): ExportResult =
        container.exporter.exportSingle(photo, target, container.settings.snapshot().toExportOptions())

    fun consumeMessage() = container.messages.consume()
}

/** The export tab. */
class ExportViewModel(private val container: AppContainer) : ViewModel() {

    private val repository = container.repository
    private val _progress = MutableStateFlow<ExportProgress?>(null)
    private val _preview = MutableStateFlow<String?>(null)

    val photos: StateFlow<List<PhotoEntity>> =
        repository.observeAll().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val settings: StateFlow<AppSettings> =
        container.settings.settings.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), AppSettings())

    val progress: StateFlow<ExportProgress?> = _progress.asStateFlow()

    val preview: StateFlow<String?> = _preview.asStateFlow()

    val message = container.messages.current

    fun setExportLossless(value: Boolean) {
        viewModelScope.launch { container.settings.setExportLossless(value) }
    }

    fun setExportIncludeCaptions(value: Boolean) {
        viewModelScope.launch { container.settings.setExportIncludeCaptions(value) }
    }

    fun setExportCaptionFormat(format: CaptionFormat) {
        viewModelScope.launch { container.settings.setExportCaptionFormat(format.key) }
    }

    fun setExportNumbered(value: Boolean) {
        viewModelScope.launch { container.settings.setExportNumbered(value) }
    }

    fun setExportNameFromCaption(value: Boolean) {
        viewModelScope.launch { container.settings.setExportNameFromCaption(value) }
    }

    fun setExportJpegQuality(value: Int) {
        viewModelScope.launch { container.settings.setExportJpegQuality(value) }
    }

    fun setExportMaxLongEdge(value: Int) {
        viewModelScope.launch { container.settings.setExportMaxLongEdge(value) }
    }

    fun showPreview(scope: ExportScope, options: ExportOptions) {
        _preview.value = container.exporter.captionPreview(photos.value, scope, options)
    }

    fun dismissPreview() {
        _preview.value = null
    }

    fun exportZip(target: Uri, scope: ExportScope, options: ExportOptions) {
        runExport {
            container.exporter.exportZip(photos.value, target, scope, options) { report(it) }
        }
    }

    fun exportToTree(target: Uri, scope: ExportScope, options: ExportOptions) {
        runExport {
            container.exporter.exportToTree(photos.value, target, scope, options) { report(it) }
        }
    }

    fun exportCaptions(target: Uri, scope: ExportScope, options: ExportOptions) {
        runExport {
            container.exporter.exportCaptionsOnly(photos.value, target, scope, options)
        }
    }

    fun consumeMessage() = container.messages.consume()

    private fun report(progress: ExportProgress) {
        _progress.value = progress
    }

    /**
     * Runs one export and reports it exactly once.
     *
     * The progress state is cleared in a `finally` so a failure mid-export cannot leave the
     * screen permanently showing a progress bar that will never advance.
     */
    private fun runExport(block: suspend () -> ExportResult) {
        viewModelScope.launch {
            _progress.value = ExportProgress(0, 0, "准备中…")
            val result = try {
                block()
            } catch (t: Throwable) {
                ExportResult.Failed(t.message ?: "导出失败")
            } finally {
                _progress.value = null
            }
            container.messages.post(result.describe())
        }
    }
}

/** The settings tab. */
class SettingsViewModel(private val container: AppContainer) : ViewModel() {

    private val repository = container.repository

    val settings: StateFlow<AppSettings> =
        container.settings.settings.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), AppSettings())

    val count: StateFlow<Int> =
        repository.observeCount().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), 0)

    val totalBytes: StateFlow<Long> =
        repository.observeTotalBytes().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), 0L)

    val message = container.messages.current

    fun setThemeMode(mode: String) {
        viewModelScope.launch { container.settings.setThemeMode(mode) }
    }

    fun setExportLossless(value: Boolean) {
        viewModelScope.launch { container.settings.setExportLossless(value) }
    }

    fun setExportIncludeCaptions(value: Boolean) {
        viewModelScope.launch { container.settings.setExportIncludeCaptions(value) }
    }

    fun setExportCaptionFormat(format: CaptionFormat) {
        viewModelScope.launch { container.settings.setExportCaptionFormat(format.key) }
    }

    fun setExportNumbered(value: Boolean) {
        viewModelScope.launch { container.settings.setExportNumbered(value) }
    }

    fun setExportNameFromCaption(value: Boolean) {
        viewModelScope.launch { container.settings.setExportNameFromCaption(value) }
    }

    fun setExportJpegQuality(value: Int) {
        viewModelScope.launch { container.settings.setExportJpegQuality(value) }
    }

    fun setExportMaxLongEdge(value: Int) {
        viewModelScope.launch { container.settings.setExportMaxLongEdge(value) }
    }

    fun sortByCapturedAt() {
        viewModelScope.launch {
            repository.sortByCapturedAt()
            container.messages.post("已按拍摄时间重排")
        }
    }

    fun deleteAll() {
        viewModelScope.launch {
            repository.deleteAll()
            container.messages.post("图库已清空")
        }
    }

    fun consumeMessage() = container.messages.consume()
}

/**
 * Manual ViewModel factory.
 *
 * A DI framework would be a build-time cost and a layer of indirection to construct five
 * ViewModels that take one dependency each.
 */
class PhotoLogViewModelFactory(
    private val container: AppContainer,
    private val photoId: Long = 0L,
) : ViewModelProvider.Factory {

    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        val created: ViewModel = when {
            modelClass.isAssignableFrom(GalleryViewModel::class.java) -> GalleryViewModel(container)
            modelClass.isAssignableFrom(CaptureViewModel::class.java) -> CaptureViewModel(container)
            modelClass.isAssignableFrom(DetailViewModel::class.java) -> DetailViewModel(container, photoId)
            modelClass.isAssignableFrom(ExportViewModel::class.java) -> ExportViewModel(container)
            modelClass.isAssignableFrom(SettingsViewModel::class.java) -> SettingsViewModel(container)
            else -> error("Unknown ViewModel class: ${modelClass.name}")
        }
        return created as T
    }
}
