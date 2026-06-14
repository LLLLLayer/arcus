import SwiftUI
import UIKit

/// 全 App 统一设计系统（专业级视觉语言）：极光配色、玻璃面板、强调渐变、按钮/控件样式。
/// 目标：从「毛坯测试 demo」升级为可交付的产品级界面。所有界面共用这里的 token 与组件。
/// 全部颜色支持**深浅色自适应**：底色/文本随系统外观翻转，强调极光色两种外观下都成立。
enum Theme {

    /// 深浅色动态颜色工具。
    static func dyn(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(UIColor { tc in
            let c = tc.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    // MARK: - 配色（底色自适应：浅色=近白，深色=近黑）

    static let ink     = dyn(light: (0.96, 0.97, 0.99), dark: (0.04, 0.05, 0.09))   // 主底
    static let ink2    = dyn(light: (0.91, 0.93, 0.975), dark: (0.07, 0.07, 0.13))  // 次底
    static let inkEdge = dyn(light: (1.00, 1.00, 1.00), dark: (0.00, 0.00, 0.00))   // 渐变边缘

    static let accentA   = Color(red: 0.49, green: 0.36, blue: 1.00)   // 紫 #7C5CFF
    static let accentB   = Color(red: 0.13, green: 0.83, blue: 0.99)   // 青 #21D4FD
    static let accentC   = Color(red: 1.00, green: 0.42, blue: 0.71)   // 粉 #FF6BB5

    static let accentGradient = LinearGradient(colors: [accentA, accentB],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
    static let accentGradientH = LinearGradient(colors: [accentA, accentB],
                                                startPoint: .leading, endPoint: .trailing)
    static let warmGradient = LinearGradient(colors: [accentC, accentA],
                                             startPoint: .leading, endPoint: .trailing)

    /// 全谱彩虹（处理态炫彩 + 雾状背景旋转色环用，取自 spatial-photo 风格）。
    static let rainbowColors: [Color] = [
        Color(red: 1.00, green: 0.18, blue: 0.49), Color(red: 0.48, green: 0.36, blue: 1.00),
        Color(red: 0.00, green: 0.83, blue: 1.00), Color(red: 0.00, green: 1.00, blue: 0.64),
        Color(red: 1.00, green: 0.90, blue: 0.00), Color(red: 1.00, green: 0.37, blue: 0.00),
        Color(red: 1.00, green: 0.18, blue: 0.49)
    ]

    // MARK: - 文本层级（基于 primary，自动随外观翻转：浅色=近黑，深色=近白）

    static let title  = Color.primary
    static let body   = Color.primary.opacity(0.82)
    static let sub    = Color.primary.opacity(0.55)
    static let faint  = Color.primary.opacity(0.40)

    // MARK: - 自适应表面/描边（替代裸 .white.opacity：浅色下是淡黑、深色下是淡白）

    static let surface       = Color.primary.opacity(0.06)
    static let surfaceStrong = Color.primary.opacity(0.10)
    static let hairline      = Color.primary.opacity(0.12)
}

// MARK: - 安全填充图（scaledToFill 但用精确像素 frame 锁定，绝不撑大父布局——避免再现「背景撑宽坐标系」类 bug）

struct FillImage: View {
    let image: UIImage
    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
    }
}

// MARK: - 极光背景

private struct AuroraBackground: ViewModifier {
    var animated: Bool = true
    @State private var t: CGFloat = 0
    func body(content: Content) -> some View {
        content.background(
            ZStack {
                LinearGradient(colors: [Theme.ink2, Theme.ink, Theme.inkEdge],
                               startPoint: .top, endPoint: .bottom)
                // 柔和极光团块
                Circle().fill(Theme.accentA.opacity(0.30))
                    .frame(width: 420, height: 420).blur(radius: 120)
                    .offset(x: -120, y: -260 + t * 18)
                Circle().fill(Theme.accentB.opacity(0.22))
                    .frame(width: 380, height: 380).blur(radius: 130)
                    .offset(x: 150, y: -120 - t * 14)
                Circle().fill(Theme.accentC.opacity(0.14))
                    .frame(width: 320, height: 320).blur(radius: 130)
                    .offset(x: 60, y: 320 + t * 10)
            }
            .ignoresSafeArea()
        )
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) { t = 1 }
        }
    }
}

// MARK: - 玻璃容器（iOS 26 液态玻璃 Liquid Glass，旧系统回退到 material）

extension View {
    /// 任意形状的玻璃背景：iOS 26 用真·液态玻璃 `.glassEffect`，否则 ultraThinMaterial + 描边 + 阴影。
    @ViewBuilder
    func glassBG<S: Shape>(_ shape: S, interactive: Bool = false, strong: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Theme.hairline.opacity(strong ? 1.4 : 1), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 10)
        }
    }

    func auroraBackground(animated: Bool = true) -> some View { modifier(AuroraBackground(animated: animated)) }
    func glassCard(radius: CGFloat = 24, strong: Bool = false) -> some View {
        glassBG(RoundedRectangle(cornerRadius: radius, style: .continuous), strong: strong)
    }
}

