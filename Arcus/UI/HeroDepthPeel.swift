import SwiftUI

/// 首页主视觉「深度分层」(Depth Peel)：一张照片卡 + 身后扇形展开的磨砂玻璃深度层(棱镜彩边)
/// + 点状轨道环 + 极光辉光球 + 柔和投影。呼应 Reshot 质感、表达「一张照片长出深度层」。
/// 全程 SwiftUI 矢量绘制：任意尺寸清晰、深浅色自适应(半透明白 + 品牌色,无纯黑填充)、含轻微呼吸/漂移动效。
struct HeroDepthPeel: View {
    /// 设计画布(与 mockup 一致)：760×360，内部用绝对坐标，再整体缩放到可用宽度。
    private static let canvas = CGSize(width: 760, height: 360)
    @State private var phase: CGFloat = 0   // 0…1 往返：辉光呼吸 + 轨道极轻漂移

    private let cA = Theme.accentA   // #7C5CFF 紫
    private let cB = Theme.accentB   // #21D4FD 青
    private let cC = Theme.accentC   // #FF6BB5 粉
    /// 棱镜彩边：粉→紫→青→绿→黄 的彩虹扫描。
    private var rim: [Color] {
        [cC, cA, cB, Color(red: 0, green: 1, blue: 0.64), Color(red: 1, green: 0.90, blue: 0)]
    }
    /// 磨砂玻璃层填充(冷白偏蓝半透明，深浅色都成立)。
    private var glassFill: LinearGradient {
        LinearGradient(colors: [Color(red: 0.59, green: 0.75, blue: 1).opacity(0.22),
                                Color(red: 0.78, green: 0.84, blue: 1).opacity(0.09)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        Color.clear
            .aspectRatio(Self.canvas.width / Self.canvas.height, contentMode: .fit)
            .overlay(
                GeometryReader { geo in
                    composition
                        .frame(width: Self.canvas.width, height: Self.canvas.height)
                        .scaleEffect(geo.size.width / Self.canvas.width, anchor: .topLeading)
                }
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) { phase = 1 }
            }
            .accessibilityHidden(true)
    }

    private var composition: some View {
        ZStack(alignment: .topLeading) {
            glows
            orbit
            depthLayer(rotation: -33, offsetX: 108, offsetY: 20, scale: 0.90, opacity: 0.66, blur: 0.6, rim: 0.78)
            depthLayer(rotation: -25, offsetX: 58,  offsetY: 8,  scale: 0.95, opacity: 0.90, blur: 0,   rim: 1.0)
            spheres
            photoCard
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .topLeading)
    }

    // MARK: - 极光辉光（呼吸）

    private var glows: some View {
        ZStack(alignment: .topLeading) {
            glow(cA, 330, x: 185, y: 195, op: 0.46)
            glow(cB, 300, x: 580, y: 204, op: 0.44)
            glow(cC, 250, x: 405, y: 307, op: 0.34)
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .topLeading)
    }

    private func glow(_ c: Color, _ d: CGFloat, x: CGFloat, y: CGFloat, op: Double) -> some View {
        Circle().fill(c)
            .frame(width: d, height: d)
            .blur(radius: 62)
            .opacity(op * (0.86 + 0.14 * phase))
            .position(x: x, y: y)
    }

    // MARK: - 点状轨道环（极轻漂移）

    private var orbit: some View {
        ZStack(alignment: .topLeading) {
            orbitEllipse(Color(red: 0.47, green: 0.47, blue: 0.59).opacity(0.42), lw: 1.4)
            orbitEllipse(Color.white.opacity(0.30), lw: 1.0)
            dot(cB, 4.0, x: 632, y: 164)
            dot(cC, 3.5, x: 112, y: 232)
            dot(cA, 3.0, x: 410, y: 64)
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .topLeading)
        .rotationEffect(.degrees(-7 + Double(phase) * 2 - 1), anchor: .center)
    }

    private func orbitEllipse(_ c: Color, lw: CGFloat) -> some View {
        Ellipse()
            .stroke(c, style: StrokeStyle(lineWidth: lw, dash: [2.5, 8]))
            .frame(width: 552, height: 256)
            .position(x: 370, y: 194)
    }

    private func dot(_ c: Color, _ r: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle().fill(c)
            .frame(width: r * 2, height: r * 2)
            .shadow(color: c.opacity(0.6), radius: r)
            .position(x: x, y: y)
    }

    // MARK: - 深度层（扇形展开 + 棱镜彩边）

    private func depthLayer(rotation: Double, offsetX: CGFloat, offsetY: CGFloat,
                            scale: CGFloat, opacity: Double, blur: CGFloat, rim rimOp: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return ZStack {
            shape.fill(glassFill)
                .overlay(shape.strokeBorder(Color(red: 0.75, green: 0.82, blue: 1).opacity(0.30), lineWidth: 1))
            // 内层磨砂高光
            shape.fill(LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.04), .clear],
                                      startPoint: .topLeading, endPoint: .center))
            // 棱镜彩边
            shape.strokeBorder(LinearGradient(colors: rim, startPoint: .topLeading, endPoint: .bottomTrailing),
                               lineWidth: 1.6)
                .opacity(rimOp)
        }
        .frame(width: 280, height: 196)
        .scaleEffect(scale)
        .rotation3DEffect(.degrees(rotation), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.55)
        .opacity(opacity)
        .blur(radius: blur)
        .shadow(color: Color(red: 0.08, green: 0.04, blue: 0.24).opacity(0.30), radius: 26, x: 0, y: 22)
        .position(x: 298 + offsetX + (phase - 0.5) * 3, y: 184 + offsetY)
    }

    // MARK: - 辉光小球

    private var spheres: some View {
        ZStack(alignment: .topLeading) {
            sphere(30, x: 648, y: 236, base: cA, light: Color(red: 0.80, green: 0.74, blue: 1), op: 0.92)
            sphere(18, x: 108, y: 104, base: cB, light: Color(red: 0.75, green: 0.94, blue: 1), op: 0.85)
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .topLeading)
    }

    private func sphere(_ d: CGFloat, x: CGFloat, y: CGFloat, base: Color, light: Color, op: Double) -> some View {
        Circle()
            .fill(RadialGradient(colors: [light, base, base.opacity(0.7)],
                                 center: UnitPoint(x: 0.32, y: 0.28), startRadius: 0, endRadius: d * 0.95))
            .frame(width: d, height: d)
            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: base.opacity(0.45), radius: d * 0.4, x: 0, y: d * 0.3)
            .opacity(op)
            .position(x: x, y: y)
    }

    // MARK: - 前景照片卡（含示意场景）

    private var photoCard: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return ZStack {
            scene
                .frame(width: 280, height: 196)
                .clipShape(shape)
            // 内发光：顶部提亮 + 底部压暗
            shape.fill(LinearGradient(colors: [.white.opacity(0.12), .clear, .black.opacity(0.18)],
                                      startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
            // 高光描边
            shape.strokeBorder(.white.opacity(0.55), lineWidth: 1)
            // 右缘棱镜「亲吻」，把卡片与身后玻璃层呼应起来
            LinearGradient(colors: [.clear, cC, cA, cB, .clear], startPoint: .top, endPoint: .bottom)
                .frame(width: 2, height: 168)
                .blur(radius: 0.5).opacity(0.5)
                .position(x: 279, y: 98)
        }
        .frame(width: 280, height: 196)
        .shadow(color: Color(red: 0.06, green: 0.03, blue: 0.18).opacity(0.44), radius: 30, x: 0, y: 24)
        .position(x: 298, y: 184)
    }

    private var scene: some View {
        ZStack {
            Rectangle().fill(LinearGradient(stops: [
                .init(color: Color(red: 0.20, green: 0.16, blue: 0.48), location: 0),
                .init(color: cA,                                        location: 0.42),
                .init(color: Color(red: 1, green: 0.56, blue: 0.77),    location: 0.70),
                .init(color: Color(red: 1, green: 0.80, blue: 0.56),    location: 1.0),
            ], startPoint: .top, endPoint: .bottom))
            // 太阳：辉光 + 亮核
            Circle().fill(RadialGradient(colors: [Color(red: 1, green: 0.88, blue: 0.54), .clear],
                                         center: .center, startRadius: 2, endRadius: 48))
                .frame(width: 96, height: 96).position(x: 140, y: 114)
            Circle().fill(Color(red: 1, green: 0.95, blue: 0.81)).frame(width: 30, height: 30)
                .position(x: 140, y: 114)
            // 远山 / 近山
            farHill.fill(LinearGradient(colors: [Color(red: 0.38, green: 0.28, blue: 0.63),
                                                 Color(red: 0.24, green: 0.16, blue: 0.43)],
                                        startPoint: .top, endPoint: .bottom)).opacity(0.94)
            nearHill.fill(LinearGradient(colors: [Color(red: 0.23, green: 0.15, blue: 0.40),
                                                  Color(red: 0.14, green: 0.09, blue: 0.27)],
                                         startPoint: .top, endPoint: .bottom))
            // 太阳水面反光
            Ellipse().fill(Color(red: 1, green: 0.88, blue: 0.54)).frame(width: 80, height: 12)
                .opacity(0.18).position(x: 140, y: 182)
        }
        .frame(width: 280, height: 196)
    }

    private var farHill: Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 134))
            p.addCurve(to: CGPoint(x: 167, y: 111), control1: CGPoint(x: 53, y: 113), control2: CGPoint(x: 110, y: 122))
            p.addCurve(to: CGPoint(x: 280, y: 107), control1: CGPoint(x: 214, y: 101), control2: CGPoint(x: 252, y: 114))
            p.addLine(to: CGPoint(x: 280, y: 196)); p.addLine(to: CGPoint(x: 0, y: 196)); p.closeSubpath()
        }
    }

    private var nearHill: Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 162))
            p.addCurve(to: CGPoint(x: 185, y: 145), control1: CGPoint(x: 62, y: 145), control2: CGPoint(x: 119, y: 156))
            p.addCurve(to: CGPoint(x: 280, y: 145), control1: CGPoint(x: 233, y: 137), control2: CGPoint(x: 261, y: 150))
            p.addLine(to: CGPoint(x: 280, y: 196)); p.addLine(to: CGPoint(x: 0, y: 196)); p.closeSubpath()
        }
    }
}
