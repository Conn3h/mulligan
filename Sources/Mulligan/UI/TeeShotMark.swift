import SwiftUI

/// The tee-shot mark drawn from `DS.TeeShot`: a ball on a tee with five sound arcs coming off
/// it. `level` (0...1) lights the arcs from the inside out, each in its place on the meter's
/// green-to-amber scale, so the arcs are a level meter and the meter colours stay in a meter.
/// The ball is the recording lamp: coral only while `isRecording`, neutral otherwise.
/// Drawn in a `Canvas`, so a per-frame level change repaints without a layout pass.
struct TeeShotMark: View {
    let level: CGFloat
    let isRecording: Bool
    /// Arcs drawn at rest, for the static mark (welcome sheet): every arc lit in ink.
    var restingArcs = false

    var body: some View {
        Canvas { gc, size in
            let scale = min(size.width / DS.TeeShot.width, size.height / DS.TeeShot.height)
            gc.translateBy(
                x: (size.width - DS.TeeShot.width * scale) / 2,
                y: (size.height - DS.TeeShot.height * scale) / 2
            )
            gc.scaleBy(x: scale, y: scale)
            drawTee(into: gc)
            drawArcs(into: gc)
            drawBall(into: gc)
        }
        .accessibilityHidden(true)
    }

    private func drawTee(into gc: GraphicsContext) {
        var cup = Path()
        cup.addLines(DS.TeeShot.cup)
        cup.closeSubpath()
        gc.fill(cup, with: .color(DS.Color.ink))
        let stem = DS.TeeShot.stem
        gc.fill(Path(roundedRect: stem, cornerRadius: stem.width / 2), with: .color(DS.Color.ink))
    }

    private func drawBall(into gc: GraphicsContext) {
        let centre = DS.TeeShot.ballCentre
        let radius = DS.TeeShot.ballRadius
        let rect = CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)
        gc.fill(Path(ellipseIn: rect), with: .color(isRecording ? DS.Color.accent : DS.Color.inkTertiary))
    }

    private func drawArcs(into gc: GraphicsContext) {
        let radii = DS.TeeShot.arcRadii
        let lastIndex = max(radii.count - 1, 1)
        let clamped = max(0, min(1, level))
        for (index, radius) in radii.enumerated() {
            let arc = arcPath(radius: radius)
            let style = StrokeStyle(lineWidth: DS.TeeShot.arcLineWidth, lineCap: .round)
            if restingArcs {
                gc.stroke(arc, with: .color(DS.Color.ink), style: style)
                continue
            }
            gc.stroke(arc, with: .color(DS.Color.hairlineStrong), style: style)
            // Each arc owns one fifth of the range and fades in across it.
            let lit = max(0, min(1, clamped * CGFloat(radii.count) - CGFloat(index)))
            guard lit > 0 else {
                continue
            }
            let colour = DS.Color.meterLow.mix(with: DS.Color.meterHigh, by: Double(index) / Double(lastIndex))
            var layer = gc
            layer.opacity = lit
            layer.stroke(arc, with: .color(colour), style: style)
        }
    }

    private func arcPath(radius: CGFloat) -> Path {
        let half = DS.TeeShot.arcHalfAngleDegrees
        var path = Path()
        path.addArc(
            center: DS.TeeShot.ballCentre,
            radius: radius,
            startAngle: .degrees(-half),
            endAngle: .degrees(half),
            clockwise: false
        )
        return path
    }
}

/// Maps the controller's 0...1 meter level onto the arcs (spec §6.14). The level is scaled so
/// `DS.TeeShot.meterFullScale` fills the meter, then square-rooted so ordinary speech, well
/// below its peaks, still reaches the middle arcs.
enum MeterScale {
    static func display(_ level: Float) -> CGFloat {
        let scaled = max(0, min(1, level / DS.TeeShot.meterFullScale))
        return CGFloat(scaled.squareRoot())
    }
}
