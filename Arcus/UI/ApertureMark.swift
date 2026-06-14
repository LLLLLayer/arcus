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

/// 光圈环带：外圆挖去中心的多边形孔（even-odd 填充得到环带），用于铺彩虹叶片。可动画（孔径/旋转）。
private struct ApertureRing: Shape {
    var holeScale: CGFloat
    var swirl: Double
    var sides: Int = 6
    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(holeScale, swirl) }
        set { holeScale = newValue.first; swirl = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let R = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        p.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
        let n = max(3, sides)
        let r = R * holeScale
        for i in 0..<n {
            let a = (Double(i) * 360.0 / Double(n) - 90 + swirl) * .pi / 180
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

/// 多边形孔（N 边形，半径 = scale·R，可旋转），用于光圈内缘描边等，可动画。
struct PolyHole: Shape {
    var sides: Int = 6
    var scale: CGFloat
    var rotationDegrees: Double
    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(scale, rotationDegrees) }
        set { scale = newValue.first; rotationDegrees = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let n = max(3, sides)
        let r = min(rect.width, rect.height) / 2 * scale
        var p = Path()
        for i in 0..<n {
            let a = (Double(i) * 360.0 / Double(n) - 90 + rotationDegrees) * .pi / 180
            let pt = CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// 机械相机光圈：`progress` 0→1 时，多边形开口一边旋转一边张开（叶片直边收向边缘），露出中心——
/// 像真实镜头光圈打开。金属镜筒 + 叶片内缘阴影 + 直边，机械感强；配 spring 有精准的开合动感。
struct IrisAperture: View {
    var progress: Double
    var sides: Int = 7   // 7 片叶（奇数叶光圈更像真实镜头）

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let hole = 0.16 + 0.92 * CGFloat(progress)   // 闭合 → 张开（略超出边缘，叶片全收）
            let rot = 12 + 64 * progress                 // 机械旋转开合
            ZStack {
                // 金属镜筒外圈
                Circle()
                    .strokeBorder(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.10), Color(white: 0.22)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing),
                                  lineWidth: s * 0.06)
                    .background(Circle().fill(Color(white: 0.06)))
                // 彩虹叶片环（中心多边形孔随 progress 张开；even-odd 得环带）
                ApertureRing(holeScale: hole, swirl: rot, sides: sides)
                    .fill(AngularGradient(gradient: Gradient(colors: Theme.rainbowColors),
                                          center: .center, angle: .degrees(rot)),
                          style: FillStyle(eoFill: true))
                // 叶片层叠的径向阴影（金属感）：内深外浅
                ApertureRing(holeScale: hole, swirl: rot, sides: sides)
                    .fill(RadialGradient(colors: [.black.opacity(0.55), .clear],
                                         center: .center, startRadius: s * hole * 0.5, endRadius: s * 0.5),
                          style: FillStyle(eoFill: true))
                    .blendMode(.multiply)
                // 叶片内缘：深色厚度阴影 + 细高光，做出机械叶片层叠
                PolyHole(sides: sides, scale: hole, rotationDegrees: rot)
                    .stroke(.black.opacity(0.55), lineWidth: s * 0.02)
                PolyHole(sides: sides, scale: hole, rotationDegrees: rot)
                    .stroke(.white.opacity(0.22), lineWidth: max(1, s * 0.006))
                // 外圈细高光
                Circle().strokeBorder(.white.opacity(0.20), lineWidth: max(1, s * 0.01))
            }
            .frame(width: s, height: s)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}
