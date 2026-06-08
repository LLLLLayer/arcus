import Foundation
import UIKit
import AVFoundation

/// 端侧编排：UIImage → 深度 → 定向 → 主体分割 → 去遮挡补全 → 烘焙 Photo3DScene。
/// 全程一次性、可在后台线程跑；通过 progress 回调反馈阶段与进度。
/// 背景去遮挡补全方式（启动页选择）。
enum FillMode: String, CaseIterable, Identifiable, Sendable {
    case fast        // 竖直延续 + 深度门控（快，<1s，默认）
    case patchMatch  // PatchMatch 内容感知 + 深度门控（慢，~10s）
    case migan       // MI-GAN 神经补全（AI 生成，端侧）

    var id: String { rawValue }
    var title: String {
        switch self { case .fast: return "快速"; case .patchMatch: return "PatchMatch"; case .migan: return "AI 补全" }
    }
    var detail: String {
        switch self {
        case .fast: return "竖直延续 · 深度门控 · 实时"
        case .patchMatch: return "内容感知 · 更连贯 · 较慢（约十几秒）"
        case .migan: return "MI-GAN 神经生成 · 端侧 · 处理较慢"
        }
    }
    var source: String {
        switch self { case .fast: return "vertical+depth"; case .patchMatch: return "PatchMatch+depth"; case .migan: return "MI-GAN" }
    }
}

final class Photo3DPipeline {

    struct Options {
        var maxWorkingSide: Int = 1024
        /// 去遮挡环带半径占长边比例（决定背景被补全的范围，≈最大像素视差）。
        var ringRadiusFraction: Float = 0.045
        /// 背景补全方式：快速 / PatchMatch / MI-GAN。默认快速。
        var fillMode: FillMode = .fast
    }

    enum PipelineError: Error { case badImage, textureAllocation }

    private let depthEstimator = DepthEstimator()
    private let segmenter = SubjectSegmenter()
    private let lamaInpainter = LamaInpainter()
    private let miganInpainter = MiganInpainter()

    var isDepthModelAvailable: Bool { depthEstimator.isModelAvailable }
    var isLamaAvailable: Bool { lamaInpainter.isAvailable }

