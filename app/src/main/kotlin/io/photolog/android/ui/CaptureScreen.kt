package io.photolog.android.ui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FlashAuto
import androidx.compose.material.icons.outlined.FlashOff
import androidx.compose.material.icons.outlined.FlashOn
import androidx.compose.material.icons.outlined.FlipCameraAndroid
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import coil.compose.AsyncImage
import io.photolog.android.vm.CaptureViewModel
import io.photolog.android.vm.CapturedPhoto
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * The camera.
 *
 * `ImageCapture` writes straight to a file under the app's own storage, so the JPEG the sensor
 * produced is the file the library holds. That is what makes 无损导出 meaningful later: there
 * is no intermediate bitmap anywhere in the capture path that could have thrown information
 * away before the photo ever reached the library.
 *
 * Capture is bound to the composition's lifecycle, so leaving the tab releases the camera
 * instead of holding it against other apps.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CaptureScreen(
    viewModel: CaptureViewModel,
    navController: NavHostController,
    onOpenPhoto: (Long) -> Unit,
) {
    val context = LocalContext.current
    val message by viewModel.message.collectAsStateWithLifecycle()
    val capturing by viewModel.capturing.collectAsStateWithLifecycle()
    val lastSaved by viewModel.lastSaved.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }

    var granted by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED,
        )
    }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { allowed -> granted = allowed }

    var lensFacing by remember { mutableStateOf(CameraSelector.LENS_FACING_BACK) }
    var flashMode by remember { mutableStateOf(ImageCapture.FLASH_MODE_AUTO) }
    var imageCapture by remember { mutableStateOf<ImageCapture?>(null) }
    var cameraError by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        if (!granted) permissionLauncher.launch(Manifest.permission.CAMERA)
    }

    LaunchedEffect(message) {
        message?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.consumeMessage()
        }
    }

    // The flash setting can be changed between shots; CameraX applies it to the next capture.
    LaunchedEffect(flashMode, imageCapture) {
        runCatching { imageCapture?.flashMode = flashMode }
    }

    fun shutter() {
        val capture = imageCapture ?: return
        if (capturing) return
        val file = viewModel.newCaptureFile()
        val options = ImageCapture.OutputFileOptions.Builder(file).build()
        capture.takePicture(
            options,
            ContextCompat.getMainExecutor(context),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                    viewModel.onCaptured(file)
                }

                override fun onError(exception: ImageCaptureException) {
                    viewModel.onCaptureFailed(exception.message)
                }
            },
        )
    }

    Scaffold(
        topBar = { TopAppBar(title = { Text("拍照") }) },
        bottomBar = { PhotoLogBottomBar(navController) },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize(),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .background(Color.Black),
                contentAlignment = Alignment.Center,
            ) {
                when {
                    !granted -> CameraPermissionPrompt(
                        onRequest = { permissionLauncher.launch(Manifest.permission.CAMERA) },
                    )

                    cameraError != null -> CameraMessage(
                        text = cameraError.orEmpty(),
                        onRetry = {
                            cameraError = null
                            imageCapture = null
                        },
                    )

                    else -> CameraPreview(
                        lensFacing = lensFacing,
                        onReady = { capture -> imageCapture = capture },
                        onError = { reason -> cameraError = reason },
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }

            Surface(tonalElevation = 3.dp) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    lastSaved?.let { saved ->
                        LastSavedRow(
                            captured = saved,
                            onOpen = {
                                viewModel.clearLastSaved()
                                onOpenPhoto(saved.photo.id)
                            },
                            onDismiss = { viewModel.clearLastSaved() },
                        )
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        IconButton(
                            onClick = { flashMode = nextFlashMode(flashMode) },
                            enabled = granted && imageCapture != null,
                        ) {
                            Icon(
                                imageVector = flashIcon(flashMode),
                                contentDescription = flashLabel(flashMode),
                            )
                        }

                        ShutterButton(
                            enabled = granted && imageCapture != null && !capturing,
                            busy = capturing,
                            onClick = { shutter() },
                        )

                        IconButton(
                            onClick = {
                                lensFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK) {
                                    CameraSelector.LENS_FACING_FRONT
                                } else {
                                    CameraSelector.LENS_FACING_BACK
                                }
                            },
                            enabled = granted,
                        ) {
                            Icon(Icons.Outlined.FlipCameraAndroid, contentDescription = "切换前后摄像头")
                        }
                    }

                    Text(
                        text = "照片按原样保存，不做二次压缩。拍完在图库里给它写一行文字说明，" +
                            "导出时可以按顺序连着说明一起带走。",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

/**
 * The live preview.
 *
 * The `PreviewView` is remembered rather than recreated so a lens switch rebinds the use cases
 * on the same surface instead of tearing down the whole view hierarchy.
 */
@Composable
private fun CameraPreview(
    lensFacing: Int,
    onReady: (ImageCapture?) -> Unit,
    onError: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val previewView = remember {
        PreviewView(context).apply {
            scaleType = PreviewView.ScaleType.FILL_CENTER
            // COMPATIBLE renders through a TextureView, which is the mode that works on the
            // widest range of devices; PERFORMANCE (SurfaceView) has black-frame bugs on some
            // older drivers when the view is animated or clipped.
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        }
    }

    LaunchedEffect(lensFacing) {
        val provider = context.awaitCameraProvider()
        if (provider == null) {
            onReady(null)
            onError("无法访问相机硬件")
            return@LaunchedEffect
        }

        val selector = if (lensFacing == CameraSelector.LENS_FACING_FRONT) {
            CameraSelector.DEFAULT_FRONT_CAMERA
        } else {
            CameraSelector.DEFAULT_BACK_CAMERA
        }
        if (!provider.hasCamera(selector)) {
            onReady(null)
            onError("这台设备上没有可用的摄像头")
            return@LaunchedEffect
        }

        val preview = Preview.Builder().build().also { it.surfaceProvider = previewView.surfaceProvider }
        val capture = ImageCapture.Builder()
            // Maximize quality rather than latency: this app is not shooting bursts, and the
            // higher-quality mode is what gives the best JPEG the sensor can produce — which is
            // the file the library then promises to export untouched.
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
            .build()

        try {
            // Rebinding without this throws "Use case already bound" on the second lens switch.
            provider.unbindAll()
            provider.bindToLifecycle(lifecycleOwner, selector, preview, capture)
            onReady(capture)
        } catch (t: Throwable) {
            onReady(null)
            onError(t.message ?: "相机启动失败")
        }
    }

    AndroidView(factory = { previewView }, modifier = modifier)
}

@Composable
private fun ShutterButton(enabled: Boolean, busy: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(72.dp)
            .clip(CircleShape)
            .background(
                if (enabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant,
            )
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        if (busy) {
            CircularProgressIndicator(
                modifier = Modifier.size(26.dp),
                strokeWidth = 3.dp,
                color = MaterialTheme.colorScheme.onPrimary,
            )
        } else {
            Icon(
                imageVector = Icons.Outlined.PhotoCamera,
                contentDescription = "拍照",
                tint = if (enabled) {
                    MaterialTheme.colorScheme.onPrimary
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
            )
        }
    }
}

@Composable
private fun LastSavedRow(
    captured: CapturedPhoto,
    onOpen: () -> Unit,
    onDismiss: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AsyncImage(
            model = captured.file,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(48.dp)
                .clip(RoundedCornerShape(8.dp)),
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text("已保存到图库", style = MaterialTheme.typography.bodyMedium)
            Text(
                text = "给它写一行文字说明",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        TextButton(onClick = onOpen) { Text("写说明") }
        TextButton(onClick = onDismiss) { Text("知道了") }
    }
}

@Composable
private fun CameraPermissionPrompt(onRequest: () -> Unit) {
    Column(
        modifier = Modifier.padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = "需要相机权限才能拍照",
            style = MaterialTheme.typography.titleMedium,
            color = Color.White,
        )
        Text(
            text = "不授权也可以继续用图库导入和「分享到图志」。",
            style = MaterialTheme.typography.bodySmall,
            color = Color.White.copy(alpha = 0.75f),
        )
        TextButton(onClick = onRequest) { Text("授予权限") }
    }
}

@Composable
private fun CameraMessage(text: String, onRetry: () -> Unit) {
    Column(
        modifier = Modifier.padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(text = text, style = MaterialTheme.typography.titleMedium, color = Color.White)
        TextButton(onClick = onRetry) { Text("重试") }
    }
}

// --------------------------------------------------------------------------- //
// Camera helpers
// --------------------------------------------------------------------------- //

/**
 * Awaits CameraX's process-wide provider.
 *
 * `getInstance` hands back a `ListenableFuture`, and awaiting it here rather than adding
 * `kotlinx-coroutines-guava` keeps the dependency list to what the app actually uses.
 */
private suspend fun Context.awaitCameraProvider(): ProcessCameraProvider? =
    suspendCancellableCoroutine { continuation ->
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener(
            {
                if (continuation.isActive) {
                    val provider = try {
                        future.get()
                    } catch (t: Throwable) {
                        null
                    }
                    continuation.resume(provider)
                }
            },
            ContextCompat.getMainExecutor(this),
        )
    }

private fun nextFlashMode(current: Int): Int = when (current) {
    ImageCapture.FLASH_MODE_AUTO -> ImageCapture.FLASH_MODE_ON
    ImageCapture.FLASH_MODE_ON -> ImageCapture.FLASH_MODE_OFF
    else -> ImageCapture.FLASH_MODE_AUTO
}

private fun flashIcon(mode: Int) = when (mode) {
    ImageCapture.FLASH_MODE_ON -> Icons.Outlined.FlashOn
    ImageCapture.FLASH_MODE_OFF -> Icons.Outlined.FlashOff
    else -> Icons.Outlined.FlashAuto
}

private fun flashLabel(mode: Int): String = when (mode) {
    ImageCapture.FLASH_MODE_ON -> "闪光灯：开"
    ImageCapture.FLASH_MODE_OFF -> "闪光灯：关"
    else -> "闪光灯：自动"
}
