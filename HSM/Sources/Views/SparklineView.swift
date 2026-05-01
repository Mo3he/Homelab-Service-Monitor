import SwiftUI

/// A compact sparkline chart showing recent latency history for a service.
struct SparklineView: View {
    let snapshots: [StatusSnapshot]
    var height: CGFloat = 30
    var lineColor: Color = .accentColor

    var body: some View {
        if snapshots.count < 2 {
            EmptyView()
        } else {
            let values = snapshots.compactMap(\.latencyMs)
            if values.count >= 2 {
                GeometryReader { geo in
                    sparklinePath(values: values, in: geo.size)
                        .stroke(lineColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                .frame(height: height)
                .accessibilityLabel(accessibilityDescription(values: values))
                .accessibilityHint("Latency trend chart")
            }
        }
    }

    private func accessibilityDescription(values: [Double]) -> String {
        guard let first = values.first, let last = values.last else { return "Latency trend" }
        let trend = last > first * 1.2 ? "increasing" : last < first * 0.8 ? "decreasing" : "stable"
        return String(format: "Latency trend, %@. Latest: %.0f ms", trend, last)
    }

    private func sparklinePath(values: [Double], in size: CGSize) -> Path {
        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 1
        let range = max(maxVal - minVal, 1)

        return Path { path in
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                let y = size.height * (1 - CGFloat((value - minVal) / range))
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
    }
}
