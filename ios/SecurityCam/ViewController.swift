// ViewController.swift
// Full-screen camera preview + status label with the LAN stream URL.
// Programmatic UIKit only — no storyboards, nothing newer than iOS 12.

import UIKit
import AVFoundation

final class ViewController: UIViewController {

    private let streamer = CameraStreamer()
    private let server = HTTPStreamServer(port: 8080)

    private var previewLayer: AVCaptureVideoPreviewLayer?

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = UIFont(name: "Menlo", size: 15) ?? UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        label.textColor = UIColor(red: 0.2, green: 1.0, blue: 0.4, alpha: 1.0) // green terminal look
        label.backgroundColor = UIColor(white: 0.0, alpha: 0.6)
        return label
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Keep the screen awake — a sleeping phone kills the stream.
        UIApplication.shared.isIdleTimerDisabled = true

        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])

        statusLabel.text = "Requesting camera access…"
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestCameraPermissionAndStart()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Leave the session running only while visible; when the app is
        // backgrounded iOS suspends it anyway (see README).
    }

    // MARK: - Permission + startup

    private func requestCameraPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startEverything()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.startEverything()
                    } else {
                        self?.showError("Camera permission denied.\nEnable it in Settings → SecurityCam → Camera.")
                    }
                }
            }
        case .denied, .restricted:
            showError("Camera permission denied.\nEnable it in Settings → SecurityCam → Camera.")
        @unknown default:
            showError("Unknown camera authorization status.")
        }
    }

    private func startEverything() {
        // Wire camera frames into the HTTP server.
        streamer.delegate = server
        streamer.maxFPS = 10.0
        streamer.jpegQuality = 0.5
        streamer.start()
        server.start()

        attachPreviewLayer()

        if let ip = Self.localIPAddress() {
            statusLabel.text = "● LIVE\nhttp://\(ip):8080/stream"
        } else {
            showError("No Wi-Fi address found (en0).\nConnect the iPhone to your network.")
        }
    }

    private func attachPreviewLayer() {
        guard previewLayer == nil else { return }
        let layer = AVCaptureVideoPreviewLayer(session: streamer.session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Insert below the status label so the URL stays readable.
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
    }

    private func showError(_ message: String) {
        statusLabel.textColor = UIColor(red: 1.0, green: 0.35, blue: 0.3, alpha: 1.0)
        statusLabel.text = "✕ \(message)"
    }

    // MARK: - Local IP helper

    /// Returns the device's IPv4 address, preferring the Wi-Fi interface en0
    /// and falling back to any non-loopback IPv4 address. Uses getifaddrs
    /// from Darwin/BSD sockets.
    static func localIPAddress() -> String? {
        var address: String?
        var fallback: String?

        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            guard let sockAddr = current.pointee.ifa_addr else { continue }

            let family = sockAddr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }   // IPv4 only

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(sockAddr,
                                     socklen_t(current.pointee.ifa_addrlen),
                                     &hostname, socklen_t(hostname.count),
                                     nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let ip = String(cString: hostname)
            guard !ip.hasPrefix("127.") else { continue }      // skip loopback

            let name = String(cString: current.pointee.ifa_name)
            if name == "en0" {
                address = ip        // Wi-Fi: preferred answer
                break
            }
            if fallback == nil {
                fallback = ip       // e.g. pdp_ip0 (cellular) as backup
            }
        }
        return address ?? fallback
    }
}
