import AVFoundation
import SwiftUI

/// Runs the back camera and recognises text in a frame about once a second.
final class CameraScanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onText: ((String) -> Void)?
    var isPaused = false

    private let queue = DispatchQueue(label: "etymon.camera")
    private var lastScan = Date.distantPast
    private var isScanning = false
    private let interval: TimeInterval = 1.0

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
        guard !isPaused, !isScanning, Date().timeIntervalSince(lastScan) >= interval,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastScan = Date()
        isScanning = true
        defer { isScanning = false }
        // portrait, back camera: the sensor's top is the device's right
        guard let text = try? WordExtractor.recognizeText(in: buffer, orientation: .right),
              !text.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onText?(text) }
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
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
