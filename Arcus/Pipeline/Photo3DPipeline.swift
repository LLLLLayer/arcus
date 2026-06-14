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
    case cloud       // Gemini 云端生成补全（可选、需 Key、联网；缺 Key/失败回退 PatchMatch）

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast: return String(localized: "Fast")
        case .patchMatch: return "PatchMatch"
        case .migan: return String(localized: "AI Fill")
        case .cloud: return String(localized: "Cloud")
        }
    }
    var detail: String {
        switch self {
        case .fast: return String(localized: "Vertical continuation, depth-gated, real-time")
        case .patchMatch: return String(localized: "Content-aware, more coherent but slower (~10+ s)")
        case .migan: return String(localized: "MI-GAN neural generation, on-device, slower")
        case .cloud: return String(localized: "Gemini cloud generation, needs an API key, uploads each photo")
        }
    }
    var source: String {
        switch self { case .fast: return "vertical+depth"; case .patchMatch: return "PatchMatch+depth"; case .migan: return "MI-GAN"; case .cloud: return "Gemini cloud" }
    }
}

final class Photo3DPipeline {

    struct Options {
        var maxWorkingSide: Int = 1024
        /// 去遮挡环带半径占长边比例（决定背景被补全的范围，≈最大像素视差）。
        var ringRadiusFraction: Float = 0.045
        /// 背景补全方式：快速 / PatchMatch / MI-GAN。默认快速。
        var fillMode: FillMode = .fast
        /// 是否额外构建 3D 高斯泼溅场景（首页选「高斯泼溅」时为 true）。
        /// 复用同一条管线产物（前景主体 + 完整补全背景）lift 成 3D 高斯，LDI 烘焙照常进行。
        var buildGaussians: Bool = false
        /// 云端背景补全闭包（仅 `.cloud` 且已配置 Gemini Key 时注入）：
        /// (rgb3, 主体洞) → 补全后的整幅背景色(洞内云端生成、洞外真背景)；nil/失败时管线回退 PatchMatch。
        /// 同步签名：在后台管线线程上以信号量阻塞等待这一次网络调用（见 AppModel.cloudFillSync）。
        var cloudFill: ((FloatImage, FloatImage) -> FloatImage?)? = nil
    }

    enum PipelineError: Error { case badImage, textureAllocation }

    private let depthEstimator = DepthEstimator()
    private let segmenter = SubjectSegmenter()
    private let lamaInpainter = LamaInpainter()
    private let miganInpainter = MiganInpainter()

    var isDepthModelAvailable: Bool { depthEstimator.isModelAvailable }
    var isLamaAvailable: Bool { lamaInpainter.isAvailable }

    /// 「重拍·补全这一视角」的补全入口：LaMa 优先（FFC 擅长外扩），失败/缺失回退 MI-GAN。
    /// 复用常驻实例 ⇒ 模型只在首次补全时加载一次，而不是每次点按钮都重新加载（秒级开销）。
    func reframeInpaint(rgb: FloatImage, hole: FloatImage) -> FloatImage? {
        lamaInpainter.inpaint(rgb: rgb, hole: hole) ?? miganInpainter.inpaint(rgb: rgb, hole: hole)
    }

    func process(image: UIImage,
                 avDepth: AVDepthData? = nil,
                 options: Options = Options(),
                 progress: @escaping (Double, String) -> Void) throws -> Photo3DScene {

        let t0 = CFAbsoluteTimeGetCurrent()
        progress(0.05, String(localized: "Preprocessing image…"))
        guard let work = ImageUtils.workingImage(from: image, maxSide: options.maxWorkingSide) else {
            throw PipelineError.badImage
        }
        let cg = work.cg, W = work.width, H = work.height
        let color = FloatImage.fromCGImage(cg, width: W, height: H)   // rgba

        // 取消检查放在各阶段边界：用户取消后尽快退出（PatchMatch/MI-GAN 模式整条管线 10s+）。
        try Task.checkCancellation()
        progress(0.20, String(localized: "Estimating depth…"))
        let depthResult = depthEstimator.estimate(cgImage: cg, width: W, height: H, avDepth: avDepth)
        var disparity = depthResult.disparity

        try Task.checkCancellation()
        progress(0.45, String(localized: "Segmenting subject…"))
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
            // 无系统分割：先用「画面下部通常更近」启发式校正远近方向（模型/来源输出方向不一），
            // 再阈值取近景为前景——方向反了 nearFieldMask 会把远景当主体。
            orientDisparityBottomNear(&disparity)
            mask = nearFieldMask(from: disparity)
            segSource = SubjectSegmenter.Source.none.rawValue
        }

