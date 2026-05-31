import SwiftUI

struct CrosshairView: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) * 0.48
        let innerGap = outerRadius * 0.26

        path.addEllipse(in: CGRect(
            x: center.x - outerRadius,
            y: center.y - outerRadius,
            width: outerRadius * 2,
            height: outerRadius * 2
        ))

        path.move(to: CGPoint(x: rect.minX, y: center.y))
        path.addLine(to: CGPoint(x: center.x - innerGap, y: center.y))
        path.move(to: CGPoint(x: center.x + innerGap, y: center.y))
        path.addLine(to: CGPoint(x: rect.maxX, y: center.y))

        path.move(to: CGPoint(x: center.x, y: rect.minY))
        path.addLine(to: CGPoint(x: center.x, y: center.y - innerGap))
        path.move(to: CGPoint(x: center.x, y: center.y + innerGap))
        path.addLine(to: CGPoint(x: center.x, y: rect.maxY))

        path.addEllipse(in: CGRect(
            x: center.x - 2,
            y: center.y - 2,
            width: 4,
            height: 4
        ))

        return path
    }
}

#Preview {
    CrosshairView()
        .stroke(.white, lineWidth: 1)
        .frame(width: 160, height: 160)
        .padding()
        .background(Color.black)
}

