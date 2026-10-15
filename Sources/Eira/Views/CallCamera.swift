import AVFoundation
import CoreImage
import SwiftUI
import UIKit

/// 视频通话里我这边的前置摄像头（网页版 system/camera.js）。
///
/// 只在通话里开，挂断就关。画面只留最近一帧，轮到发请求时取一张缩小的 JPEG 挂在我那句话上；
/// 不录像、不存文件。角色能不能看见取决于识图那一档：只认「交给聊天模型」，画面跟着那一轮请求一起过去，不多调一次接口。
@MainActor
final class CallCamera: ObservableObject {
    let session = AVCaptureSession()
    @Published private(set) var running = false
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "eira.call-camera")
    private let latest = LatestFrame()
    private var configured = false

    func start() async throws {
        guard !running else { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw StoreError(message: "未获得相机权限，可在系统设置中为本应用开启")
        }
        if !configured {
            guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: dev) else {
                throw StoreError(message: "没有可用的前置摄像头")
            }
            session.beginConfiguration()
            session.sessionPreset = .medium
            if session.canAddInput(input) { session.addInput(input) }
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(latest, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            if let c = output.connection(with: .video) {
                if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
                if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = true }
            }
            session.commitConfiguration()
            configured = true
        }
        let s = session
        await Task.detached(priority: .userInitiated) { s.startRunning() }.value
        running = s.isRunning
        if !running { throw StoreError(message: "摄像头未能打开") }
    }

    func stop() {
        guard running || session.isRunning else { return }
        running = false
        latest.clear()
        let s = session
        Task.detached { s.stopRunning() }
    }

    /// 最近一帧，缩到长边 640 的 JPEG
    func grab() -> AIImage? {
        guard running else { return nil }
        return latest.jpeg(maxPixel: 640)
    }
}

/// 摄像头回调在自己的队列上，只记住最近那一帧
private final class LatestFrame: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private let context = CIContext()

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); buffer = pb; lock.unlock()
    }

    func clear() { lock.lock(); buffer = nil; lock.unlock() }

    func jpeg(maxPixel: CGFloat) -> AIImage? {
        lock.lock(); let pb = buffer; lock.unlock()
        guard let pb else { return nil }
        var img = CIImage(cvPixelBuffer: pb)
        let side = max(img.extent.width, img.extent.height)
        if side > maxPixel { img = img.transformed(by: CGAffineTransform(scaleX: maxPixel / side, y: maxPixel / side)) }
        guard let cg = context.createCGImage(img, from: img.extent),
              let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.7) else { return nil }
        return AIImage(mediaType: "image/jpeg", base64: data.base64EncodedString())
    }
}

/// 我这边的小窗：摄像头画面
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {}
}
