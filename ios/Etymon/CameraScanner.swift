import AVFoundation
import SwiftUI

/// Runs the back camera. About once a second it reads the frame carefully (new words,
/// language); in between it re-reads quickly, ~10 times a second, so the positions of
/// known words follow the camera and the overlay moves with the video.
final class CameraScanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Frame {
        let recognition: Recognition
        let imageSize: CGSize  // upright frame size, for mapping boxes onto the preview
        let isFull: Bool  // careful pass: may add words; otherwise only positions
    }

    let session = AVCaptureSession()
    var onFrame: ((Frame) -> Void)?
    var isPaused = false

    private let queue = DispatchQueue(label: "etymon.camera")
    private var lastFull = Date.distantPast
    private var lastTrack = Date.distantPast
    private var isBusy = false
    private var trackFast = true  // false while the scene is in a script fast passes can't read
    private let fullInterval: TimeInterval = 1.0
    private let trackInterval: TimeInterval = 0.08

    static var isAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    func start() {
        queue.async { [self] in
            if session.inputs.isEmpty { configure() }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                   position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080  // text needs resolution
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date()
        guard !isBusy, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let full = !isPaused && now.timeIntervalSince(lastFull) >= fullInterval
        guard full || now.timeIntervalSince(lastTrack) >= trackInterval else { return }
        isBusy = true
        defer { isBusy = false }
        if full { lastFull = now } else { lastTrack = now }

        // portrait, back camera: the sensor's top is the device's right, so the upright
        // image is the buffer rotated: width and height swap
        let size = CGSize(width: CVPixelBufferGetHeight(buffer), height: CVPixelBufferGetWidth(buffer))
        guard let recognition = try? WordExtractor.recognize(in: buffer, orientation: .right,
                                                             fast: !full && trackFast) else { return }
        if full { trackFast = WordExtractor.fastReads(recognition.text) }
        let frame = Frame(recognition: recognition, imageSize: size, isFull: full)
        DispatchQueue.main.async { [weak self] in self?.onFrame?(frame) }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill  // OverlayView maps boxes the same way
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
