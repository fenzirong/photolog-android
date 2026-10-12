import SwiftUI
import AVFoundation
import UIKit

/// Wraps `AVCaptureSession` for SwiftUI.
///
/// The camera writes straight into a file under the app's own storage, so the JPEG the sensor
/// produced is the file the library holds. That is what makes 无损导出 meaningful later: there is
/// no intermediate bitmap anywhere in the capture path that could have thrown information away
/// before the photo ever reached the library.
@Observable
final class CameraSession: NSObject {
    var isReady = false
    var errorMessage: String?
    var lastSaved: Photo?

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var onCapture: ((URL) -> Void)?
    private var destination: URL?

    func start() {
        guard !session.isRunning else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video) else {
            errorMessage = "这台设备上没有可用的摄像头"
            return
        }

        // Configure on a background queue: `startRunning` blocks, and doing it on the main thread
        // is a visible freeze on the first frame.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                if self.session.canAddInput(input) { self.session.addInput(input) }
                if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                self.session.commitConfiguration()
                self.session.startRunning()
                DispatchQueue.main.async { self.isReady = true }
            } catch {
                DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func stop() {
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.stopRunning()
        }
    }

    func capture(to url: URL, completion: @escaping (URL) -> Void) {
        destination = url
        onCapture = completion
        // The settings object is single-use: reusing one instance across captures throws.
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }
}

extension CameraSession: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let url = destination else {
            DispatchQueue.main.async { self.errorMessage = error?.localizedDescription ?? "拍照失败" }
            return
        }
        try? data.write(to: url)
        let completion = onCapture
        destination = nil
        onCapture = nil
        DispatchQueue.main.async { completion?(url) }
    }
}

/// The live preview layer.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }

    /// A `UIView` whose backing layer *is* the preview layer, so the session's frames fill it
    /// without a separate layout pass.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            // Safe by the `layerClass` override above.
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

/// The camera tab.
struct CaptureView: View {
    let store: LibraryStore

    @State private var camera = CameraSession()
    @State private var capturing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if camera.isReady {
                        CameraPreview(session: camera.session)
                    } else if let message = camera.errorMessage {
                        VStack(spacing: 12) {
                            Text(message).foregroundStyle(.white)
                            Button("重试") {
                                camera.errorMessage = nil
                                camera.start()
                            }
                        }
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 12) {
                    Button(capturing ? "保存中…" : "拍照") { shutter() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!camera.isReady || capturing)

                    Text("照片按原样保存，不做二次压缩。拍完在图库里给它写一行文字说明，导出时可以按顺序连着说明一起带走。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(.systemBackground))
            }
            .navigationTitle("拍照")
            .onAppear { camera.start() }
            .onDisappear { camera.stop() }
        }
    }

    private func shutter() {
        capturing = true
        let url = store.newCaptureURL()
        camera.capture(to: url) { saved in
            camera.lastSaved = store.registerCapture(at: saved)
            capturing = false
        }
    }
}