    func process(image: UIImage,
                 avDepth: AVDepthData? = nil,
                 options: Options = Options(),
                 progress: @escaping (Double, String) -> Void) throws -> Photo3DScene {

        let t0 = CFAbsoluteTimeGetCurrent()
        progress(0.05, "预处理图像…")
        guard let work = ImageUtils.workingImage(from: image, maxSide: options.maxWorkingSide) else {
            throw PipelineError.badImage
        }
        let cg = work.cg, W = work.width, H = work.height
        let color = FloatImage.fromCGImage(cg, width: W, height: H)   // rgba

        progress(0.20, "估计深度…")
        let depthResult = depthEstimator.estimate(cgImage: cg, width: W, height: H, avDepth: avDepth)
        var disparity = depthResult.disparity

        progress(0.45, "分割主体…")
        let segResult = segmenter.segment(cgImage: cg, width: W, height: H)

        // 主体 mask：系统分割优先；否则用深度近场阈值近似。
        var mask: FloatImage
        let segSource: String
        if let seg = segResult {
            mask = seg.mask
            segSource = seg.source.rawValue
            // 用 mask 自动校正深度远近方向（保证主体处视差更大）。
            orientDisparity(&disparity, mask: mask)
        } else {
            // 无系统分割：先确保 disparity 近=大（默认信任来源），再阈值取近景为前景。
            mask = nearFieldMask(from: disparity)
            segSource = SubjectSegmenter.Source.none.rawValue
        }

        // 边缘 matting 精修：用 RGB 亮度做 guided filter，把 mask 贴合到图像边缘（发丝/边界），
        // 减少边缘漏光与补全掩膜脏。
        let guide = color.luminance()
        mask = mask.guidedRefined(guide: guide, radius: max(2, W / 200), eps: 1e-4)
        // 收紧 matte 边缘到近乎硬边（几何抗锯齿交给 4×MSAA）：半透明过渡带越宽，
        // 主体背后的补全色越会从这条带"透出来"形成光晕。收紧到 ~1px → 补全被前景完全盖住。
        for p in 0..<(W * H) { mask.pixels[p] = smoothStep(0.46, 0.54, mask.pixels[p]) }

        // 边缘保持式深度去噪（中值）——保留深度断层，替代会糊掉悬崖的方框模糊。
        disparity = disparity.median3()

        progress(0.62, "补全主体背后的背景…")

        let longSide = Float(max(W, H))

        // 主体二值（阈值低些把柔边并入），用于前景深度的平滑/外扩。
        var subj = FloatImage(width: W, height: H, channels: 1)
        for p in 0..<(W * H) { subj.pixels[p] = mask.pixels[p] > 0.35 ? 1 : 0 }

        // 补全区 = 仅「前景不透明覆盖」的区域(matte>0.5)，**绝不外扩到真实背景**。
        // 之前向外膨胀 ~25px 去补全，等于把剪影外那一圈真背景换成了填充色 → 就是用户看到的光圈。
        // 现在只补主体所在处；剪影之外保持原始真背景，零光圈。露出的去遮挡发生在剪影"内"，仍被补到。
        // 有效背景 = 主体之外的干净背景(matte<0.35)，作为补全的「已知区」。
        var validFull = FloatImage(width: W, height: H, channels: 1)
        for p in 0..<(W * H) { validFull.pixels[p] = subj.pixels[p] > 0.5 ? 0 : 1 }

        // 背景颜色：快速=竖直延续(实时)；PatchMatch=内容感知(慢)；MI-GAN=神经生成(端侧)。
        // 前两者传入 disparity 做「深度门控」：只从身后背景侧取色。MI-GAN 直接生成整块洞(主体区)，
        // 失败/模型缺失则回退 PatchMatch。三者都只在 hole(主体区) 内补，剪影外保持真背景。
        let rgbColor = rgb3(color)
        let bgColorImg: FloatImage
        let inpaintSource: String
        switch options.fillMode {
        case .migan:
            progress(0.62, "AI 补全背景（MI-GAN，端侧生成）…")
            if let mig = miganInpainter.inpaint(rgb: rgbColor, hole: subj) {
                bgColorImg = mig
                inpaintSource = "MI-GAN"
            } else {
                bgColorImg = DisocclusionInpainter.patchMatchFill(rgbColor, valid: validFull, disparity: disparity)
                inpaintSource = "PatchMatch+depth(MI-GAN 不可用)"
            }
        case .patchMatch:
            progress(0.62, "高质量补全背景（PatchMatch · 深度感知，较慢）…")
            bgColorImg = DisocclusionInpainter.patchMatchFill(rgbColor, valid: validFull, disparity: disparity)
            inpaintSource = "PatchMatch+depth"
        case .fast:
            bgColorImg = DisocclusionInpainter.verticalFill(rgbColor, valid: validFull, disparity: disparity)
            inpaintSource = "vertical+depth"
        }

        // 背景深度：降采样上 push-pull（深度平滑无妨），主体区按背景视差填充。
        let inpaintSide = 640
        let s = Float(inpaintSide) / longSide
        let iw = max(2, Int((Float(W) * s).rounded()))
        let ih = max(2, Int((Float(H) * s).rounded()))
        let dispSmall = disparity.resized(to: iw, to: ih)
        let validSmall = validFull.resized(to: iw, to: ih)
        let bgDepthImg = DisocclusionInpainter.pushPullFill(dispSmall, valid: validSmall).resized(to: W, to: H)

        progress(0.85, "烘焙 3D 网格…")

        // 前景几何深度——关键：
        // (1) 主体内部「带掩膜强平滑」：Depth Anything 在发丝/边缘处深度噪声极大，
        //     若直接拿来 warp，网格会在主体内被撕成毛刺+空洞（实测真机毛刺/糊背景的根因，
        //     合成噪声深度复现：115200 个三角只剩 1310 个）。带掩膜模糊只用主体内像素求平均，
        //     既抹平内部噪声、又保留剪影处的深度悬崖。
        let rBlur = max(3, W / 30)
        var dmul = FloatImage(width: W, height: H, channels: 1)
        for p in 0..<(W * H) { dmul.pixels[p] = disparity.pixels[p] * subj.pixels[p] }
        let num = dmul.boxBlurred(radius: rBlur, passes: 2)
        let den = subj.boxBlurred(radius: rBlur, passes: 2)
        var fgDisp = disparity
        for p in 0..<(W * H) where subj.pixels[p] > 0.5 {
            fgDisp.pixels[p] = den.pixels[p] > 0.01 ? num.pixels[p] / den.pixels[p] : disparity.pixels[p]
        }
        // (2) 把(已平滑的)主体深度向外扩张一个小带，使柔和 matte 的边缘与主体同步位移
        //     （边缘抗锯齿、不产生反向尖刺）。
        let extR = max(4, W / 120)
        let subjDil2 = subj.dilated(radius: extR)
        let fgDispDil = fgDisp.dilated(radius: extR)
        for p in 0..<(W * H) where subjDil2.pixels[p] > 0.5 && subj.pixels[p] < 0.5 {
            fgDisp.pixels[p] = fgDispDil.pixels[p]
        }

        // 前景层 rgb+a：干净锐利主体（无外扩带 ⇒ 边缘零光晕）。「整体放大」改由顶点着色器在
        // 运行时按 fgScale 绕主体质心完成（放大剪影盖住身后过渡带），故此处只烘焙原尺寸主体。
        // 颜色：羽化带(剪影外的过渡像素)用「最近主体像素」外扩，避免放大时把背景色拉出一圈边。
        let extColor = DisocclusionInpainter.nearestValidFill(rgb3(color), valid: subj)
        var fg = FloatImage(width: W, height: H, channels: 4)
        var fgAField = FloatImage(width: W, height: H, channels: 1)
        for p in 0..<(W * H) {
            if subj.pixels[p] > 0.5 {
                fg.pixels[p*4+0] = color.pixels[p*4+0]; fg.pixels[p*4+1] = color.pixels[p*4+1]; fg.pixels[p*4+2] = color.pixels[p*4+2]
            } else {
                fg.pixels[p*4+0] = extColor.pixels[p*3+0]; fg.pixels[p*4+1] = extColor.pixels[p*3+1]; fg.pixels[p*4+2] = extColor.pixels[p*3+2]
            }
            let a = mask.pixels[p]
            fg.pixels[p*4+3] = a
            fgAField.pixels[p] = a
        }

        // 主体质心(uv)：前景「整体放大」的支点（绕质心放大 ⇒ 上下左右对称外扩，盖住各方向的去遮挡带）。
        var cxSum: Double = 0, cySum: Double = 0, cN: Double = 0
        for y in 0..<H {
            for x in 0..<W where subj.pixels[y * W + x] > 0.5 {
                cxSum += Double(x); cySum += Double(y); cN += 1
            }
        }
        let fgCenter = cN > 0
            ? SIMD2<Float>(Float(cxSum / cN) / Float(W), Float(cySum / cN) / Float(H))
            : SIMD2<Float>(0.5, 0.5)

        guard let depthTex = fgDisp.uploadScalarTexture(),
              let fgColorTex = fg.uploadColorTexture(),
              let bgColorTex = bgColorImg.uploadColorTexture(),
              let bgDepthTex = bgDepthImg.uploadScalarTexture() else {
            throw PipelineError.textureAllocation
        }

        // 构建网格：背景=完整连续网格(平滑视差,无分层环)；前景=主体网格(深度断层处切开,无橡皮膜糊影)。
        guard let mesh = MeshBuilder.build(width: W, height: H,
                                           disparity: fgDisp, matte: fgAField,
                                           stride: 2, tauCut: 0.05) else {
            throw PipelineError.textureAllocation
        }

        // ===== 背景再分层（近景背景中间层 mid + 远景背景打底 far），供「背景再分层」开关使用 =====
        // 把「非主体」背景按视差中位数拆成 近景背景(更近、动得多) / 远景背景(更远、动得少)。
        var midThr: Float = 0.5
        var bgVals = [Float](); bgVals.reserveCapacity(W * H)
        for p in 0..<(W * H) where subj.pixels[p] < 0.5 { bgVals.append(disparity.pixels[p]) }
        if !bgVals.isEmpty { bgVals.sort(); midThr = bgVals[bgVals.count / 2] }
        let midBand: Float = 0.06
        var midMatte = FloatImage(width: W, height: H, channels: 1)
        for p in 0..<(W * H) {
            midMatte.pixels[p] = subj.pixels[p] < 0.5 ? smoothStep(midThr - midBand, midThr + midBand, disparity.pixels[p]) : 0
        }
        midMatte = midMatte.boxBlurred(radius: max(2, W / 200), passes: 1)   // 去掉散点
        var midBin = FloatImage(width: W, height: H, channels: 1)
        for p in 0..<(W * H) { midBin.pixels[p] = midMatte.pixels[p] > 0.5 ? 1 : 0 }
        // 近景背景质心(uv)：中间层「放大」的支点（同前景：绕质心放大近景背景，盖住其身后远景的去遮挡带）。
        var mcx: Double = 0, mcy: Double = 0, mcN: Double = 0
        for y in 0..<H {
            for x in 0..<W where midBin.pixels[y * W + x] > 0.5 {
                mcx += Double(x); mcy += Double(y); mcN += 1
            }
        }
        let midCenter = mcN > 0
            ? SIMD2<Float>(Float(mcx / mcN) / Float(W), Float(mcy / mcN) / Float(H))
            : SIMD2<Float>(0.5, 0.5)
        // 近景背景深度：带掩膜平滑(去噪) + 外扩（同前景技巧，避免网格撕裂）。
        var mdmul = FloatImage(width: W, height: H, channels: 1)
        for p in 0..<(W * H) { mdmul.pixels[p] = disparity.pixels[p] * midBin.pixels[p] }
        let mnum = mdmul.boxBlurred(radius: rBlur, passes: 2)
        let mden = midBin.boxBlurred(radius: rBlur, passes: 2)
        var midDisp = disparity
        for p in 0..<(W * H) where midBin.pixels[p] > 0.5 {
            midDisp.pixels[p] = mden.pixels[p] > 0.01 ? mnum.pixels[p] / mden.pixels[p] : disparity.pixels[p]
        }
        let midDil = midBin.dilated(radius: extR)
        let midDispDil = midDisp.dilated(radius: extR)
        for p in 0..<(W * H) where midDil.pixels[p] > 0.5 && midBin.pixels[p] < 0.5 {
            midDisp.pixels[p] = midDispDil.pixels[p]
        }
        var midRGBA = FloatImage(width: W, height: H, channels: 4)
        for p in 0..<(W * H) {
            midRGBA.pixels[p * 4 + 0] = color.pixels[p * 4 + 0]; midRGBA.pixels[p * 4 + 1] = color.pixels[p * 4 + 1]
            midRGBA.pixels[p * 4 + 2] = color.pixels[p * 4 + 2]; midRGBA.pixels[p * 4 + 3] = midMatte.pixels[p]
        }
        // 远景背景 = 去除(主体 ∪ 近景背景)后填充：颜色竖直填充，深度远侧 push-pull。
        var farValid = FloatImage(width: W, height: H, channels: 1)
        for p in 0..<(W * H) { farValid.pixels[p] = (subj.pixels[p] > 0.5 || midBin.pixels[p] > 0.5) ? 0 : 1 }
        // 远景层颜色直接复用主背景填充(含树的全背景)，近景树移开后露出的是树而非灰路；
        // 远景的「深度」仍按远侧填充(farValid)保持分层。也少跑一次填充更快。
        let farColorImg = bgColorImg
        let farValidSmall = farValid.resized(to: iw, to: ih)
        let farDepthImg = DisocclusionInpainter.pushPullFill(dispSmall, valid: farValidSmall).resized(to: W, to: H)
        var multiLayer: Photo3DScene.MultiLayer?
        if let midMesh = MeshBuilder.build(width: W, height: H, disparity: midDisp, matte: midMatte, stride: 2, tauCut: 0.05),
           let midColorTex = midRGBA.uploadColorTexture(),
           let midDepthTex = midDisp.uploadScalarTexture(),
           let farColorTex = farColorImg.uploadColorTexture(),
           let farDepthTex = farDepthImg.uploadScalarTexture() {
            multiLayer = Photo3DScene.MultiLayer(
                midColor: midColorTex, midDepth: midDepthTex,
                midIndexBuffer: midMesh.fgIndexBuffer, midIndexCount: midMesh.fgIndexCount,
                farColor: farColorTex, farDepth: farDepthTex,
                midCenter: midCenter)
        }

        // 视差幅度建议：按深度分布的展开度。
        let suggested = suggestedParallax(from: disparity)

        NSLog("[Pipeline] 完成 %dx%d 用时 %.2fs (深度:%@ 主体:%@ 补全:%@ 三角 前景:%d/背景:%d)", W, H,
              CFAbsoluteTimeGetCurrent() - t0, depthResult.source.rawValue, segSource, inpaintSource,
              mesh.fgIndexCount / 3, mesh.bgIndexCount / 3)
        progress(1.0, "完成")
        return Photo3DScene(
            width: W, height: H,
            fgColor: fgColorTex, depth: depthTex,
            bgColor: bgColorTex, bgDepth: bgDepthTex,
            vertexBuffer: mesh.vertexBuffer, gridW: mesh.gridW, gridH: mesh.gridH,
            bgIndexBuffer: mesh.bgIndexBuffer, bgIndexCount: mesh.bgIndexCount,
            fgIndexBuffer: mesh.fgIndexBuffer, fgIndexCount: mesh.fgIndexCount,
            suggestedParallax: suggested,
            depthPreview: nil, maskPreview: nil, backgroundPreview: nil,
            depthSource: depthResult.source.rawValue,
            segmentSource: segSource, inpaintSource: inpaintSource,
            fgCenter: fgCenter,
            multiLayer: multiLayer)
    }

