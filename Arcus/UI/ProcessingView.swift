import SwiftUI

/// 处理态：给正在处理的照片本身叠一层「炫彩」效果（色相循环 + 旋转彩虹 screen 混合），
/// 而非一个干巴巴的转圈。对标 Apple 空间照片转换 / OpenReshot 的彩色加载动画。
struct ProcessingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            Theme.ink.ignoresSafeArea()

            if let img = model.sourceImage {
                // 背景：同图模糊铺满 + 压暗，填满屏幕避免黑边；FillImage(精确 frame+clipped)不会撑大坐标系，底部进度坞稳。
                FillImage(image: img)
                    .blur(radius: 48).opacity(0.5).saturation(1.2)
                    .ignoresSafeArea()
                LinearGradient(colors: [.black.opacity(0.5), .black.opacity(0.32), .black.opacity(0.62)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                // 前景：原图**按原始比例**展示（scaledToFit，绝不裁切/拉伸）+ 炫彩（色相循环 + 反向旋转彩虹 screen）。
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let rot = (t.truncatingRemainder(dividingBy: 6) / 6) * 360
                    Image(uiImage: img).resizable().scaledToFit()
                        .saturation(1.6).brightness(0.03).contrast(1.03)
                        .hueRotation(.degrees(rot))               // 色相循环 ⇒ 炫彩流动
                        .overlay(
                            AngularGradient(colors: Theme.rainbowColors, center: .center)
                                .rotationEffect(.degrees(-rot))   // 反向旋转的彩虹
                                .scaleEffect(1.4).blur(radius: 32)
                                .opacity(0.4).blendMode(.screen)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: 28, x: 0, y: 16)
                        .padding(.horizontal, 26)
                        .padding(.top, 64)
                        .padding(.bottom, 132)   // 给底部进度坞留空间
                }
            } else {
                Color.clear.auroraBackground()
            }

            VStack {
                Spacer()
                progressDock
            }
        }
        .preferredColorScheme(.dark)
    }

    private var progressDock: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(.white.opacity(0.18), lineWidth: 3).frame(width: 30, height: 30)
                    Circle().trim(from: 0, to: max(0.04, model.progress))
                        .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 30, height: 30)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: model.progress)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.progressMessage).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text(String(format: String(localized: "%d%% · On-device processing"), Int(model.progress * 100))).font(.caption2).foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 0)
                Button { model.cancelProcessing() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.body).frame(width: 34, height: 34)
                        .background(.white.opacity(0.10), in: Circle())
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .glassCard(radius: 22)
            .padding(.horizontal, 20)
            .padding(.bottom, 34)
        }
    }
}
