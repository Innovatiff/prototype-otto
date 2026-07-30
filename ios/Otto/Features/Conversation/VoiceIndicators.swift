import SwiftUI

/// Live mic amplitude as a row of bars — real levels, not decoration.
/// `levels` is a fixed-width window, oldest first, each 0…1.
struct WaveformView: View {
    let levels: [Float]
    var dimmed = false

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .frame(width: 3, height: max(3, CGFloat(levels[index]) * 30))
            }
        }
        .frame(height: 34)
        .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
        .animation(.linear(duration: 0.05), value: levels)
    }
}

/// The thinking state: three dots breathing in sequence. Deliberately not a
/// spinner — subtle enough to glance past, alive enough to show work.
struct ThinkingIndicator: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 7, height: 7)
                    .opacity(pulsing ? 0.9 : 0.2)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                        value: pulsing
                    )
            }
        }
        .foregroundStyle(.secondary)
        .frame(height: 34)
        .onAppear { pulsing = true }
    }
}