    // MARK: - 辅助

    private func rgb3(_ rgba: FloatImage) -> FloatImage {
        var out = FloatImage(width: rgba.width, height: rgba.height, channels: 3)
        for p in 0..<(rgba.width * rgba.height) {
            out.pixels[p * 3 + 0] = rgba.pixels[p * 4 + 0]
            out.pixels[p * 3 + 1] = rgba.pixels[p * 4 + 1]
            out.pixels[p * 3 + 2] = rgba.pixels[p * 4 + 2]
        }
        return out
    }

    /// 若主体处平均视差小于背景，则翻转深度方向（保证 1=近）。
    private func orientDisparity(_ disp: inout FloatImage, mask: FloatImage) {
        var inSum: Float = 0, inN: Float = 0, outSum: Float = 0, outN: Float = 0
        let n = disp.width * disp.height
        for p in 0..<n {
            if mask.pixels[p] > 0.5 { inSum += disp.pixels[p]; inN += 1 }
            else { outSum += disp.pixels[p]; outN += 1 }
        }
        let inMean = inN > 0 ? inSum / inN : 0
        let outMean = outN > 0 ? outSum / outN : 0
        if inMean < outMean {
            for p in 0..<n { disp.pixels[p] = 1 - disp.pixels[p] }
        }
    }