        // 剪影抗锯齿（关键）：Vision 实例 mask 是低分辨率上采样来的，边界是一条很粗的「像素台阶」
        // （在调试「主体」图层放大可见，约 ~10px 阶梯）。片元 fwidth AA 只能软化过渡「厚度」，
        // 扶不直台阶「走向」；小半径模糊也跨不过这么粗的台阶 → 必须把边界重新「吸附」到真实边缘。
        //
        // 用 joint-bilateral 式 guided upsampling：半径取得比台阶块更大(~W/130)，才能跨过整段台阶、
        // 把边界吸到全分辨率真实边缘；eps 极小=强吸边。**用 RGB 三通道彩色引导**而非单亮度：
        // 浅灰杯/浅灰墙这类「亮度相近但有微弱色差」的低对比边界，亮度引导吸不住、只剩台阶，
        // 彩色引导能利用色差吸边；真的无色差的平坦处则自动退化为局部均值，把台阶磨成平滑斜坡。
        mask = mask.guidedRefinedColor(guide: color, radius: max(3, W / 130), eps: 1e-4)
        // 残余台阶用一遍小低通抹平成平滑斜坡，再 smoothStep 收回 ~2px 细带：
        // 中点仍是 0.5 ⇒ 剪影位置不变、补全色不从半透带透出成光晕，但 0.5 等值线已是平滑曲线 ⇒ 配 fwidth AA 得干净边。
        mask = mask.boxBlurred(radius: max(2, W / 360), passes: 2)
        for p in 0..<(W * H) { mask.pixels[p] = smoothStep(0.42, 0.58, mask.pixels[p]) }

        // 边缘保持式深度去噪（中值）——保留深度断层，替代会糊掉悬崖的方框模糊。
        disparity = disparity.median3()

        try Task.checkCancellation()
        progress(0.62, String(localized: "Filling the background behind the subject…"))

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
        var bgFilledByNeural = false   // 仅当 MI-GAN/Cloud「真的」生成了虚构内容时为真 ⇒ 决定背景深度走重估而非 push-pull
        switch options.fillMode {
        case .migan:
            progress(0.62, String(localized: "AI-filling the background (MI-GAN, on-device)…"))
            // 把洞(主体)小幅外扩再喂给 MI-GAN，确保人被完全盖住——否则模型看到边缘的人像残片(发丝/衣角)
            // 会把人「续」进可见带里。外扩环带在静止时被前景遮住、动起来正是要生成的带，故只赚不亏。
            let migHole = subj.dilated(radius: max(6, W / 100))
            if let mig = miganInpainter.inpaint(rgb: rgbColor, hole: migHole) {
                bgColorImg = mig
                inpaintSource = "MI-GAN"
                bgFilledByNeural = true
            } else {
                bgColorImg = DisocclusionInpainter.patchMatchFill(rgbColor, valid: validFull, disparity: disparity)
                inpaintSource = "PatchMatch+depth (MI-GAN unavailable)"
            }
        case .cloud:
            // 同 MI-GAN：把洞(主体)小幅外扩再交给云端，确保主体被完全盖住、生成的是身后背景。
            let cloudHole = subj.dilated(radius: max(6, W / 100))
            if let cloudFill = options.cloudFill {           // 已配置 Key 才联网；否则直接走 PatchMatch（消息不误报「云端」）
                progress(0.62, String(localized: "Cloud-filling the background (Gemini)…"))
                if let cloud = cloudFill(rgbColor, cloudHole) {
                    bgColorImg = cloud
                    inpaintSource = "Gemini cloud"
                    bgFilledByNeural = true
                } else {
                    bgColorImg = DisocclusionInpainter.patchMatchFill(rgbColor, valid: validFull, disparity: disparity)
                    inpaintSource = "PatchMatch+depth (cloud failed)"
                }
            } else {
                progress(0.62, String(localized: "High-quality background fill (PatchMatch, depth-aware, slower)…"))
                bgColorImg = DisocclusionInpainter.patchMatchFill(rgbColor, valid: validFull, disparity: disparity)
                inpaintSource = "PatchMatch+depth (no API key)"
            }
        case .patchMatch:
            progress(0.62, String(localized: "High-quality background fill (PatchMatch, depth-aware, slower)…"))
            bgColorImg = DisocclusionInpainter.patchMatchFill(rgbColor, valid: validFull, disparity: disparity)
            inpaintSource = "PatchMatch+depth"
        case .fast:
            bgColorImg = DisocclusionInpainter.verticalFill(rgbColor, valid: validFull, disparity: disparity)
            inpaintSource = "vertical+depth"
        }

