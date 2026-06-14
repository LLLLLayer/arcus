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

/// 单片光圈叶片：直边三角板，按 index 绕中心旋转、与相邻叶片交叠成风车——还原 App 图标里的相机光圈。
/// `openR` = 开口内切半径（到多边形边），`overlap` = 额外扫角(度)使叶片交叠。可动画（openR/swirl）。
struct BladeTriangle: Shape {
    var openR: CGFloat
    var swirl: Double
    var rim: CGFloat
    var sides: Int
    var index: Int
    var overlap: Double
    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(openR, swirl) }
        set { openR = newValue.first; swirl = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let n = max(3, sides)
        let half = 180.0 / Double(n)
        let base = Double(index) * 360.0 / Double(n) + swirl
        let rv = openR / CGFloat(cos(half * .pi / 180))      // 多边形顶点半径
        func polar(_ r: CGFloat, _ deg: Double) -> CGPoint {
            let a = (deg - 90) * .pi / 180
            return CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
        }
        let A = polar(rv, base - half)                       // 开口顶点
        let B = polar(rv, base + half)                       // 下一个开口顶点（内边 A→B）
        let aStart = base + half                             // 叶片前缘（径向出到边缘）
        let aEnd = base - half - overlap                     // 沿边缘扫回，制造交叠
        var p = Path()
        p.move(to: A)
        p.addLine(to: B)
        p.addLine(to: polar(rim, aStart))                    // B 径向出到镜筒边缘
        let steps = 14
        for k in 1...steps {                                 // 外缘沿镜筒圆弧（折线近似），填满到边缘、不留缝
            let ang = aStart + (aEnd - aStart) * Double(k) / Double(steps)
            p.addLine(to: polar(rim, ang))
        }
        p.addLine(to: A)                                     // 回到内侧顶点
        p.closeSubpath()
        return p
    }
}

/// 还原 App 图标的相机光圈：深色玻璃镜筒 + N 片交叠的彩虹直边叶片 + 中心玻璃。
/// `progress` 0→1：开口扩大、叶片收向边缘并旋转 → 像真实镜头光圈打开。
struct BladeIris: View {
    var progress: Double
    var sides: Int = 6

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let rim = s * 0.45
            let openR = s * (0.13 + 0.34 * CGFloat(progress))   // 开口：闭合(小，似图标) → 张开
            let swirl = 8 + 46 * progress
            let n = max(3, sides)
            ZStack {
                // 深色玻璃镜筒
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.17), Color(white: 0.03)],
                                         center: .init(x: 0.42, y: 0.36), startRadius: 0, endRadius: s * 0.5))
                // 交叠叶片（按 index 顺序画，后画的压住前一片 → 风车）
                ForEach(0..<n, id: \.self) { i in
                    let col = Theme.rainbowColors[i % (Theme.rainbowColors.count - 1)]
                    BladeTriangle(openR: openR, swirl: swirl, rim: rim, sides: sides, index: i, overlap: 50)
                        .fill(LinearGradient(colors: [col.opacity(0.98), col.opacity(0.74)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(
                            BladeTriangle(openR: openR, swirl: swirl, rim: rim, sides: sides, index: i, overlap: 50)
                                .stroke(.black.opacity(0.22), lineWidth: max(1, s * 0.004))
                        )
                }
                .clipShape(Circle().inset(by: s * 0.045))   // 叶片裁进镜筒内
                // 中心玻璃（开时缩小淡出，让出镜头）
                Circle()
                    .fill(RadialGradient(colors: [.white, Theme.accentB.opacity(0.75), .clear],
                                         center: .init(x: 0.4, y: 0.35), startRadius: 0, endRadius: openR))
                    .frame(width: openR * 1.15, height: openR * 1.15)
                    .opacity(1 - progress * 0.92)
                // 镜筒：金属边 + 细高光
                Circle().strokeBorder(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.05), Color(white: 0.28)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing),
                                      lineWidth: s * 0.05)
                Circle().strokeBorder(.white.opacity(0.20), lineWidth: max(1, s * 0.008))
            }
            .frame(width: s, height: s)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}
