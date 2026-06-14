import Foundation
import UIKit

/// 可选的 Google Gemini 云端「视角修复」——把选定机位的 3DGS 渲染（含露出区/拉伸/破碎）交给
/// Gemini 生成式补成一张干净成片。**完全可选**：不填 Key 时 App 走端侧 LaMa/MI-GAN 修复（离线）。
/// 仿 OpenReshot 的 generateContent 流程，但 Arcus 默认离线、Key 由用户自带、仅此一步可联网。
enum GeminiRepair {

    /// 默认图像模型（用户可在设置里改）。对齐 OpenReshot 的较新图像模型。
    static let defaultModel = "gemini-3.1-flash-image"

    /// 修复 prompt（中英双语）：只修渲染瑕疵、保持构图/视角/主体/光色不变、保人物原样。
    static let prompt = """
    This image is a novel-view render from a 3D Gaussian Splatting reconstruction of a photo. \
    Because the camera viewpoint moved, some newly exposed edges, disoccluded regions, stretched or \
    warped areas, holes, and blurry splat artifacts may appear. Repair ONLY those rendering artifacts: \
    turn blurry splat regions into clear coherent detail, fix warped/stretched/distorted areas, and \
    complete missing or broken parts with realistic detail consistent with the surrounding scene. \
    Keep the SAME camera framing, perspective, subject placement, lighting, colors, materials and layout. \
    Do not restyle, beautify, replace, or add new objects. If people are visible, preserve them exactly \
    (same identity, appearance, hair, clothing, pose, expression). Output one single clean, sharp photo.
    这是 3DGS 新视角渲染：把模糊变清晰，修正拉伸/变形/露底/空洞/破碎，补全缺失，\
    但保持原主体、视角、透视、布局、光线与颜色不变；画面中若有人物必须保持原样。
    """

    /// 云端「背景补全」prompt：把平涂灰色剪影标出的前景主体移除、生成身后背景。
    /// 与「视角修复」是不同任务（那是修渲染瑕疵），故用独立 prompt；首页 Cloud Fill 用。
    static let fillPrompt = """
    This photo has a flat gray silhouette covering a foreground subject that must be removed. \
    Reconstruct ONLY the area under the gray silhouette: fill it with the background that would \
    naturally continue behind the subject — extend the surrounding textures, edges, surfaces and \
    lighting so the gray region disappears seamlessly. Keep everything OUTSIDE the gray silhouette \
    exactly as-is (same framing, perspective, colors, lighting). Do not add people, objects or text. \
    Output one single clean photo of the scene with the foreground subject gone.
    这张图里有一块平涂灰色的前景主体剪影，需要被移除。只重建灰色区域：用主体身后本应延续的背景填满它，\
    延展周围的纹理、边缘、表面与光照，让灰块自然消失；灰块以外保持原样。不要新增人物、物体或文字。输出一张干净的成片。
    """

    enum RepairError: LocalizedError {
        case encode, badResponse(String), noImage(String)
        var errorDescription: String? {
            switch self {
            case .encode: return "Image encoding failed"
            case .badResponse(let s): return "Gemini returned an error: \(s)"
            case .noImage(let s): return "Gemini returned no image: \(s)"
            }
        }
    }

    /// 把一张已合成好的视角帧发给 Gemini，返回修复后的图片。
    static func repair(image: UIImage, key: String, model: String) async throws -> UIImage {
        try await run(image: image, prompt: prompt, key: key, model: model)
    }

    /// 云端背景补全：传入「灰色剪影标出待移除主体」的图，返回主体被移除、背景补全后的图。
    static func fillBackground(image: UIImage, key: String, model: String) async throws -> UIImage {
        try await run(image: image, prompt: fillPrompt, key: key, model: model)
    }

    /// 通用 generateContent 调用：图 + prompt → 生成图。`repair`/`fillBackground` 共用同一套 HTTP 管线。
    private static func run(image: UIImage, prompt: String, key: String, model: String) async throws -> UIImage {
        guard let png = downscaledPNG(image, maxSide: 1024) else { throw RepairError.encode }
        let m = model.trimmingCharacters(in: .whitespaces).isEmpty ? defaultModel : model
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        var comps = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(m):generateContent")!
        comps.queryItems = [URLQueryItem(name: "key", value: trimmedKey)]
        guard let url = comps.url else { throw RepairError.encode }

        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [
                    ["text": prompt],
                    ["inlineData": ["mimeType": "image/png", "data": png.base64EncodedString()]]
                ]
            ]],
            "generationConfig": [
                "responseModalities": ["IMAGE", "TEXT"],
                "thinkingConfig": ["thinkingLevel": "MINIMAL"],   // 降延迟
                "imageConfig": ["imageSize": "1K"]                 // 出图尺寸
            ]
        ]
        var req = URLRequest(url: url, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.upload(for: req, from: req.httpBody ?? Data())
        guard let http = response as? HTTPURLResponse else { throw RepairError.badResponse("Invalid response") }
        guard (200..<300).contains(http.statusCode) else {
            throw RepairError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard let img = imageFromResponse(data) else {
            throw RepairError.noImage(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return img
    }

    // MARK: - 工具

    private static func downscaledPNG(_ image: UIImage, maxSide: CGFloat) -> Data? {
        let w = image.size.width * image.scale, h = image.size.height * image.scale
        let ratio = min(1, maxSide / max(w, h, 1))
        let size = CGSize(width: w * ratio, height: h * ratio)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let out = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return out.pngData()
    }

    /// 递归在 JSON 里找 candidates→content→parts→inlineData.data 的 base64 图片。
    private static func imageFromResponse(_ data: Data) -> UIImage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return findImage(root)
    }

    private static func findImage(_ any: Any) -> UIImage? {
        if let dict = any as? [String: Any] {
            for k in ["inlineData", "inline_data"] {
                if let inl = dict[k] as? [String: Any], let s = inl["data"] as? String, let img = decode(s) {
                    return img
                }
            }
            for (_, v) in dict { if let img = findImage(v) { return img } }
        } else if let arr = any as? [Any] {
            for v in arr { if let img = findImage(v) { return img } }
        } else if let s = any as? String, s.count > 256, let img = decode(s) {
            return img
        }
        return nil
    }

    private static func decode(_ s: String) -> UIImage? {
        var str = s
        if let comma = s.range(of: ","), s[..<comma.lowerBound].contains("base64") {
            str = String(s[comma.upperBound...])
        }
        guard let d = Data(base64Encoded: str, options: [.ignoreUnknownCharacters]) else { return nil }
        return UIImage(data: d)
    }
}