        // 背景深度：洞(主体区)需要一张「合适的深度」。
        // MI-GAN 模式：旧做法 planarFill 把洞拍平成单一平面 ⇒ 站立人物脚下「本应继续延伸的地面/小路」
        //   被摆到平面深度上，视差一动就和真实地面错开、像贴片浮起（用户反馈：底部补的东西和原图层不在一起）。
        //   改为**对补全后的彩色图重新估计一遍深度**：MI-GAN 生成的内容由此获得「与画面连续、且与所画内容一致」
        //   的真实深度——脚下小路会被估成向远处递退的渐变，正好接上真实地面，不再错层。
        // 普通模式：push-pull 平滑扩散（从边界向洞内传播真实深度，连续）。
        try Task.checkCancellation()
        let inpaintSide = 640
        let s = Float(inpaintSide) / longSide
        let iw = max(2, Int((Float(W) * s).rounded()))
        let ih = max(2, Int((Float(H) * s).rounded()))
        let dispSmall = disparity.resized(to: iw, to: ih)
        let validSmall = validFull.resized(to: iw, to: ih)
        // MI-GAN 与 Cloud 真正生成了「无深度的虚构内容」⇒ 对补全后的彩色图重估一遍深度（与画面连续）。
        // 回退到 PatchMatch/竖直延续(真背景)时走 push-pull 扩散，更贴合真实背景层。
        let bgDepthImg: FloatImage
        if bgFilledByNeural, let filledCG = bgColorImg.toCGImage() {
            var reEst = depthEstimator.estimate(cgImage: filledCG, width: W, height: H, avDepth: nil).disparity
            reEst = reEst.median3()
            bgDepthImg = depthAlignedHoleFill(original: disparity, reEstimated: reEst, hole: subj)
        } else if bgFilledByNeural {
            bgDepthImg = DisocclusionInpainter.planarFill(disparity, valid: validFull)   // 兜底：转 CGImage 失败
        } else {
            bgDepthImg = DisocclusionInpainter.pushPullFill(dispSmall, valid: validSmall).resized(to: W, to: H)
        }

        try Task.checkCancellation()
        progress(0.85, String(localized: "Baking 3D mesh…"))

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
        // 同时累计主体平均视差 dSubj，用于：① 自适应视差支点(主体锚定、背景扫动)；② 各层按深度比例放大。
        var cxSum: Double = 0, cySum: Double = 0, cN: Double = 0, dSubjSum: Double = 0
        for y in 0..<H {
            for x in 0..<W where subj.pixels[y * W + x] > 0.5 {
                cxSum += Double(x); cySum += Double(y); cN += 1
                dSubjSum += Double(disparity.pixels[y * W + x])
            }
        }
        let fgCenter = cN > 0
            ? SIMD2<Float>(Float(cxSum / cN) / Float(W), Float(cySum / cN) / Float(H))
            : SIMD2<Float>(0.5, 0.5)
        let dSubj = cN > 0 ? Float(dSubjSum / cN) : 0.75   // 主体平均视差(1=近)

        // 自适应视差支点：从 0.5 偏向主体深度的一半 ⇒ 主体近乎锚定、越往深处的背景扫动越大(深层运镜)。
        // 半混合(0.5)兼顾：主体仍保留少量平移、背景去遮挡不过度扩大。
        let depthPivot = min(0.85, max(0.4, 0.5 + 0.5 * (dSubj - 0.5)))

        // 把「补全区掩膜」烤进背景层 alpha：subj=1 处即主体footprint=处理时被填充的像素。
        // 正常渲染从不读 bg.alpha（背景 alpha 恒置 1），故无副作用；仅供「重拍·补全主体背后」识别哪些是烤进去的填充。
        var bgColor4 = FloatImage(width: W, height: H, channels: 4)
        for p in 0..<(W * H) {
            bgColor4.pixels[p * 4 + 0] = bgColorImg.pixels[p * 3 + 0]
            bgColor4.pixels[p * 4 + 1] = bgColorImg.pixels[p * 3 + 1]
            bgColor4.pixels[p * 4 + 2] = bgColorImg.pixels[p * 3 + 2]
            bgColor4.pixels[p * 4 + 3] = subj.pixels[p] > 0.5 ? 1 : 0
        }

