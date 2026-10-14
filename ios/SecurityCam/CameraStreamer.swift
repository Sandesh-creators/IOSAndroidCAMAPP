// CameraStreamer.swift
// Captures video from the back wide-angle camera and publishes JPEG frames.
// Uses only iOS 12-era APIs (AVFoundation + CoreImage, no Combine/async).

import AVFoundation
import CoreImage
import UIKit

protocol CameraStreamerDelegate: AnyObject {
    /// Called on an arbitrary background queue with each encoded JPEG frame.
    func cameraStreamer(_ streamer: CameraStreamer, didProduceJPEG jpeg: Data)
}

final class CameraStreamer: NSObject {

    weak var delegate: CameraStreamerDelegate?

    let session = AVCaptureSession()

    /// Maximum processed frames per second (frames above this are dropped).
    var maxFPS: Double = 10.0

    /// JPEG quality 0.0 ... 1.0 used for every published frame.
    var jpegQuality: CGFloat = 0.5

    private let videoQueue = DispatchQueue(label: "com.example.securitycam.video", qos: .userInitiated)
    private let ciContext = CIContext(options: nil)
    private var lastFrameTime: CFTimeInterval = 0

    private(set) var isRunning = false

    // MARK: - Setup

    override init() {
        super.init()
        configureSession()
    }

    private func configureSession() {
        session.beginConfiguration()
        // .medium is a good balance of resolution/CPU on A7-A11 devices.
        if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }

        // Back wide-angle camera device.
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                 for: .video,
                                                 position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        // Raw BGRA pixel buffers delivered to our delegate queue.
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        session.commitConfiguration()
    }

    // MARK: - Control

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Session start is blocking; run it off the main thread.
        videoQueue.async { [session] in
            session.startRunning()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        videoQueue.async { [session] in
            session.stopRunning()
        }
    }

    // MARK: - Frame conversion

    /// Converts one CMSampleBuffer to JPEG, honouring the maxFPS throttle.
    fileprivate func process(sampleBuffer: CMSampleBuffer) {
        // Throttle: skip frames that arrive faster than 1/maxFPS.
        let now = CACurrentMediaTime()
        let minInterval = 1.0 / max(1.0, maxFPS)
        if now - lastFrameTime < minInterval {
            return
        }
        lastFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Lock the base address so we can wrap it in a CIImage without copying.
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        let uiImage = UIImage(cgImage: cgImage)
        // jpegData(compressionQuality:) exists since iOS 11, so prefer it over
        // the deprecated UIImageJPEGRepresentation global function.
        guard let jpeg = uiImage.jpegData(compressionQuality: jpegQuality) else { return }

        delegate?.cameraStreamer(self, didProduceJPEG: jpeg)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraStreamer: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ captureOutput: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        process(sampleBuffer: sampleBuffer)
    }
}