// MARK: - 按钮样式

struct PrimaryButtonStyle: ButtonStyle {
    var gradient: LinearGradient = Theme.accentGradientH
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Theme.accentA.opacity(0.45), radius: 16, x: 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// 虹彩描边主按钮：极光渐变底 + 旋转彩虹描边光环。呼应 App 图标与「Arcus=彩虹」品牌，是首页的标志性 CTA。
struct RainbowRingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            // 饱和极光底（两种外观下都够深，白字始终可读），外加旋转彩虹描边
            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                    let rot = (tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 8) / 8) * 360
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(AngularGradient(colors: Theme.rainbowColors, center: .center,
                                                      angle: .degrees(rot)), lineWidth: 2.5)
                }
            )
            .shadow(color: Theme.accentA.opacity(0.45), radius: 18, x: 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.title)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - 圆形玻璃图标按钮

struct CircleIconButton: View {
    let system: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.title)
                .frame(width: 44, height: 44)
                .glassBG(Circle(), interactive: true)
        }
    }
}

// MARK: - 标签胶囊

struct PillLabel: View {
    let text: String
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.caption2) }
            Text(text).font(.caption2.weight(.medium))
        }
        .foregroundStyle(Theme.body)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .glassBG(Capsule())
    }
}

// MARK: - 选择卡片（首页方案/补全选择）

struct SelectableCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let selected: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceStrong))
                        .frame(width: 42, height: 42)
                    Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.body))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.title)
                    Text(subtitle).font(.caption2).foregroundStyle(Theme.sub)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? Theme.accentB : Theme.faint)
            }
            .padding(12)
            .background(selected ? Theme.surfaceStrong : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.hairline),
                            lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 带标题/数值的滑杆

struct LabeledSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Float
    let range: ClosedRange<Float>
    var unit: String = "%"
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(Theme.body)
                Spacer()
                Text(display).font(.caption2.monospacedDigit()).foregroundStyle(Theme.faint)
            }
            Slider(value: $value, in: range).tint(Theme.accentB)
        }
    }
    private var display: String {
        if unit == "%" {
            let p = (value - range.lowerBound) / (range.upperBound - range.lowerBound) * 100
            return String(format: "%.0f%%", p)
        }
        return String(format: "%.2f%@", value, unit)
    }
}

// MARK: - 胶囊开关芯片

struct ChipToggle: View {
    let title: LocalizedStringKey
    let icon: String
    @Binding var isOn: Bool
    var tint: Color = Theme.accentB
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2)
                Text(title).font(.caption2.weight(.medium))
            }
            .foregroundStyle(isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.body))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(isOn ? AnyShapeStyle(tint.opacity(0.85)) : AnyShapeStyle(Theme.surface),
                        in: Capsule())
            .overlay(Capsule().stroke(isOn ? Color.clear : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
