package com.puroo.pulai

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.media.MediaActionSound
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.view.MotionEvent
import android.view.View
import android.view.animation.DecelerateInterpolator
import android.widget.SeekBar
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.MeteringPoint
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import com.puroo.pulai.databinding.ActivityMainBinding
import java.util.Locale
import kotlin.math.min

class MainActivity : AppCompatActivity(), CameraController.Listener {
    private lateinit var binding: ActivityMainBinding
    private lateinit var cameraController: CameraController
    private lateinit var gyroStabilizer: GyroStabilizer
    private val mainHandler = Handler(Looper.getMainLooper())
    private val shutterSound = MediaActionSound()
    private var captureMode = CaptureMode.PHOTO
    private var selectedMagnification = 10
    private var maxZoom = 6f
    private var focusDismiss: Runnable? = null
    private var isRecording = false

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { result ->
        if (result[Manifest.permission.CAMERA] == true) {
            startCamera()
        } else {
            Toast.makeText(this, "需要相机权限才能拍摄", Toast.LENGTH_LONG).show()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, true)
        window.statusBarColor = Color.BLACK
        window.navigationBarColor = Color.BLACK
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        cameraController = CameraController(this, this, binding.previewView, this)
        gyroStabilizer = GyroStabilizer(this) { x, y, roll ->
            runOnUiThread { applyGyroCorrection(x, y, roll) }
        }
        configureControls()
        requestPermissionsOrStart()
        startOverviewUpdates()
    }

    override fun onResume() {
        super.onResume()
        gyroStabilizer.start()
    }

    override fun onPause() {
        gyroStabilizer.stop()
        super.onPause()
    }

    override fun onDestroy() {
        mainHandler.removeCallbacksAndMessages(null)
        shutterSound.release()
        cameraController.stop()
        super.onDestroy()
    }

