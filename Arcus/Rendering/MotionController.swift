import Foundation
import CoreMotion
import simd

/// 用陀螺仪姿态驱动视差。每帧在渲染线程同步拉取最新姿态（无跨线程竞争），
/// 相对初始参考姿态取 delta，钳位 + 一阶低通，输出 -1…1 的偏移。
final class MotionController {

    private let manager = CMMotionManager()
    private var refRoll: Double = 0
    private var refPitch: Double = 0
    private var hasReference = false
    private var filtered = SIMD2<Float>(0, 0)

    /// 钳位角度（弧度）：超过该倾角即达到最大视差。
    var maxAngle: Float = 0.40
    /// 低通系数（越小越平滑）。
    var smoothing: Float = 0.12

    private(set) var enabled = false

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { enabled = manager.isDeviceMotionActive; return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical)
        enabled = true
    }

    func stop() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
        enabled = false
    }

    /// 以当前姿态为新的“正视”参考。
    func recenter() { hasReference = false }

    /// 渲染线程每帧调用，返回平滑后的 -1…1 偏移。
    func sample() -> SIMD2<Float> {
        guard enabled, let dm = manager.deviceMotion else { return filtered }
        let att = dm.attitude
        if !hasReference {
            refRoll = att.roll
            refPitch = att.pitch
            hasReference = true
        }
        let dRoll = Float(att.roll - refRoll)
        let dPitch = Float(att.pitch - refPitch)
        // roll → 水平视差，pitch → 垂直视差。
        let tx = max(-1, min(1, dRoll / maxAngle))
        let ty = max(-1, min(1, dPitch / maxAngle))
        let target = SIMD2<Float>(tx, ty)
        filtered += (target - filtered) * smoothing
        return filtered
    }
}
