import Metal
import MetalKit
import CoreImage

/// 全 App 共享的 Metal 设备 / 队列 / 默认着色器库 / CIContext。
/// 实时渲染与纹理上传都走这里，避免重复创建昂贵对象。
final class MetalContext {
    static let shared = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let ciContext: CIContext

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal 不可用：本设备/模拟器不支持 Metal。")
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            fatalError("无法创建 Metal command queue。")
        }
        self.queue = queue
        // 工程内的 .metal 文件会被编进 default.metallib。
        guard let library = device.makeDefaultLibrary() else {
            fatalError("找不到 default.metallib（Shaders.metal 未编译进 target？）。")
        }
        self.library = library
        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .cacheIntermediates: false
        ])
    }

    // MARK: - 纹理工厂

    /// 分配失败返回 nil（内存紧张时优雅降级，不崩）。
    func makeColorTexture(width: Int, height: Int,
                          usage: MTLTextureUsage = [.shaderRead],
                          storage: MTLStorageMode = .shared) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: max(1, width), height: max(1, height), mipmapped: false)
        desc.usage = usage
        desc.storageMode = storage
        return device.makeTexture(descriptor: desc)
    }

    /// r16Float 单通道纹理（支持线性过滤，适合存视差/深度，shader 里可平滑采样）。
    func makeScalarTexture(width: Int, height: Int,
                           usage: MTLTextureUsage = [.shaderRead],
                           storage: MTLStorageMode = .shared) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: max(1, width), height: max(1, height), mipmapped: false)
        desc.usage = usage
        desc.storageMode = storage
        return device.makeTexture(descriptor: desc)
    }

    /// 离屏渲染目标。
    func makeRenderTarget(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: max(1, width), height: max(1, height), mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)
    }
}
