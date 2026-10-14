// CameraView.kt
// Legacy android.hardware.Camera preview + JPEG frame pump (mirrors the iOS
// CameraStreamer). Uses the old Camera1 API on purpose: it works from API 21
// through modern Android with zero dependencies and is ideal for ancient
// devices being repurposed as security cams.

package com.example.securitycam

import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.Camera
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicLong

class CameraView(context: Context) : SurfaceView(context), SurfaceHolder.Callback {

    fun interface OnFrameListener {
        fun onFrame(jpeg: ByteArray)
    }

    var maxFps: Int = 10                 // throttle like the iOS app
    var jpegQuality: Int = 50            // 0..100, default matches iOS (0.5)

    private var listener: OnFrameListener? = null
    private var camera: Camera? = null
    private var previewActive = false
    private val lastFrameAt = AtomicLong(0L)

    init {
        holder.addCallback(this)
    }

    fun setOnFrameListener(l: OnFrameListener?) { listener = l }

    /** Idempotent start; safe to call from onResume and after permission grant. */
    @Synchronized
    fun start() {
        if (camera != null) return
        camera = try {
            openBackCamera()
        } catch (e: RuntimeException) {
            Log.e("CameraView", "cannot open camera", e)
            null
        }
        val cam = camera ?: return
        configure(cam)
        // If the surface already exists, begin preview immediately.
        if (holder.surface != null && !previewActive) {
            startPreviewSafe(cam)
        }
    }

    @Synchronized
    fun stop() {
        val cam = camera ?: return
        try {
            cam.setOneShotPreviewCallback(null)
            cam.stopPreview()
        } catch (_: RuntimeException) {
        } finally {
            cam.release()
            camera = null
            previewActive = false
        }
    }

    private fun openBackCamera(): Camera {
        val count = Camera.getNumberOfCameras()
        val info = Camera.CameraInfo()
        for (i in 0 until count) {
            Camera.getCameraInfo(i, info)
            if (info.facing == Camera.CameraInfo.CAMERA_FACING_BACK) {
                return Camera.open(i)
            }
        }
        return Camera.open()   // fall back to whatever exists
    }

    private fun configure(cam: Camera) {
        val params = cam.parameters
        // Pick the largest preview size <= 640x480 to keep encoding cheap.
        val best = params.supportedPreviewSizes
            .filter { it.width <= 960 && it.height <= 720 }
            .maxByOrNull { it.width * it.height }
            ?: params.previewSize
        if (best != null) params.setPreviewSize(best.width, best.height)
        params.previewFormat = ImageFormat.NV21     // what we compress to JPEG
        try {
            if (params.supportedFocusModes?.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE) == true) {
                params.focusMode = Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE
            }
        } catch (_: RuntimeException) {
        }
        cam.parameters = params
        cam.setPreviewCallback { data, c -> handleFrame(data, c) }
    }

    private fun startPreviewSafe(cam: Camera) {
        try {
            cam.startPreview()
            previewActive = true
        } catch (e: RuntimeException) {
            Log.e("CameraView", "startPreview failed", e)
        }
    }

    /** NV21 -> JPEG via YuvImage, throttled to maxFps. Runs on the camera thread. */
    private fun handleFrame(nv21: ByteArray?, cam: Camera?) {
        if (nv21 == null || cam == null || !previewActive) return
        val now = System.currentTimeMillis()
        if (now - lastFrameAt.get() < 1000L / maxFps.coerceAtLeast(1)) return
        lastFrameAt.set(now)

        val size = cam.parameters.previewSize ?: return
        try {
            val yuv = YuvImage(nv21, ImageFormat.NV21, size.width, size.height, null)
            val out = ByteArrayOutputStream(size.width * size.height / 4)
            yuv.compressToJpeg(Rect(0, 0, size.width, size.height), jpegQuality, out)
            val jpeg = out.toByteArray()
            if (jpeg.isNotEmpty()) listener?.onFrame(jpeg)
        } catch (e: Exception) {
            Log.w("CameraView", "frame encode failed", e)
        }
    }

    // -- SurfaceHolder.Callback ---------------------------------------------

    override fun surfaceCreated(h: SurfaceHolder) {
        camera?.let { configure(it); startPreviewSafe(it) }
    }

    override fun surfaceChanged(h: SurfaceHolder, format: Int, width: Int, height: Int) {
        val cam = camera ?: return
        try {
            cam.stopPreview()
        } catch (_: RuntimeException) {
        }
        configure(cam)
        startPreviewSafe(cam)
    }

    override fun surfaceDestroyed(h: SurfaceHolder) {
        // Preview must stop before the surface goes away.
        try {
            camera?.stopPreview()
            previewActive = false
        } catch (_: RuntimeException) {
        }
    }
}
