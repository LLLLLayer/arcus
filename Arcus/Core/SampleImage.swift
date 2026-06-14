import UIKit

/// 默认示例图：优先用内置的高鲜艳度实拍照（金刚鹦鹉，主体/背景分离明显，最能体现 3D 深度，来源 Unsplash 免费授权）；
/// 缺失时回退到程序化生成图（渐变天空 + 地面 + 球体），保证永不崩。
enum SampleImage {
    static func make(width: Int = 900, height: Int = 1200) -> UIImage {
        if let bundled = UIImage(named: "SampleParrot") { return bundled }
        return procedural(width: width, height: height)
    }

    /// 程序化兜底图：渐变天空 + 地面 + 一个近景“主体”（球体）。
    private static func procedural(width: Int, height: Int) -> UIImage {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { rctx in
            let ctx = rctx.cgContext
            // 天空渐变
            let cs = CGColorSpaceCreateDeviceRGB()
            let sky = CGGradient(colorsSpace: cs,
                colors: [UIColor(red: 0.45, green: 0.62, blue: 0.92, alpha: 1).cgColor,
                         UIColor(red: 0.85, green: 0.90, blue: 0.98, alpha: 1).cgColor] as CFArray,
                locations: [0, 1])!
            ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height * 0.7), options: [])

            // 远山
            ctx.setFillColor(UIColor(red: 0.55, green: 0.66, blue: 0.78, alpha: 1).cgColor)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 0, y: size.height * 0.62))
            ctx.addCurve(to: CGPoint(x: size.width, y: size.height * 0.6),
                         control1: CGPoint(x: size.width * 0.3, y: size.height * 0.5),
                         control2: CGPoint(x: size.width * 0.7, y: size.height * 0.7))
            ctx.addLine(to: CGPoint(x: size.width, y: size.height))
            ctx.addLine(to: CGPoint(x: 0, y: size.height))
            ctx.closePath(); ctx.fillPath()

            // 地面
            ctx.setFillColor(UIColor(red: 0.30, green: 0.52, blue: 0.32, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: size.height * 0.72, width: size.width, height: size.height * 0.28))

            // 中景树
            for tx in [0.18, 0.82] {
                let cx = size.width * tx
                ctx.setFillColor(UIColor(red: 0.36, green: 0.26, blue: 0.18, alpha: 1).cgColor)
                ctx.fill(CGRect(x: cx - 8, y: size.height * 0.55, width: 16, height: size.height * 0.2))
                ctx.setFillColor(UIColor(red: 0.20, green: 0.45, blue: 0.24, alpha: 1).cgColor)
                ctx.fillEllipse(in: CGRect(x: cx - 50, y: size.height * 0.45, width: 100, height: 130))
            }

            // 近景主体：橙色球 + 阴影
            let r = size.width * 0.26
            let cx = size.width * 0.5
            let cy = size.height * 0.66
            ctx.setFillColor(UIColor(white: 0, alpha: 0.25).cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - r, y: cy + r * 0.75, width: r * 2, height: r * 0.5))
            let ball = CGGradient(colorsSpace: cs,
                colors: [UIColor(red: 1.0, green: 0.78, blue: 0.35, alpha: 1).cgColor,
                         UIColor(red: 0.92, green: 0.42, blue: 0.16, alpha: 1).cgColor] as CFArray,
                locations: [0, 1])!
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            ctx.clip()
            ctx.drawRadialGradient(ball,
                startCenter: CGPoint(x: cx - r * 0.3, y: cy - r * 0.3), startRadius: 0,
                endCenter: CGPoint(x: cx, y: cy), endRadius: r * 1.4, options: [])
            ctx.restoreGState()
        }
    }
}
