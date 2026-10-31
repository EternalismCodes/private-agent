package com.orailnoor.privateagent

import android.content.ContentValues
import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.Image
import android.media.ImageReader
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.HandlerThread
import android.provider.MediaStore
import java.io.File
import java.io.FileOutputStream

/**
 * Takes a photo without any camera-app UI, and therefore with nothing for a
 * user to tap: ACTION_IMAGE_CAPTURE (the previous approach) hands control to
 * whatever camera app is installed and Android deliberately gives no way to
 * confirm its shutter via an intent extra — that confirmation step is an
 * intentional privacy boundary of that API, not a bug to work around by
 * finding the right extra. Driving Camera2 directly is the actual way to get
 * a real, silent capture, and — as a side benefit — it doesn't require
 * bringing the app to the foreground at all, so it also works from a
 * scheduled task running in the background.
 */
object SilentCameraCapture {
    /**
     * [front]: true takes a selfie with the front-facing camera, false (the
     * default) uses the back camera — same silent Camera2 path either way.
     */
    fun capture(context: Context, front: Boolean = false, onResult: (String?) -> Unit) {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val thread = HandlerThread("SilentCameraCapture").apply { start() }
        val handler = Handler(thread.looper)
        var device: CameraDevice? = null
        var finished = false

        fun finish(path: String?) {
            if (finished) return
            finished = true
            try { device?.close() } catch (_: Exception) {}
            onResult(path)
            handler.postDelayed({ thread.quitSafely() }, 200)
        }

        try {
            val wantedFacing = if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
            val cameraId = manager.cameraIdList.firstOrNull {
                manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == wantedFacing
            } ?: manager.cameraIdList.firstOrNull {
                manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
            } ?: manager.cameraIdList.firstOrNull()
            if (cameraId == null) {
                finish(null)
                return
            }
            val chars = manager.getCameraCharacteristics(cameraId)
            val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val sizes = map?.getOutputSizes(ImageFormat.JPEG)
            val size = sizes?.maxByOrNull { it.width.toLong() * it.height } ?: android.util.Size(1280, 720)
            val sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90

            val reader = ImageReader.newInstance(size.width, size.height, ImageFormat.JPEG, 2)
            reader.setOnImageAvailableListener({ r ->
                var image: Image? = null
                try {
                    image = r.acquireLatestImage()
                    if (image != null) {
                        val buffer = image.planes[0].buffer
                        val bytes = ByteArray(buffer.remaining())
                        buffer.get(bytes)
                        val saved = saveToPictures(context, bytes)
                        finish(saved)
                    } else {
                        finish(null)
                    }
                } catch (_: Exception) {
                    finish(null)
                } finally {
                    image?.close()
                }
            }, handler)

            manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(cam: CameraDevice) {
                    device = cam
                    try {
                        val builder = cam.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE)
                        builder.addTarget(reader.surface)
                        builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                        builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                        builder.set(CaptureRequest.JPEG_ORIENTATION, sensorOrientation)

                        cam.createCaptureSession(
                            listOf(reader.surface),
                            object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(session: CameraCaptureSession) {
                                    // Brief settle time for auto-exposure/focus before the real capture.
                                    handler.postDelayed({
                                        try {
                                            session.capture(builder.build(), null, handler)
                                        } catch (_: Exception) {
                                            finish(null)
                                        }
                                    }, 400)
                                }

                                override fun onConfigureFailed(session: CameraCaptureSession) {
                                    finish(null)
                                }
                            },
                            handler,
                        )
                    } catch (_: Exception) {
                        finish(null)
                    }
                }

                override fun onDisconnected(cam: CameraDevice) {
                    device = cam
                    finish(null)
                }

                override fun onError(cam: CameraDevice, error: Int) {
                    device = cam
                    finish(null)
                }
            }, handler)
        } catch (_: Exception) {
            finish(null)
        }
    }

    /**
     * Saves into the public Pictures/PrivateAgent folder — visible in the
     * gallery and Files app, not buried in app-private storage. Uses
     * MediaStore on Android 10+ (the scoped-storage-compliant way to write
     * into a shared folder without broad storage permission); falls back to
     * a direct file write for the older API levels this app still supports.
     */
    private fun saveToPictures(context: Context, bytes: ByteArray): String? {
        val name = "IMG_${System.currentTimeMillis()}.jpg"
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, name)
                    put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                    put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/PrivateAgent")
                }
                val uri = context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                    ?: return null
                context.contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                "Pictures/PrivateAgent/$name"
            } else {
                @Suppress("DEPRECATION")
                val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "PrivateAgent")
                dir.mkdirs()
                val file = File(dir, name)
                FileOutputStream(file).use { it.write(bytes) }
                MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), arrayOf("image/jpeg"), null)
                file.absolutePath
            }
        } catch (_: Exception) {
            null
        }
    }
}