        guard let depthTex = fgDisp.uploadScalarTexture(),
              let fgColorTex = fg.uploadColorTexture(),
              let bgColorTex = bgColor4.uploadColorTexture(),
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
        // 优化：高斯泼溅模式查看走 3DGS、不用 LDI 多层背景，跳过这段重 CPU（pushPull×2 + 第二次建网格）省数秒。
        var multiLayer: Photo3DScene.MultiLayer?
        if !options.buildGaussians {
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
        // 同时累计近景背景平均视差 dMid，用于按深度比例决定放大系数。
        var mcx: Double = 0, mcy: Double = 0, mcN: Double = 0, dMidSum: Double = 0
        for y in 0..<H {
            for x in 0..<W where midBin.pixels[y * W + x] > 0.5 {
                mcx += Double(x); mcy += Double(y); mcN += 1
                dMidSum += Double(disparity.pixels[y * W + x])
            }
        }
        let midCenter = mcN > 0
            ? SIMD2<Float>(Float(mcx / mcN) / Float(W), Float(mcy / mcN) / Float(H))
            : SIMD2<Float>(0.5, 0.5)
        let dMid = mcN > 0 ? Float(dMidSum / mcN) : 0.4
        // 中间层放大系数 = 按深度比例(越远越小)。用 (dMid/dSubj)² 让远层掉得更快(用户：离得远的倍率别太高)。
        let midRatio = dSubj > 1e-3 ? min(1, max(0, dMid / dSubj)) : 0.4
        let midScaleFactor = midRatio * midRatio
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
        // 远景背景 = 去除(主体 ∪ 近景背景)后填充：颜色 + 深度都补，近景背景层移开后露出的是「身后的远景」。
        var farValid = FloatImage(width: W, height: H, channels: 1)
        for p in 0..<(W * H) { farValid.pixels[p] = (subj.pixels[p] > 0.5 || midBin.pixels[p] > 0.5) ? 0 : 1 }
        // 远景层颜色：在 bgColorImg(已补主体)基础上，把「近景背景」区域也补掉——否则该区仍是近景原像素，
        // 近景层 parallax 移开后露出的会是它自己的重影(树移开还是树)。
        // 关键：这里**必须用平滑扩散填充(push-pull)，不能用竖直/PatchMatch**——后者是高频条纹/接缝，
        // 近景层缩放放大+视差一移开就会在主体旁露出「明显的线条」。push-pull 给柔和模糊(远景本就虚)，
        // 即便被露出也只是糊一点，绝不出现条纹。主体区保留 bgColorImg(按填充模式的清晰补全)不动。
        var farColorValid = FloatImage(width: W, height: H, channels: 1)
        for p in 0..<(W * H) { farColorValid.pixels[p] = midBin.pixels[p] > 0.5 ? 0 : 1 }
        let farColorImg = DisocclusionInpainter.pushPullFill(bgColorImg, valid: farColorValid)
        let farValidSmall = farValid.resized(to: iw, to: ih)
        let farDepthImg = DisocclusionInpainter.pushPullFill(dispSmall, valid: farValidSmall).resized(to: W, to: H)
        if let midMesh = MeshBuilder.build(width: W, height: H, disparity: midDisp, matte: midMatte, stride: 2, tauCut: 0.05),
           let midColorTex = midRGBA.uploadColorTexture(),
           let midDepthTex = midDisp.uploadScalarTexture(),
           let farColorTex = farColorImg.uploadColorTexture(),
           let farDepthTex = farDepthImg.uploadScalarTexture() {
            multiLayer = Photo3DScene.MultiLayer(
                midColor: midColorTex, midDepth: midDepthTex,
                midIndexBuffer: midMesh.fgIndexBuffer, midIndexCount: midMesh.fgIndexCount,
                farColor: farColorTex, farDepth: farDepthTex,
                midCenter: midCenter, midScaleFactor: midScaleFactor)
        }
        }   // end if !options.buildGaussians

        // 视差幅度建议：按深度分布的展开度。
        let suggested = suggestedParallax(from: disparity)

        // ===== 3D 高斯泼溅（可选）：从已算好的前景/背景 FloatImage 直接 lift（零新模型、全离线）=====
        // 背景层 = 完整补全背景(bgColorImg+bgDepthImg)；前景层 = 主体像素(color+fgDisp，matte 当不透明度)。
        var gaussianScene: GaussianScene?
        if options.buildGaussians {
            try Task.checkCancellation()
            progress(0.92, String(localized: "Building 3D Gaussians…"))
            gaussianScene = GaussianSplatBuilder.build(
                color: color, fgDisp: fgDisp, matte: fgAField,
                bgColor: bgColorImg, bgDisp: bgDepthImg,
                depthPivot: depthPivot, suggestedParallax: suggested)
        }

