// MainActivity.kt
// Entry point: requests CAMERA permission, then starts the camera capture and
// the embedded HTTP server. Written in Kotlin for Android 5.0+ (API 21) using
// only framework APIs — no third-party dependencies.

package com.example.securitycam

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.text.SpannableString
import android.text.style.ForegroundColorSpan
import android.view.Gravity
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : AppCompatActivity() {

    private lateinit var cameraView: CameraView
    private val server = HttpStreamServer(port = 8080)

    private companion object {
        const val REQUEST_CAMERA = 1
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Keep the screen (and therefore the stream) alive while plugged in.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        cameraView = CameraView(this)

        val status = TextView(this).apply {
            setTextColor(Color.rgb(102, 255, 153))          // green terminal look
            textSize = 14f
            typeface = android.graphics.Typeface.MONOSPACE
            setBackgroundColor(0x99000000.toInt())          // translucent black bar
            gravity = Gravity.CENTER
            text = "Requesting camera permission…"
        }

        setContentView(FrameLayout(this).apply {
            addView(cameraView, FrameLayout.LayoutParams(-1, -1))
            addView(status, FrameLayout.LayoutParams(-1, wrapStatusHeight()).apply {
                gravity = Gravity.BOTTOM
            })
        })

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), REQUEST_CAMERA)
        } else {
            startCameraAndServer(status)
        }
    }

    private fun wrapStatusHeight() = WindowManager.LayoutParams.WRAP_CONTENT

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val status = (cameraView.parent as? FrameLayout)?.let { layout ->
            (0 until layout.childCount).map(layout.getChildAt)
                .filterIsInstance<TextView>().firstOrNull()
        } ?: return

        if (requestCode == REQUEST_CAMERA &&
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        ) {
            startCameraAndServer(status)
        } else {
            showRed(status, "Camera permission denied. Grant it in Settings > Apps > SecurityCam.")
        }
    }

    private fun startCameraAndServer(status: TextView) {
        cameraView.setOnFrameListener { jpeg -> server.publish(jpeg) }
        cameraView.start()
        try {
            server.start()
        } catch (e: Exception) {
            showRed(status, "Could not bind port 8080: ${e.message}")
            return
        }
        val ip = localIPAddress()
        val url = if (ip != null) "● LIVE\nhttp://$ip:8080/stream"
                  else "● LIVE (no network address found)"
        status.text = url
    }

    private fun showRed(status: TextView, message: String) {
        val span = SpannableString("✕ $message")
        span.setSpan(ForegroundColorSpan(Color.rgb(255, 90, 80)), 0, span.length, 0)
        status.text = span
    }

    override fun onResume() {
        super.onResume()
        cameraView.start()
    }

    override fun onPause() {
        super.onPause()
        cameraView.stop()
    }

    override fun onDestroy() {
        super.onDestroy()
        server.stop()
    }

    /** IPv4 of Wi-Fi (wlan0) preferred, falling back to any non-loopback IPv4. */
    private fun localIPAddress(): String? {
        var fallback: String? = null
        try {
            for (intf in NetworkInterface.getNetworkInterfaces()) {
                if (!intf.isUp || intf.isLoopback) continue
                for (addr in intf.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        val host = addr.hostAddress ?: continue
                        if (intf.name == "wlan0") return host
                        if (fallback == null) fallback = host
                    }
                }
            }
        } catch (_: Exception) {
            return null
        }
        return fallback
    }
}
