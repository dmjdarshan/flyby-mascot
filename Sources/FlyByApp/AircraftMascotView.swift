import SwiftUI

struct AircraftMascotView: View {
    let fliesRight: Bool
    var showsContrail = true

    var body: some View {
        HStack(spacing: -4) {
            if showsContrail {
                Capsule()
                    .fill(.white.opacity(0.5))
                    .frame(width: 28, height: 4)
                    .blur(radius: 0.5)
            }

            MinimalPlaneMark()
                .aspectRatio(2.25, contentMode: .fit)
        }
        .scaleEffect(x: fliesRight ? 1 : -1, y: 1)
        .accessibilityHidden(true)
    }
}

private struct MinimalPlaneMark: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack {
                PlaneSilhouette()
                    .fill(Color.flyByBlue)

                TailFin()
                    .fill(Color.flyByBlue)

                WingMark()
                    .fill(Color.flyByNavy)

                Capsule()
                    .fill(Color.flyByCyan)
                    .frame(width: width * 0.55, height: max(2, height * 0.055))
                    .offset(x: width * 0.08, y: height * 0.12)

                HStack(spacing: max(2, width * 0.025)) {
                    Capsule()
                    Capsule()
                }
                .foregroundStyle(Color.flyByNavy)
                .frame(width: width * 0.12, height: height * 0.09)
                .offset(x: width * 0.32, y: -height * 0.08)
            }
        }
    }
}

private struct PlaneSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(0.08, 0.42, in: rect))
        path.addLine(to: point(0.76, 0.39, in: rect))
        path.addCurve(
            to: point(0.98, 0.55, in: rect),
            control1: point(0.88, 0.39, in: rect),
            control2: point(0.96, 0.45, in: rect)
        )
        path.addCurve(
            to: point(0.78, 0.68, in: rect),
            control1: point(0.96, 0.64, in: rect),
            control2: point(0.88, 0.68, in: rect)
        )
        path.addLine(to: point(0.12, 0.68, in: rect))
        path.addLine(to: point(0.02, 0.58, in: rect))
        path.addLine(to: point(0.14, 0.53, in: rect))
        path.closeSubpath()
        return path
    }
}

private struct TailFin: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(0.12, 0.48, in: rect))
        path.addLine(to: point(0.08, 0.14, in: rect))
        path.addQuadCurve(
            to: point(0.25, 0.45, in: rect),
            control: point(0.11, 0.12, in: rect)
        )
        path.closeSubpath()
        return path
    }
}

private struct WingMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(0.42, 0.58, in: rect))
        path.addLine(to: point(0.31, 0.9, in: rect))
        path.addQuadCurve(
            to: point(0.39, 0.91, in: rect),
            control: point(0.35, 0.94, in: rect)
        )
        path.addLine(to: point(0.62, 0.59, in: rect))
        path.closeSubpath()
        return path
    }
}

private func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
}

private extension Color {
    static let flyByBlue = Color(red: 0.08, green: 0.55, blue: 0.96)
    static let flyByCyan = Color(red: 0.35, green: 0.92, blue: 1)
    static let flyByNavy = Color(red: 0.03, green: 0.13, blue: 0.28)
}