        NSLog("[Pipeline] done %dx%d in %.2fs (depth:%@ subject:%@ fill:%@ tris fg:%d/bg:%d)", W, H,
              CFAbsoluteTimeGetCurrent() - t0, depthResult.source.rawValue, segSource, inpaintSource,
              mesh.fgIndexCount / 3, mesh.bgIndexCount / 3)
        progress(1.0, String(localized: "Done"))
        return Photo3DScene(
            width: W, height: H,
            fgColor: fgColorTex, depth: depthTex,
            bgColor: bgColorTex, bgDepth: bgDepthTex,
            vertexBuffer: mesh.vertexBuffer, gridW: mesh.gridW, gridH: mesh.gridH,
            bgIndexBuffer: mesh.bgIndexBuffer, bgIndexCount: mesh.bgIndexCount,
            fgIndexBuffer: mesh.fgIndexBuffer, fgIndexCount: mesh.fgIndexCount,
            suggestedParallax: suggested,
            depthPreview: nil, maskPreview: nil, backgroundPreview: nil,
            depthSource: locSource(depthResult.source.rawValue),
            segmentSource: locSource(segSource), inpaintSource: locSource(inpaintSource),
            fgCenter: fgCenter,
            depthPivot: depthPivot,
            multiLayer: multiLayer,
            gaussianScene: gaussianScene)
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

    /// 无 mask 可参考时的方向校正：自然照片下 1/3（地面/近景）几乎总比上 1/3（天空/远景）近，
    /// 若下部平均视差反而更小则整体翻转（保证 1=近）。
    private func orientDisparityBottomNear(_ disp: inout FloatImage) {
        let w = disp.width, h = disp.height
        let third = h / 3
        guard third > 0 else { return }
        var top: Float = 0, bottom: Float = 0
        for y in 0..<third {
            for x in 0..<w { top += disp.pixels[y * w + x] }
        }
        for y in (h - third)..<h {
            for x in 0..<w { bottom += disp.pixels[y * w + x] }
        }
        if bottom < top {
            for p in 0..<(w * h) { disp.pixels[p] = 1 - disp.pixels[p] }
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

    /// 把「对补全图重新估计的深度」对齐到原视差，并只在洞(主体区)内替换，边界羽化无缝。
    /// - 有效区(洞外)做最小二乘拟合 a·reEst + b ≈ original：统一尺度、并自动处理朝向翻转(a 可负)；
    /// - 洞内用对齐后的重估深度，洞外保留原深度，主体边界用羽化权重平滑过渡。
    private func depthAlignedHoleFill(original: FloatImage, reEstimated: FloatImage, hole: FloatImage) -> FloatImage {
        let n = original.pixels.count
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, cnt = 0.0
        for p in 0..<n where hole.pixels[p] < 0.5 {
            let x = Double(reEstimated.pixels[p]), y = Double(original.pixels[p])
            sx += x; sy += y; sxx += x * x; sxy += x * y; cnt += 1
        }
        var a: Float = 1, b: Float = 0
        if cnt > 1 {
            let denom = cnt * sxx - sx * sx
            if abs(denom) > 1e-9 {
                a = Float((cnt * sxy - sx * sy) / denom)
                b = Float((sy - Double(a) * sx) / cnt)
            }
        }
        // 羽化洞掩膜：边界几像素平滑过渡（对齐后 aligned≈original，过渡处无缝）。
        let holeW = hole.boxBlurred(radius: max(2, original.width / 200), passes: 2)
        var out = original
        for p in 0..<n {
            let aligned = max(0, min(1, a * reEstimated.pixels[p] + b))
            let w = holeW.pixels[p]
            out.pixels[p] = (1 - w) * original.pixels[p] + w * aligned
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

/// 把来源信息里的中文枚举值映射到本地化字符串（仅用于来源信息胶囊；NSLog 仍用原始 rawValue）。
func locSource(_ s: String) -> String {
    switch s {
    case "Pseudo-depth (fallback)": return String(localized: "Pseudo-depth (fallback)")
    case "Foreground subject instance": return String(localized: "Foreground subject instance")
    case "Person segmentation": return String(localized: "Person segmentation")
    case "Depth-threshold approximation": return String(localized: "Depth-threshold approximation")
    case "PatchMatch+depth (MI-GAN unavailable)": return String(localized: "PatchMatch+depth (MI-GAN unavailable)")
    default: return s
    }
}

@inline(__always) func smoothStep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(1, max(0, (x - a) / max(b - a, 1e-5)))
    return t * t * (3 - 2 * t)
}
