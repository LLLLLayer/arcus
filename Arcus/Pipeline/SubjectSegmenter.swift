import Foundation
import Vision
import CoreVideo

/// 主体分割：取前景主体的软 matte（0…1）。
/// 优先级：VNGenerateForegroundInstanceMaskRequest（类无关主体, iOS17+）
///        → VNGeneratePersonSegmentationRequest（仅人物）
///        → nil（交由管线用深度阈值近似前景）。
final class SubjectSegmenter {

    enum Source: String { case foregroundInstance = "Foreground subject instance", person = "Person segmentation", none = "Depth-threshold approximation" }

    struct Result {
        var mask: FloatImage    // 1ch, 0…1
        var source: Source
    }

    /// 返回 nil 表示两种系统分割都不可用（模拟器 / 无主体）。
    func segment(cgImage: CGImage, width: Int, height: Int) -> Result? {
        if let m = foregroundInstanceMask(cgImage: cgImage, width: width, height: height) {
            return Result(mask: m, source: .foregroundInstance)
        }
        if let m = personMask(cgImage: cgImage, width: width, height: height) {
            return Result(mask: m, source: .person)
        }
        return nil
    }

    // MARK: - 前景主体实例 mask (iOS 17+)

    private func foregroundInstanceMask(cgImage: CGImage, width: Int, height: Int) -> FloatImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let maskPB = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            guard let raw = ImageUtils.scalarFloats(from: maskPB) else { return nil }
            return raw.resized(to: width, to: height)
        } catch {
            NSLog("[Segment] Foreground instance mask unavailable (simulator/no subject): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 人物分割兜底

    private func personMask(cgImage: CGImage, width: Int, height: Int) -> FloatImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let obs = request.results?.first as? VNPixelBufferObservation,
                  let raw = ImageUtils.scalarFloats(from: obs.pixelBuffer) else { return nil }
            // 人物分割若几乎全黑（无人物），视为失败。
            let mean = raw.pixels.reduce(0, +) / Float(raw.pixels.count)
            guard mean > 0.005 else { return nil }
            return raw.resized(to: width, to: height)
        } catch {
            NSLog("[Segment] Person segmentation unavailable: \(error.localizedDescription)")
            return nil
        }
    }
}
