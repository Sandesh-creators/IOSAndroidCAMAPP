// HttpStreamServer.kt
// Tiny hand-rolled HTTP server (java.net.ServerSocket) that mirrors the iOS
// HTTPStreamServer: /stream MJPEG, /snapshot single JPEG, / status page.
// Frames arrive via publish() from the camera callback thread.

package com.example.securitycam

import android.util.Log
import java.io.IOException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import java.util.concurrent.Executors

class HttpStreamServer(private val port: Int = 8080) {

    private val boundary = "frame"
    private var serverSocket: ServerSocket? = null
    @Volatile private var running = false

    @Volatile private var latestJpeg: ByteArray? = null

    /** Sockets currently attached to /stream; dead ones are reaped in publish(). */
    private val clients: MutableList<Socket> = Collections.synchronizedList(mutableListOf())
    private val executor = Executors.newCachedThreadPool()

    // -- lifecycle ------------------------------------------------------------

    @Synchronized
    fun start() {
        if (running) return
        val ss = ServerSocket()
        // SO_REUSEADDR before bind so a quick app restart does not EADDRINUSE.
        ss.reuseAddress = true
        ss.bind(InetSocketAddress(port))
        serverSocket = ss
        running = true
        executor.execute { acceptLoop(ss) }
        Log.i("HttpStreamServer", "listening on $port")
    }

    @Synchronized
    fun stop() {
        running = false
        try { serverSocket?.close() } catch (_: IOException) {}
        serverSocket = null
        synchronized(clients) { clients.forEach { runCatching { it.close() } }; clients.clear() }
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (running) {
            val socket = try {
                ss.accept()
            } catch (e: IOException) {
                if (running) Log.w("HttpStreamServer", "accept failed", e)
                break                       // socket closed => shutting down
            }
            executor.execute { handleConnection(socket) }
        }
    }

    // -- frame publishing -------------------------------------------------------

    /** Call from the camera thread with each encoded JPEG frame. */
    fun publish(jpeg: ByteArray) {
        latestJpeg = jpeg
        val dead = mutableListOf<Socket>()
        // Snapshot the client list so we never hold the lock across blocking I/O.
        val snapshot = synchronized(clients) { clients.toList() }
        for (s in snapshot) {
            val out = try { s.getOutputStream() } catch (e: IOException) { dead.add(s); continue }
            if (!writeMultipartFrame(out, jpeg)) dead.add(s)
        }
        if (dead.isNotEmpty()) {
            synchronized(clients) { clients.removeAll(dead.toSet()) }
            dead.forEach { runCatching { it.close() } }
        }
    }

    // -- connection handling ------------------------------------------------------

    private fun handleConnection(socket: Socket) {
        try {
            socket.tcpNoDelay = true
            val input = socket.getInputStream()

            // Read the request line: loop until we consume a full "\r\n" line.
            val sb = StringBuilder()
            var prev = -1
            while (true) {
                val b = input.read()
                if (b == -1) return
                sb.append(b.toChar())
                if (prev == '\r'.code && b == '\n'.code) break
                prev = b
                if (sb.length > 2048) break   // refuse absurd request lines
            }

            val parts = sb.toString().trim().split(" ")
            val method = parts.getOrElse(0) { "GET" }
            val path = parts.getOrElse(1) { "/" }

            if (method != "GET") {
                respondSimple(socket.getOutputStream(), "405 Method Not Allowed",
                    "text/plain", "Method not allowed\n".toByteArray())
                runCatching { socket.close() }
                return
            }

            when (path) {
                "/stream" -> serveStream(socket)               // socket stays open
                "/snapshot" -> {
                    val jpeg = latestJpeg
                    if (jpeg != null) {
                        respondSimple(socket.getOutputStream(), "200 OK", "image/jpeg", jpeg)
                    } else {
                        respondSimple(socket.getOutputStream(), "503 Service Unavailable",
                            "text/plain", "No frame yet\n".toByteArray())
                    }
                    runCatching { socket.close() }
                }
                "/" -> {
                    val text = buildString {
                        append("SecurityCam Android streamer\n")
                        append("---------------------------\n")
                        append("Status:   RUNNING\n")
                        append("Stream:   /stream  (multipart/x-mixed-replace MJPEG)\n")
                        append("Snapshot: /snapshot (single JPEG)\n")
                        append("Clients:  ${clients.size} watching /stream\n")
                        append("Frames:   ${if (latestJpeg != null) "publishing" else "none yet"}\n")
                    }
                    respondSimple(socket.getOutputStream(), "200 OK",
                        "text/plain; charset=utf-8", text.toByteArray())
                    runCatching { socket.close() }
                }
                else -> {
                    respondSimple(socket.getOutputStream(), "404 Not Found",
                        "text/plain", "Not found. Try /stream, /snapshot or /\n".toByteArray())
                    runCatching { socket.close() }
                }
            }
        } catch (e: IOException) {
            // Client vanished mid-request — normal for streaming sockets.
            runCatching { socket.close() }
        }
    }

    /** Write multipart headers once, then keep the socket registered for frames. */
    private fun serveStream(socket: Socket) {
        val out = socket.getOutputStream()
        val headers = buildString {
            append("HTTP/1.1 200 OK\r\n")
            append("Content-Type: multipart/x-mixed-replace; boundary=$boundary\r\n")
            append("Cache-Control: no-store, no-cache, must-revalidate\r\n")
            append("Connection: close\r\n")
            append("\r\n")
        }.toByteArray()
        if (!writeAll(out, headers)) {
            runCatching { socket.close() }
            return
        }
        // Send the current frame immediately so new viewers see video at once.
        latestJpeg?.let { writeMultipartFrame(out, it) }
        clients.add(socket)
    }

    // -- helpers ------------------------------------------------------------------

    /** One MIME part = boundary + per-part headers + JPEG + CRLF. */
    private fun writeMultipartFrame(out: OutputStream, jpeg: ByteArray): Boolean {
        val head = "--$boundary\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpeg.size}\r\n\r\n"
            .toByteArray()
        if (!writeAll(out, head)) return false
        if (!writeAll(out, jpeg)) return false
        return writeAll(out, "\r\n".toByteArray())
    }

    private fun respondSimple(out: OutputStream, status: String, contentType: String, body: ByteArray) {
        val headers = "HTTP/1.1 $status\r\nContent-Type: $contentType\r\n" +
            "Content-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray()
        writeAll(out, headers)
        writeAll(out, body)
    }

    /** Loop send() until every byte is out; partial writes are common on TLS-less TCP. */
    private fun writeAll(out: OutputStream, data: ByteArray): Boolean = try {
        out.write(data)
        out.flush()
        true
    } catch (e: IOException) {
        false
    }
}
