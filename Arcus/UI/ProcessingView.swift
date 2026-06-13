import SwiftUI

struct ProcessingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 26) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.12), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: max(0.02, model.progress))
                    .stroke(
                        LinearGradient(colors: [.cyan, .purple], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.25), value: model.progress)
                Text("\(Int(model.progress * 100))%")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 150, height: 150)

            Text(model.progressMessage)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
            Text(AppText.Processing.summary)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))

            Button {
                model.cancelProcessing()
            } label: {
                Text(AppText.cancel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 26).padding(.vertical, 10)
                    .background(.white.opacity(0.10), in: Capsule())
            }
            .padding(.top, 6)
        }
        .padding(40)
    }
}
