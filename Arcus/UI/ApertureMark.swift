import SwiftUI

/// 正六边形（可旋转，默认顶点朝上）——相机光圈的开口形状。
struct Hexagon: Shape {
    var rotationDegrees: Double = 0
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var p = Path()
        for i in 0..<6 {
            let a = (Double(i) * 60 - 90 + rotationDegrees) * .pi / 180
            let pt = CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// 光圈环带：外圆挖去中心的六边形孔（even-odd 填充得到环带），用于铺彩虹叶片。
private struct ApertureRing: Shape {
    var holeScale: CGFloat
    var swirl: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let R = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        p.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
        let r = R * holeScale
        for i in 0..<6 {
            let a = (Double(i) * 60 - 90 + swirl) * .pi / 180
            let pt = CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// 七彩相机光圈标记——直接呼应 App 图标（彩虹光圈）。用作首页 logo、快门环、加载指示等，
/// 把图标的视觉语言带进界面。纯矢量、深浅色通用。
struct ApertureMark: View {
    var swirl: Double = 16          // 叶片旋转，做出风车/光圈感
    var holeScale: CGFloat = 0.46   // 中心开口相对直径
    var centerGlass: Bool = true    // 中心是否画一颗玻璃「眼」（logo 用；快门置 false 露出白心）

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let rHole = s * holeScale / 2
            let R = s / 2
            ZStack {
                // 彩虹环带（叶片）
                ApertureRing(holeScale: holeScale, swirl: swirl)
                    .fill(AngularGradient(gradient: Gradient(colors: Theme.rainbowColors),
                                          center: .center, angle: .degrees(swirl)),
                          style: FillStyle(eoFill: true))
                // 叶片分隔线（沿六边形顶点向外）
                ForEach(0..<6, id: \.self) { i in
                    Capsule().fill(Color.black.opacity(0.26))
                        .frame(width: max(1, s * 0.018), height: R - rHole)
                        .offset(y: -(rHole + (R - rHole) / 2))
                        .rotationEffect(.degrees(Double(i) * 60 + swirl))
                }
                // 外圈高光 + 内孔描边（玻璃感）
                Circle().strokeBorder(.white.opacity(0.30), lineWidth: max(1, s * 0.022))
                Hexagon(rotationDegrees: swirl)
                    .stroke(.white.opacity(0.35), lineWidth: max(1, s * 0.014))
                    .frame(width: rHole * 2, height: rHole * 2)
                // 中心玻璃眼
                if centerGlass {
                    Circle()
                        .fill(RadialGradient(colors: [.white, .white.opacity(0.65), .white.opacity(0)],
                                             center: UnitPoint(x: 0.4, y: 0.35),
                                             startRadius: 0, endRadius: rHole))
                        .frame(width: rHole * 1.5, height: rHole * 1.5)
                }
            }
            .frame(width: s, height: s)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

/// 单片花瓣 / 光圈叶片（底部为尖端朝中心，顶部圆润）。
struct PetalShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w / 2, y: h))                               // 底部尖端（朝中心）
        p.addCurve(to: CGPoint(x: w / 2, y: 0),                           // 顶部
                   control1: CGPoint(x: -w * 0.10, y: h * 0.58),
                   control2: CGPoint(x: w * 0.30, y: h * 0.06))
        p.addCurve(to: CGPoint(x: w / 2, y: h),                           // 回到底部尖端
                   control1: CGPoint(x: w * 0.70, y: h * 0.06),
                   control2: CGPoint(x: w * 1.10, y: h * 0.58))
        p.closeSubpath()
        return p
    }
}

/// 会「绽放」的七彩花瓣光圈：`progress` 0→1 时，花瓣一边旋转一边向外展开、露出中心——
/// 用作「打开相机」的转场（像一朵花旋转转开）。几何全部由 progress 推导，配 spring 即有回弹动感。
struct BloomingAperture: View {
    var progress: Double
    var bladeCount: Int = 6

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let petalH = s * 0.42
            let petalW = s * 0.36
            let r = s * 0.02 + s * 0.30 * CGFloat(progress)     // 中心半径：闭合→展开
            let spin = progress * 178.0                          // 整体旋转转开
            let unfurl = progress * 26.0                         // 花瓣外翻
            let n = max(3, bladeCount)
            ZStack {
                ForEach(0..<n, id: \.self) { i in
                    let col = Theme.rainbowColors[i % (Theme.rainbowColors.count - 1)]
                    PetalShape()
                        .fill(LinearGradient(colors: [col.opacity(0.96), col, col.opacity(0.78)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(PetalShape().stroke(.white.opacity(0.30), lineWidth: max(1, s * 0.006)))
                        .frame(width: petalW, height: petalH)
                        .rotationEffect(.degrees(unfurl), anchor: .bottom)
                        .offset(y: -(r + petalH / 2))
                        .rotationEffect(.degrees(Double(i) * 360.0 / Double(n) + spin))
                        .shadow(color: col.opacity(0.5), radius: s * 0.03)
                }
                // 中心玻璃眼：闭合时明显，绽放时缩小让出中心
                Circle()
                    .fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center,
                                         startRadius: 0, endRadius: s * 0.12))
                    .frame(width: s * 0.18 * (1 - CGFloat(progress) * 0.85),
                           height: s * 0.18 * (1 - CGFloat(progress) * 0.85))
            }
            .frame(width: s, height: s)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}
