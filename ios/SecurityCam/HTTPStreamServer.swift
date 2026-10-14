// HTTPStreamServer.swift
// Minimal raw-BSD-socket HTTP/1.0 server that serves an MJPEG stream, a
// single snapshot, and a plain-text status page. No third-party frameworks.
//
// MJPEG framing refresher: the response is `multipart/x-mixed-replace` with a
// boundary; each part is a full JPEG preceded by its own Content-Type /
// Content-Length headers. The client "replaces" the previous part as new
// parts arrive, which renders as live video in any browser.

import Foundation
import Darwin

final class HTTPStreamServer {

    /// TCP port to listen on (default 8080).
    let port: UInt16

    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "com.example.securitycam.accept")
    /// Serial queue guarding the client list + latest frame (our "lock").
    private let stateQueue = DispatchQueue(label: "com.example.securitycam.state")

    /// File descriptors of connected /stream clients.
    private var streamClients: [Int32] = []
    /// Most recent JPEG, kept for /snapshot.
    private var latestJPEG: Data?

    private let boundary = "frame"
    private var running = false

    init(port: UInt16 = 8080) {
        self.port = port
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true

        // AF_INET = IPv4, SOCK_STREAM = TCP, protocol 0 = default (TCP).
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("HTTPStreamServer: socket() failed (errno \(errno))")
            running = false
            return
        }

        // Allow quick restart without waiting for TIME_WAIT.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian                 // network byte order
        addr.sin_addr.s_addr = INADDR_BIG_ENDIAN_ANY   // 0 == INADDR_ANY, big-endian

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("HTTPStreamServer: bind() on port \(port) failed (errno \(errno))")
            close(fd)
            running = false
            return
        }

        guard listen(fd, 8) == 0 else {
            NSLog("HTTPStreamServer: listen() failed (errno \(errno))")
            close(fd)
            running = false
            return
        }

        listenFD = fd

        // Blocking accept loop on a dedicated background queue.
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
        NSLog("HTTPStreamServer: listening on port \(port)")
    }

    func stop() {
        running = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        stateQueue.sync {
            for fd in streamClients { close(fd) }
            streamClients.removeAll()
        }
    }

    private func acceptLoop() {
        while running {
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &len)
                }
            }
            if clientFD < 0 {
                if !running { break }        // stopped intentionally
                usleep(50_000)               // transient error: back off briefly
                continue
            }

            // Suppress SIGPIPE so writing to a disconnected client returns an
            // error instead of killing the app.
            var nosigpipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE,
                       &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

            // Handle each connection on a global concurrent queue so slow
            // clients never block the accept loop or each other.
            DispatchQueue.global().async { [weak self] in
                self?.handleConnection(fd: clientFD)
            }
        }
    }

    // MARK: - Frame publishing

    /// Called from the camera queue with every encoded JPEG frame.
    func publish(jpeg: Data) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            self.latestJPEG = jpeg
            var dead: [Int32] = []
            for fd in self.streamClients {
                if !self.writeMultipartFrame(jpeg: jpeg, to: fd) {
                    dead.append(fd)
                }
            }
            // Remove + close sockets whose client vanished.
            if !dead.isEmpty {
                for fd in dead { close(fd) }
                self.streamClients.removeAll(where: { dead.contains($0) })
            }
        }
    }

    // MARK: - Connection handling

    private func handleConnection(fd: Int32) {
        defer { if !isStreamingClient(fd) { close(fd) } }

        // Read the request line(s) until CRLF CRLF (or a lone "\r\n"-terminated
        // first line is enough for routing — we loop recv until we see "\r\n").
        guard let request = readRequestHead(fd: fd) else { return }
        let methodAndPath = parseRequestLine(request)

        guard methodAndPath.method == "GET" else {
            writeSimpleResponse(fd: fd,
                                status: "405 Method Not Allowed",
                                contentType: "text/plain",
                                body: Data("Method not allowed\n".utf8))
            return
        }

        switch methodAndPath.path {
        case "/stream":
            serveStream(fd: fd)

        case "/snapshot":
            let jpeg = stateQueue.sync { latestJPEG }
            if let jpeg = jpeg {
                writeSimpleResponse(fd: fd,
                                    status: "200 OK",
                                    contentType: "image/jpeg",
                                    body: jpeg)
            } else {
                writeSimpleResponse(fd: fd,
                                    status: "503 Service Unavailable",
                                    contentType: "text/plain",
                                    body: Data("No frame yet\n".utf8))
            }

        case "/":
            let count = stateQueue.sync { streamClients.count }
            let hasFrame = stateQueue.sync { latestJPEG != nil }
            let text = """
            SecurityCam iOS streamer
            ------------------------
            Status:   RUNNING
            Stream:   /stream  (multipart/x-mixed-replace MJPEG)
            Snapshot: /snapshot (single JPEG)
            Clients:  \(count) watching /stream
            Frames:   \(hasFrame ? "publishing" : "none yet")
            """
            writeSimpleResponse(fd: fd,
                                status: "200 OK",
                                contentType: "text/plain; charset=utf-8",
                                body: Data((text + "\n").utf8))

        default:
            writeSimpleResponse(fd: fd,
                                status: "404 Not Found",
                                contentType: "text/plain",
                                body: Data("Not found. Try /stream, /snapshot or /\n".utf8))
        }
    }

    /// Reads bytes until the first complete line ("\r\n") or connection close.
    private func readRequestHead(fd: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 1024)
        var received: [UInt8] = []
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { return nil }          // closed or error
            received.append(contentsOf: buffer[0..<n])
            // Stop as soon as we have a full request line ending in "\r\n".
            if containsCRLF(in: received) { break }
            if received.count >= 1024 { break } // give up on absurdly long lines
        }
        return String(bytes: received, encoding: .isoLatin1)
    }

    /// True if the byte array contains a CR LF pair anywhere.
    private func containsCRLF(in bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        for i in 0..<(bytes.count - 1) where bytes[i] == 0x0D && bytes[i + 1] == 0x0A {
            return true
        }
        return false
    }

    private struct RequestLine {
        let method: String
        let path: String
    }

    private func parseRequestLine(_ request: String) -> RequestLine {
        let firstLine = request.components(separatedBy: "\r\n").first ?? request
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return RequestLine(method: "GET", path: "/") }
        return RequestLine(method: String(parts[0]), path: String(parts[1]))
    }

    // MARK: - MJPEG streaming

    /// Registered fds currently receiving /stream (kept open across calls).
    private var streamingFDs = Set<Int32>()
    private let streamingFDsLock = NSLock()

    private func isStreamingClient(_ fd: Int32) -> Bool {
        streamingFDsLock.lock()
        defer { streamingFDsLock.unlock() }
        return streamingFDs.contains(fd)
    }

    private func serveStream(fd: Int32) {
        // Send the multipart response headers once, then keep the socket open
        // and let publish(jpeg:) push frames into it.
        let headers =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\n" +
            "Cache-Control: no-store, no-cache, must-revalidate\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        guard writeAll(fd: fd, data: Data(headers.utf8)) else { return }

        streamingFDsLock.lock()
        streamingFDs.insert(fd)
        streamingFDsLock.unlock()

        stateQueue.async { [weak self] in
            self?.streamClients.append(fd)
        }
        // NOTE: deliberately do NOT close fd here — publish() owns its life.
    }

    /// Writes one MIME part containing a JPEG. Returns false on send failure.
    private func writeMultipartFrame(jpeg: Data, to fd: Int32) -> Bool {
        var part = Data("--\(boundary)\r\n".utf8)
        part.append(Data("Content-Type: image/jpeg\r\n".utf8))
        part.append(Data("Content-Length: \(jpeg.count)\r\n\r\n".utf8))
        part.append(jpeg)
        part.append(Data("\r\n".utf8))
        return writeAll(fd: fd, data: part)
    }

    // MARK: - Low-level helpers

    private func writeSimpleResponse(fd: Int32, status: String,
                                     contentType: String, body: Data) {
        let headers =
            "HTTP/1.1 \(status)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        _ = writeAll(fd: fd, data: Data(headers.utf8))
        _ = writeAll(fd: fd, data: body)
    }

    /// send() wrapper that loops until all bytes are written (partial sends
    /// happen routinely on non-blocking-ish TCP paths).
    @discardableResult
    private func writeAll(fd: Int32, data: Data) -> Bool {
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                let sent = send(fd, base + offset, data.count - offset, 0)
                if sent <= 0 {
                    unregisterStreaming(fd: fd)
                    close(fd)
                    return false
                }
                offset += sent
            }
            return true
        }
    }

    private func unregisterStreaming(_ fd: Int32) {
        streamingFDsLock.lock()
        streamingFDs.remove(fd)
        streamingFDsLock.unlock()
        stateQueue.async { [weak self] in
            self?.streamClients.removeAll(where: { $0 == fd })
        }
    }
}

// INADDR_ANY in *big-endian* form, ready for sin_addr.s_addr (which expects
// network byte order). Plain INADDR_ANY (host order 0) equals 0 anyway, but
// naming it keeps the intent explicit.
private let INADDR_BIG_ENDIAN_ANY: in_addr_t = in_addr_t(0).bigEndian
