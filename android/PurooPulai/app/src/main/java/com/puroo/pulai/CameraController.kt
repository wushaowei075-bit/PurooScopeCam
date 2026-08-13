package com.puroo.pulai

import android.content.ContentValues
import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureRequest
import android.os.Build
import android.provider.MediaStore
import android.util.Range
import android.util.Rational
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.core.AspectRatio
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.MeteringPoint
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.core.ViewPort
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.MediaStoreOutputOptions
import androidx.camera.video.PendingRecording
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import java.io.File
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

data class CaptureQualityOption(
    val title: String,
    val quality: Quality,
    val frameRate: Int
)

class CameraController(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
    private val previewView: PreviewView,
    private val listener: Listener
) {
    interface Listener {
        fun onCameraReady(maxZoom: Float, activeQuality: CaptureQualityOption)
        fun onPhotoSaved()
        fun onBurstProgress(completed: Int, total: Int)
        fun onRecordingStateChanged(isRecording: Boolean, elapsedNanos: Long)
        fun onError(message: String)
    }

    val qualityOptions = listOf(
        CaptureQualityOption("4K 60 FPS", Quality.UHD, 60),
        CaptureQualityOption("4K 30 FPS", Quality.UHD, 30),
        CaptureQualityOption("1080p 60 FPS", Quality.FHD, 60),
        CaptureQualityOption("1080p 30 FPS", Quality.FHD, 30),
        CaptureQualityOption("720p 60 FPS", Quality.HD, 60),
        CaptureQualityOption("720p 30 FPS", Quality.HD, 30)
    )

    private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var imageCapture: ImageCapture? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var recording: Recording? = null
    private var activeQuality = qualityOptions[2]
    private var stabilizationEnabled = true
    private var displayZoom = 1.5f

    fun start() {
        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener({
            cameraProvider = providerFuture.get()
            bindUseCases()
        }, ContextCompat.getMainExecutor(context))
    }

    fun stop() {
        recording?.stop()
        recording = null
        cameraProvider?.unbindAll()
        cameraExecutor.shutdown()
    }

    fun setQuality(option: CaptureQualityOption) {
        if (recording != null || activeQuality == option) return
        activeQuality = option
        bindUseCases()
    }

    fun setStabilizationEnabled(enabled: Boolean) {
        if (stabilizationEnabled == enabled) return
        stabilizationEnabled = enabled
        if (recording == null) bindUseCases()
    }

    fun setZoom(zoom: Float) {
        displayZoom = zoom.coerceAtLeast(1f)
        camera?.cameraControl?.setZoomRatio(displayZoom)
    }

    fun focus(point: MeteringPoint) {
        val action = FocusMeteringAction.Builder(
            point,
            FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE or FocusMeteringAction.FLAG_AWB
        )
            .setAutoCancelDuration(3, TimeUnit.SECONDS)
            .build()
        camera?.cameraControl?.startFocusAndMetering(action)
    }

    fun setExposure(index: Int) {
        val range = camera?.cameraInfo?.exposureState?.exposureCompensationRange ?: return
        camera?.cameraControl?.setExposureCompensationIndex(index.coerceIn(range.lower, range.upper))
    }

    fun capturePhoto() {
        val capture = imageCapture ?: return
        capture.takePicture(
            imageOutputOptions(),
            ContextCompat.getMainExecutor(context),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                    listener.onPhotoSaved()
                }

                override fun onError(exception: ImageCaptureException) {
                    listener.onError(exception.localizedMessage ?: "拍照失败")
                }
            }
        )
    }

    fun captureBurst(count: Int = 5) {
        captureBurstFrame(index = 0, total = count)
    }

    private fun captureBurstFrame(index: Int, total: Int) {
        if (index >= total) return
        val capture = imageCapture ?: return
        capture.takePicture(
            imageOutputOptions(),
            ContextCompat.getMainExecutor(context),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                    listener.onBurstProgress(index + 1, total)
                    previewView.postDelayed({ captureBurstFrame(index + 1, total) }, 100)
                }

                override fun onError(exception: ImageCaptureException) {
                    listener.onError(exception.localizedMessage ?: "连拍失败")
                }
            }
        )
    }

    fun toggleRecording() {
        val activeRecording = recording
        if (activeRecording != null) {
            activeRecording.stop()
            return
        }
        val capture = videoCapture ?: return
        var pending: PendingRecording = prepareVideoRecording(capture.output)
        if (ContextCompat.checkSelfPermission(context, android.Manifest.permission.RECORD_AUDIO) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            pending = pending.withAudioEnabled()
        }
        recording = pending.start(ContextCompat.getMainExecutor(context)) { event ->
            when (event) {
                is VideoRecordEvent.Start -> listener.onRecordingStateChanged(true, 0)
                is VideoRecordEvent.Status -> listener.onRecordingStateChanged(true, event.recordingStats.recordedDurationNanos)
                is VideoRecordEvent.Finalize -> {
                    recording = null
                    listener.onRecordingStateChanged(false, event.recordingStats.recordedDurationNanos)
                    if (event.hasError()) listener.onError("录像失败：${event.error}")
                }
            }
        }
    }

    @Suppress("UnsafeOptInUsageError")
    private fun bindUseCases() {
        val provider = cameraProvider ?: return
        val selector = CameraSelector.DEFAULT_BACK_CAMERA
        val previewBuilder = Preview.Builder()
            .setTargetAspectRatio(AspectRatio.RATIO_16_9)
        val imageBuilder = ImageCapture.Builder()
            .setTargetAspectRatio(AspectRatio.RATIO_16_9)
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)

        val cameraInfo = try {
            provider.getCameraInfo(selector)
        } catch (_: Throwable) {
            null
        }
        if (cameraInfo != null) {
            val camera2Info = Camera2CameraInfo.from(cameraInfo)
            val availableVideoModes = camera2Info.getCameraCharacteristic(
                CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES
            ) ?: intArrayOf()
            val availableOpticalModes = camera2Info.getCameraCharacteristic(
                CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION
            ) ?: intArrayOf()
            val previewInterop = Camera2Interop.Extender(previewBuilder)
            val imageInterop = Camera2Interop.Extender(imageBuilder)
            val requestedVideoMode = if (
                stabilizationEnabled &&
                availableVideoModes.contains(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON)
            ) CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON
            else CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF
            val requestedOpticalMode = if (
                stabilizationEnabled &&
                requestedVideoMode == CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF &&
                availableOpticalModes.contains(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON)
            ) CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON
            else CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_OFF
            previewInterop.setCaptureRequestOption(
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                requestedVideoMode
            )
            previewInterop.setCaptureRequestOption(
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                requestedOpticalMode
            )
            imageInterop.setCaptureRequestOption(
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                requestedOpticalMode
            )
            previewInterop.setCaptureRequestOption(
                CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                Range(activeQuality.frameRate, activeQuality.frameRate)
            )
        }

        val preview = previewBuilder.build().also {
            it.setSurfaceProvider(previewView.surfaceProvider)
        }
        imageCapture = imageBuilder.build()
        val recorder = Recorder.Builder()
            .setQualitySelector(
                QualitySelector.from(
                    activeQuality.quality,
                    FallbackStrategy.lowerQualityOrHigherThan(activeQuality.quality)
                )
            )
            .build()
        videoCapture = VideoCapture.withOutput(recorder)

        val viewPort = ViewPort.Builder(Rational(9, 16), previewView.display.rotation).build()
        val group = UseCaseGroup.Builder()
            .setViewPort(viewPort)
            .addUseCase(preview)
            .addUseCase(imageCapture!!)
            .addUseCase(videoCapture!!)
            .build()

        try {
            provider.unbindAll()
            camera = provider.bindToLifecycle(lifecycleOwner, selector, group)
            camera?.cameraControl?.setZoomRatio(displayZoom)
            val maxZoom = camera?.cameraInfo?.zoomState?.value?.maxZoomRatio ?: 6f
            listener.onCameraReady(maxZoom, activeQuality)
        } catch (error: Throwable) {
            if (activeQuality.frameRate == 60) {
                val fallback = qualityOptions.firstOrNull {
                    it.quality == activeQuality.quality && it.frameRate == 30
                }
                if (fallback != null) {
                    activeQuality = fallback
                    bindUseCases()
                    return
                }
            }
            listener.onError(error.localizedMessage ?: "无法启动相机")
        }
    }

    private fun imageOutputOptions(): ImageCapture.OutputFileOptions {
        val name = "PUROO_${timestamp()}.jpg"
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
                put(MediaStore.MediaColumns.RELATIVE_PATH, "DCIM/PUROO")
            }
            ImageCapture.OutputFileOptions.Builder(
                context.contentResolver,
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                values
            ).build()
        } else {
            val directory = File(context.getExternalFilesDir(null), "PUROO").apply { mkdirs() }
            ImageCapture.OutputFileOptions.Builder(File(directory, name)).build()
        }
    }

    private fun prepareVideoRecording(output: androidx.camera.video.VideoOutput): PendingRecording {
        val name = "PUROO_${timestamp()}.mp4"
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
                put(MediaStore.MediaColumns.RELATIVE_PATH, "DCIM/PUROO")
            }
            val options = MediaStoreOutputOptions.Builder(
                context.contentResolver,
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            ).setContentValues(values).build()
            output.prepareRecording(context, options)
        } else {
            val directory = File(context.getExternalFilesDir(null), "PUROO").apply { mkdirs() }
            val options = FileOutputOptions.Builder(File(directory, name)).build()
            output.prepareRecording(context, options)
        }
    }

    private fun timestamp(): String = SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US).format(System.currentTimeMillis())
}
