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

// MARK: - 首页内嵌「实时取景」相机卡（camera-first，点按光圈「转开」）

/// 首页顶部的相机卡。**不自动开相机**（不在启动/解锁时弹权限）：默认是一颗七彩光圈「打开相机」按钮，
/// 点按后光圈像桌面图标一样旋转放大「转开」，再淡入实时取景；快门拍照 → `processData` 进入 3D。
/// 复用 `CameraController`/`CameraPreviewView`。未授权/无相机时回退到优雅引导，永不空白。
struct CameraHomeCard: View {
    @ObservedObject var model: AppModel
    @StateObject private var cam = CameraController()
    @State private var started = false           // 用户是否已点「打开相机」
    @State private var openProgress: Double = 0  // 0=闭合 → 1=花瓣全开（几何）
    @State private var revealed = false           // 绽放完成后：花淡出、取景淡入
    @State private var shutterFlash = false
    @State private var autoFired = false

    var body: some View {
        ZStack {
            // 背景：闭合/绽放时暗底；绽放完成后交叉淡入实时取景
            idleBackdrop.opacity(revealed ? 0 : 1)
            if started { liveOrFallback.opacity(revealed ? 1 : 0) }

            // 七彩机械光圈：闭合=「打开相机」按钮；点按后旋转张开（像镜头光圈），随后淡出
            apertureButton

            // 闭合态文案
            if !started {
                VStack {
                    Spacer()
                    Text("Open Camera").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text("Tap to shoot a 3D photo").font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
                .padding(.bottom, 24)
                .opacity(1 - openProgress)
            }

            // 取景控件（绽放完成 + 就绪后才出现）
            if revealed, cam.status == .ready {
                liveControls.transition(.opacity)
            }

            if shutterFlash { Color.white }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 22, x: 0, y: 12)
        .onAppear {
            // 冒烟钩子：AUTOCAMERA=1 启动即自动「转开」相机。
            if ProcessInfo.processInfo.environment["AUTOCAMERA"] == "1" { openCamera() }
        }
        .onDisappear { cam.stop(); resetClosed() }
        .onChange(of: cam.status) { _, s in
            guard s == .ready, !autoFired,
                  ProcessInfo.processInfo.environment["AUTOCAMERA"] == "1" else { return }
            autoFired = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { capture() }
        }
    }

    // MARK: 打开 / 复位

    private func openCamera() {
        guard !started else { return }
        started = true
        cam.onCapture = { data in cam.stop(); model.processData(data) }
        cam.start()
        withAnimation(.spring(response: 0.6, dampingFraction: 0.74)) { openProgress = 1 }    // 机械开合：快、精准、微回弹
        withAnimation(.easeInOut(duration: 0.4).delay(0.5)) { revealed = true }               // 张开后交叉淡入取景
    }

    private func resetClosed() {
        started = false; openProgress = 0; revealed = false; autoFired = false
    }

    // MARK: 机械光圈按钮 +「旋转张开」动画

    private var apertureButton: some View {
        Button(action: openCamera) {
            BladeIris(progress: openProgress)
                .frame(width: 168, height: 168)
                .shadow(color: Theme.accentA.opacity(0.45), radius: 22)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!started)
        .opacity(revealed ? 0 : 1)
    }

    private var idleBackdrop: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.13), Color(red: 0.03, green: 0.035, blue: 0.06), .black], startPoint: .top, endPoint: .bottom)
            Circle().fill(Theme.accentA.opacity(0.22)).frame(width: 220, height: 220).blur(radius: 70).offset(x: -60, y: -80)
            Circle().fill(Theme.accentB.opacity(0.18)).frame(width: 200, height: 200).blur(radius: 70).offset(x: 70, y: 90)
        }
    }

    // MARK: 实时取景 + 控件

    @ViewBuilder private var liveOrFallback: some View {
        switch cam.status {
        case .denied: fallback(denied: true)
        case .failed: fallback(denied: false)
        default:      livePreview
        }
    }

    private var livePreview: some View {
        ZStack {
            Color.black
            CameraPreviewView(session: cam.session).opacity(cam.status == .ready ? 1 : 0)
            if cam.status != .ready { ProgressView().controlSize(.large).tint(.white) }
        }
    }

    private var liveControls: some View {
        VStack {
            HStack {
                roundButton(cam.flash.icon) { cam.flash = cam.flash.next }
                Spacer()
                if cam.depthSupported {
                    PillLabel(text: String(localized: "Depth On"), icon: "cube.transparent")
                }
                Spacer()
                roundButton("arrow.triangle.2.circlepath.camera.fill") { cam.switchCamera() }
            }
            Spacer()
            shutterButton
        }
        .padding(16)
    }

    private func roundButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    /// 快门 = 小号七彩光圈环 + 白心，呼应图标与「转开」的大光圈。
    private var shutterButton: some View {
        Button { capture() } label: {
            ZStack {
                BladeIris(progress: 0.34)
                    .frame(width: 80, height: 80)
                Circle().fill(.white).frame(width: 44, height: 44)
                    .scaleEffect(cam.isCapturing ? 0.82 : 1)
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

    // MARK: 回退引导（未授权 / 无相机）

    @ViewBuilder private func fallback(denied: Bool) -> some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.13), Color(red: 0.03, green: 0.035, blue: 0.06), .black], startPoint: .top, endPoint: .bottom)
            HeroDepthPeel().frame(maxWidth: .infinity).opacity(0.85).allowsHitTesting(false)
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 10) {
                Image(systemName: "camera.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.92))
                Text(denied ? "Camera Access Needed" : "Camera Unavailable")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                if denied {
                    Button { openSettings() } label: {
                        Text("Open Settings").font(.caption.weight(.semibold)).foregroundStyle(Theme.accentB)
                    }
                } else {
                    Text("Pick a photo below to create a 3D scene")
                        .font(.caption).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                }
            }
            .padding(20)
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
