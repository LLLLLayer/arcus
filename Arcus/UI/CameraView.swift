import SwiftUI
import AVFoundation

// MARK: - 相机引擎（自建 AVFoundation 取景 + 拍照，端侧捕获硬件深度）

/// 端侧相机控制器：配置取景会话与拍照输出，在支持的设备上开启硬件深度（LiDAR/双摄/原深感）。
/// 拍出的 HEIC 内嵌深度，交给与「选照片」完全相同的 `processData` 路径 →
/// `AuxDepthLoader` 提取辅助深度并按 EXIF 摆正，零额外深度接线、复用已验证的人像/LiDAR 快速路径。
///
/// 非 `@MainActor`：会话配置/拍照都在串行队列上跑（AVCaptureSession 阻塞，不能上主线程）；
/// 所有 `@Published` 状态统一回投主线程。
final class CameraController: NSObject, ObservableObject {

    enum Status: Equatable { case configuring, ready, denied, failed }

    /// 闪光：自动 / 强制开 / 关。
    enum Flash: CaseIterable {
        case auto, on, off
        var mode: AVCaptureDevice.FlashMode { self == .auto ? .auto : (self == .on ? .on : .off) }
        var icon: String { self == .auto ? "bolt.badge.automatic.fill" : (self == .on ? "bolt.fill" : "bolt.slash.fill") }
        var next: Flash { self == .auto ? .on : (self == .on ? .off : .auto) }
    }

    @Published var status: Status = .configuring
    @Published var isCapturing = false
    @Published var depthSupported = false
    @Published var position: AVCaptureDevice.Position = .back
    @Published var flash: Flash = .auto

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.arcus.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false

    /// 拍照完成回调（主线程）：内嵌深度的 HEIC 数据。
    var onCapture: ((Data) -> Void)?

    // MARK: 启动 / 停止（含权限）

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.configureAndRun() }
                else { self?.publish { $0.status = .denied } }
            }
        default:
            publish { $0.status = .denied }
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSession()
            if self.configured, !self.session.isRunning { self.session.startRunning() }
        }
    }

    // MARK: 会话配置

    private func configureSession() {
        guard !configured else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard addInput(for: position) else {
            session.commitConfiguration()
            publish { $0.status = .failed }
            return
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        applyDepthDelivery()
        session.commitConfiguration()
        configured = true
        publish { $0.status = .ready }
    }

    /// 选当前朝向「最能给深度」的设备并接入。
    @discardableResult
    private func addInput(for position: AVCaptureDevice.Position) -> Bool {
        guard let device = Self.bestDevice(position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        videoInput = input
        return true
    }

    private func applyDepthDelivery() {
        let ok = photoOutput.isDepthDataDeliverySupported
        photoOutput.isDepthDataDeliveryEnabled = ok
        publish { $0.depthSupported = ok }
    }

    /// 深度优先的设备选择：后摄 LiDAR > 双摄/双广角 > 广角；前摄 原深感 > 广角。
    private static func bestDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .front {
            return AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
        return AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    // MARK: 切换前后摄

    func switchCamera() {
        guard configured else { return }
        let newPos: AVCaptureDevice.Position = (position == .back) ? .front : .back
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            let old = self.videoInput
            if let old { self.session.removeInput(old) }
            if self.addInput(for: newPos) {
                self.applyDepthDelivery()
                self.session.commitConfiguration()
                self.publish { $0.position = newPos }
            } else {
                // 接入失败：退回原朝向，保持可用
                if let old, self.session.canAddInput(old) { self.session.addInput(old); self.videoInput = old }
                self.session.commitConfiguration()
            }
        }
    }

    // MARK: 拍照

    func capture() {
        guard status == .ready, !isCapturing else { return }
        publish { $0.isCapturing = true }
        let flashMode = flash.mode
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.photoOutput.capturePhoto(with: self.makeSettings(flash: flashMode), delegate: self)
        }
    }

    private func makeSettings(flash: AVCaptureDevice.FlashMode) -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.photoQualityPrioritization = .quality
        if photoOutput.isDepthDataDeliveryEnabled {
            settings.isDepthDataDeliveryEnabled = true
            settings.embedsDepthDataInPhoto = true   // 写进 HEIC，供 AuxDepthLoader 复用
        }
        if let device = videoInput?.device, device.isFlashAvailable {
            settings.flashMode = flash
        }
        return settings
    }

    // MARK: 主线程回投

    private func publish(_ change: @escaping (CameraController) -> Void) {
        if Thread.isMainThread { change(self) }
        else { DispatchQueue.main.async { change(self) } }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = (error == nil) ? photo.fileDataRepresentation() : nil
        publish {
            $0.isCapturing = false
            if let data { $0.onCapture?(data) }
        }
    }
}

// MARK: - 取景预览（AVCaptureVideoPreviewLayer 桥接）

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - 相机界面

/// 自建相机界面：全屏取景 + 快门 / 前后摄切换 / 闪光。拍完直接走 `processData` 进入 3D 处理。
struct CameraView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cam = CameraController()
    @State private var shutterFlash = false
    @State private var autoFired = false   // AUTOCAMERA 冒烟：相机就绪后自动按一次快门

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if cam.status == .denied {
                deniedView
            } else {
                cameraStage
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            cam.onCapture = { data in
                dismiss()
                model.processData(data)
            }
            cam.start()
        }
        .onDisappear { cam.stop() }
        .onChange(of: cam.status) { _, s in
            // 冒烟钩子：AUTOCAMERA=1 且相机真正就绪(真机)后，自动按一次快门，端到端验证拍照→深度→3D。
            guard s == .ready, !autoFired,
                  ProcessInfo.processInfo.environment["AUTOCAMERA"] == "1" else { return }
            autoFired = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { capture() }
        }
    }

    private var cameraStage: some View {
        ZStack {
            CameraPreviewView(session: cam.session)
                .ignoresSafeArea()
                .opacity(cam.status == .ready ? 1 : 0)

            if cam.status != .ready {
                ProgressView().controlSize(.large).tint(.white)
            }

            if shutterFlash { Color.white.ignoresSafeArea() }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
    }

    private var topBar: some View {
        HStack {
            CircleIconButton(system: "xmark") { dismiss() }
            Spacer()
            if cam.depthSupported {
                PillLabel(text: String(localized: "Depth On"), icon: "cube.transparent")
            }
            Spacer()
            Button { cam.flash = cam.flash.next } label: {
                Image(systemName: cam.flash.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    private var bottomBar: some View {
        HStack {
            Color.clear.frame(width: 56, height: 56)
            Spacer()
            shutterButton
            Spacer()
            Button { cam.switchCamera() } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(cam.status != .ready)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 30)
    }

    private var shutterButton: some View {
        Button { capture() } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 5).frame(width: 78, height: 78)
                Circle().fill(.white).frame(width: 64, height: 64)
                    .scaleEffect(cam.isCapturing ? 0.84 : 1)
            }
        }
        .disabled(cam.isCapturing || cam.status != .ready)
        .animation(.easeOut(duration: 0.15), value: cam.isCapturing)
    }

    private func capture() {
        withAnimation(.easeIn(duration: 0.04)) { shutterFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeOut(duration: 0.22)) { shutterFlash = false }
        }
        cam.capture()
    }

    private var deniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.accentGradient)
            Text("Camera Access Needed")
                .font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text("Allow camera access in Settings to take a photo and turn it into a 3D scene.")
                .font(.callout).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button { openSettings() } label: { Text("Open Settings") }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)
            Button("Cancel") { dismiss() }
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(34)
        .frame(maxWidth: 360)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