    private fun requestPermissionsOrStart() {
        val permissions = buildList {
            add(Manifest.permission.CAMERA)
            add(Manifest.permission.RECORD_AUDIO)
            if (android.os.Build.VERSION.SDK_INT <= 28) add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        }.toTypedArray()
        val missing = permissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) startCamera() else permissionLauncher.launch(missing.toTypedArray())
    }

    private fun startCamera() {
        binding.previewView.post { cameraController.start() }
    }

    private fun configureControls() {
        binding.stabilitySwitch.isChecked = true
        binding.stabilitySwitch.setOnCheckedChangeListener { _, checked ->
            gyroStabilizer.isEnabled = checked
            cameraController.setStabilizationEnabled(checked)
            binding.overviewContainer.visibility = if (checked) View.VISIBLE else View.GONE
            if (!checked) resetPreviewTransform()
        }

        binding.qualityButton.setOnClickListener { showQualityDialog() }
        binding.magnificationButton.setOnClickListener { showMagnificationDialog() }
        binding.photoModeButton.setOnClickListener { selectMode(CaptureMode.PHOTO) }
        binding.videoModeButton.setOnClickListener { selectMode(CaptureMode.VIDEO) }
        binding.shutterButton.setOnClickListener { handleShutter() }
        binding.burstButton.setOnClickListener {
            if (!isRecording) {
                shutterSound.play(MediaActionSound.SHUTTER_CLICK)
                cameraController.captureBurst()
            }
        }
        binding.albumButton.setOnClickListener { openAlbum() }
        binding.previewView.setOnTouchListener { _, event -> handlePreviewTouch(event) }

        binding.zoomBar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                val zoom = 1f + progress / 1000f * (min(maxZoom, 6f) - 1f)
                cameraController.setZoom(zoom)
                binding.zoomLabel.text = String.format(Locale.US, "%.1f×", zoom)
            }

            override fun onStartTrackingTouch(seekBar: SeekBar?) {
                binding.zoomControl.animate().scaleX(1.12f).scaleY(1.12f).setDuration(150).start()
            }

            override fun onStopTrackingTouch(seekBar: SeekBar?) {
                binding.zoomControl.animate().scaleX(1f).scaleY(1f).setDuration(180).start()
            }
        })

        binding.exposureBar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                if (fromUser) cameraController.setExposure(progress - 6)
            }
            override fun onStartTrackingTouch(seekBar: SeekBar?) = Unit
            override fun onStopTrackingTouch(seekBar: SeekBar?) = scheduleFocusDismiss()
        })
    }

    private fun selectMode(mode: CaptureMode) {
        if (isRecording || captureMode == mode) return
        captureMode = mode
        val photoSelected = mode == CaptureMode.PHOTO
        binding.photoModeButton.setBackgroundResource(if (photoSelected) R.drawable.mode_selected else android.R.color.transparent)
        binding.videoModeButton.setBackgroundResource(if (photoSelected) android.R.color.transparent else R.drawable.mode_selected)
        binding.photoModeButton.setTextColor(if (photoSelected) getColor(R.color.puroo_yellow) else Color.WHITE)
        binding.videoModeButton.setTextColor(if (photoSelected) Color.WHITE else getColor(R.color.puroo_yellow))
        binding.shutterButton.setBackgroundResource(
            if (photoSelected) R.drawable.shutter_photo else R.drawable.shutter_video
        )
        binding.burstButton.alpha = if (photoSelected) 1f else 0.45f
        binding.shutterButton.animate()
            .scaleX(0.88f)
            .scaleY(0.88f)
            .setDuration(90)
            .withEndAction {
                binding.shutterButton.animate()
                    .scaleX(1f)
                    .scaleY(1f)
                    .setInterpolator(DecelerateInterpolator())
                    .setDuration(180)
                    .start()
            }
            .start()
    }

    private fun handleShutter() {
        when (captureMode) {
            CaptureMode.PHOTO -> {
                shutterSound.play(MediaActionSound.SHUTTER_CLICK)
                cameraController.capturePhoto()
            }
            CaptureMode.VIDEO -> cameraController.toggleRecording()
        }
    }

    private fun showQualityDialog() {
        val options = cameraController.qualityOptions
        AlertDialog.Builder(this)
            .setTitle(R.string.quality)
            .setItems(options.map { it.title }.toTypedArray()) { _, index ->
                cameraController.setQuality(options[index])
                binding.qualityButton.text = options[index].title.replaceFirst(" ", "\n")
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun showMagnificationDialog() {
        val values = intArrayOf(8, 10, 12, 15, 20, 30, 40, 60)
        AlertDialog.Builder(this)
            .setTitle(R.string.magnification)
            .setSingleChoiceItems(values.map { "$it×" }.toTypedArray(), values.indexOf(selectedMagnification)) { dialog, index ->
                selectedMagnification = values[index]
                binding.magnificationButton.text = "${values[index]}×"
                dialog.dismiss()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun handlePreviewTouch(event: MotionEvent): Boolean {
        if (event.action != MotionEvent.ACTION_UP) return true
        val point: MeteringPoint = binding.previewView.meteringPointFactory.createPoint(event.x, event.y)
        cameraController.focus(point)
        val half = binding.focusFrame.width.takeIf { it > 0 }?.div(2f) ?: 35f * resources.displayMetrics.density
        binding.focusFrame.x = (event.x - half).coerceIn(0f, binding.previewView.width - half * 2)
        binding.focusFrame.y = (event.y - half).coerceIn(0f, binding.previewView.height - half * 2)
        binding.focusFrame.visibility = View.VISIBLE
        binding.focusFrame.alpha = 0f
        binding.focusFrame.scaleX = 1.28f
        binding.focusFrame.scaleY = 1.28f
        binding.focusFrame.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(180).start()
        binding.exposureBar.x = (binding.focusFrame.x + half * 2 + 8f).coerceAtMost(binding.previewView.width - binding.exposureBar.width.toFloat())
        binding.exposureBar.y = (binding.focusFrame.y - 20f).coerceAtLeast(0f)
        binding.exposureBar.visibility = View.VISIBLE
        scheduleFocusDismiss()
        return true
    }

    private fun scheduleFocusDismiss() {
        focusDismiss?.let(mainHandler::removeCallbacks)
        focusDismiss = Runnable {
            binding.focusFrame.animate().alpha(0f).setDuration(180).withEndAction {
                binding.focusFrame.visibility = View.GONE
                binding.exposureBar.visibility = View.GONE
            }.start()
        }.also { mainHandler.postDelayed(it, 3200) }
    }

    private fun openAlbum() {
        val intent = Intent(Intent.ACTION_VIEW).apply {
            type = "image/*"
            data = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            flags = Intent.FLAG_GRANT_READ_URI_PERMISSION
        }
        runCatching { startActivity(intent) }.onFailure {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("content://media/external/images/media")))
        }
    }

    private fun applyGyroCorrection(x: Float, y: Float, roll: Float) {
        if (!binding.stabilitySwitch.isChecked) return
        val scale = 1.08f
        binding.previewView.pivotX = binding.previewContainer.width * 0.5f
        binding.previewView.pivotY = binding.previewContainer.height * 0.5f
        binding.previewView.scaleX = scale
        binding.previewView.scaleY = scale
        binding.previewView.translationX = x * binding.previewContainer.width
        binding.previewView.translationY = y * binding.previewContainer.height
        binding.previewView.rotation = roll
        binding.cropOverlay.updateCorrection(x, y, scale)
    }

    private fun resetPreviewTransform() {
        binding.previewView.animate()
            .translationX(0f)
            .translationY(0f)
            .rotation(0f)
            .scaleX(1f)
            .scaleY(1f)
            .setDuration(180)
            .start()
        binding.cropOverlay.updateCorrection(0f, 0f, 1.001f)
    }

    private fun startOverviewUpdates() {
        val update = object : Runnable {
            override fun run() {
                if (!isFinishing && binding.overviewContainer.visibility == View.VISIBLE) {
                    binding.previewView.bitmap?.let(binding.overviewImage::setImageBitmap)
                }
                mainHandler.postDelayed(this, 250)
            }
        }
        mainHandler.post(update)
    }

    override fun onCameraReady(maxZoom: Float, activeQuality: CaptureQualityOption) {
        this.maxZoom = maxZoom
        binding.qualityButton.text = activeQuality.title.replaceFirst(" ", "\n")
        val initialProgress = (((1.5f - 1f) / (min(maxZoom, 6f) - 1f).coerceAtLeast(0.1f)) * 1000).toInt()
        binding.zoomBar.progress = initialProgress.coerceIn(0, 1000)
    }

    override fun onPhotoSaved() {
        Toast.makeText(this, "照片已保存", Toast.LENGTH_SHORT).show()
    }

    override fun onBurstProgress(completed: Int, total: Int) {
        if (completed == total) Toast.makeText(this, "已完成 $total 张连拍", Toast.LENGTH_SHORT).show()
    }

    override fun onRecordingStateChanged(isRecording: Boolean, elapsedNanos: Long) {
        this.isRecording = isRecording
        if (isRecording) {
            binding.shutterButton.setBackgroundResource(R.drawable.shutter_recording)
            val seconds = elapsedNanos / 1_000_000_000L
            binding.recordingStatus.text = String.format(Locale.US, "录制中 %02d:%02d", seconds / 60, seconds % 60)
            binding.photoModeButton.isEnabled = false
            binding.burstButton.isEnabled = false
        } else {
            binding.shutterButton.setBackgroundResource(R.drawable.shutter_video)
            binding.recordingStatus.text = ""
            binding.photoModeButton.isEnabled = true
            binding.burstButton.isEnabled = true
        }
    }

    override fun onError(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
    }

    private enum class CaptureMode {
        PHOTO,
        VIDEO
    }
}