    /// 取近景（高视差）为前景的软 mask（无系统分割时的兜底）。
    private func nearFieldMask(from disp: FloatImage) -> FloatImage {
        let n = disp.pixels.count
        guard n > 0 else { return FloatImage(width: disp.width, height: disp.height, channels: 1) }
        var sorted = disp.pixels
        sorted.sort()
        let thr = sorted[min(max(Int(Double(n) * 0.62), 0), n - 1)]   // 取最近的 ~38% 作前景候选
        let soft: Float = 0.12
        var out = FloatImage(width: disp.width, height: disp.height, channels: 1)
        for p in 0..<n {
            out.pixels[p] = smoothStep(thr - soft, thr + soft, disp.pixels[p])
        }
        return out
    }

    private func suggestedParallax(from disp: FloatImage) -> Float {
        let n = disp.pixels.count
        let mean = disp.pixels.reduce(0, +) / Float(n)
        var varSum: Float = 0
        for v in disp.pixels { let d = v - mean; varSum += d * d }
        let std = sqrt(varSum / Float(n))
        // std 越大（深度层次越分明），默认视差可越大。
        return min(1.0, max(0.4, std * 3.0))
    }
}

@inline(__always) func smoothStep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(1, max(0, (x - a) / max(b - a, 1e-5)))
    return t * t * (3 - 2 * t)
}
