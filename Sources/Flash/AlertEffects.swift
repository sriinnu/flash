import AppKit

// Alternative alert effects. Each one moves differently on purpose: if two
// effects share a motion signature, the setting is just a color picker with
// extra steps. Comet = travel toward a point, Marquee = continuous flow,
// Target lock = snap + trace, Heartbeat = rhythm. All sit on BorderGeometry's
// rail so switching styles never shifts where the border lives.

// MARK: - Marquee

/// Theatre-marquee bulbs chasing round the whole border in two alternating
/// colors. The most relentless of the lot — every edge is moving the whole
/// time, so there's no "wrong side of the screen" to be looking at.
final class MarqueeView: OverlayView {

    private let gradient: [NSColor]
    private let duration: Double = 2.4
    /// Bulb and gap before snapping to the perimeter. Snapped values drift
    /// by a pt or two per screen; that's the price of a seamless loop.
    private let bulb: CGFloat = 34
    private let gap: CGFloat = 22
    /// Chase speed, pt/s. Fast enough to read as motion from across the
    /// room, slow enough that the bulbs don't strobe into a solid line.
    private let speed: CGFloat = 820

    init(frame: NSRect, gradient: [NSColor]) {
        self.gradient = gradient
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func play(completion: @escaping () -> Void) {
        guard let root = layer else { return completion() }

        // Two colors alternate, so one full pattern = two bulbs + two gaps.
        // Snap it so a whole number of patterns fits the perimeter exactly,
        // otherwise the path's start point shows a stub or a double gap.
        let perimeter = BorderGeometry.perimeter(in: bounds)
        let raw = 2 * (bulb + gap)
        let count = max(1, (perimeter / raw).rounded())
        let pattern = perimeter / count
        let slot = pattern / 2
        let lineWidth = BorderGeometry.lineWidth
        // Round caps add half a line width at each end — take it back out
        // so the visible bulb matches the intended size.
        let dash = max(2, slot * bulb / (bulb + gap) - lineWidth)

        // Advance by whole patterns so the last frame lands on a phase
        // identical to the first; no jump if the fade-out is ever shortened.
        let laps = max(1, (speed * CGFloat(duration) / pattern).rounded())
        let fade = [(0.0, 0.0), (0.15, 1.0), (duration - 0.35, 1.0), (duration, 0.0)]

        runTransaction({
            for (i, color) in gradient.prefix(2).enumerated() {
                let lights = strokeLayer(path: BorderGeometry.loop(in: bounds), color: color, width: lineWidth)
                lights.strokeEnd = 1
                lights.lineDashPattern = [NSNumber(value: Double(dash)), NSNumber(value: Double(pattern - dash))]
                // Second color sits one slot behind the first.
                let base = CGFloat(i) * slot
                lights.lineDashPhase = base
                glow(lights, color, radius: 18)
                root.addSublayer(lights)

                let chase = CABasicAnimation(keyPath: "lineDashPhase")
                chase.fromValue = base
                chase.toValue = base + pattern * laps
                chase.duration = duration

                lights.add(group([chase, keyframes("opacity", fade, over: duration)], over: duration),
                           forKey: "marquee")
            }
        }, completion: completion)
    }
}

// MARK: - Target lock

/// Four corner brackets slam in from past the screen edge, lock, blink
/// twice, then grow along the edges until they close into one border and
/// flare. Reads as "acquired" — sharp, mechanical, over in under two seconds.
final class TargetLockView: OverlayView {

    private let gradient: [NSColor]
    private let glowColor: NSColor
    private let duration: Double = 1.9

    // Beat sheet, in seconds.
    private let slamEnd = 0.26
    private let settle = 0.36
    private let blinkEnd = 0.68
    private let growEnd = 1.15

    init(frame: NSRect, gradient: [NSColor], glowColor: NSColor) {
        self.gradient = gradient
        self.glowColor = glowColor
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func play(completion: @escaping () -> Void) {
        guard let root = layer else { return completion() }
        let d = duration

        runTransaction({
            // Flare rail under the brackets — lights up the instant they close.
            let (rail, _) = BorderGeometry.gradientRail(in: bounds, colors: gradient)
            rail.opacity = 0
            root.addSublayer(rail)
            rail.add(keyframes("opacity", [
                (0, 0), (growEnd - 0.03, 0), (growEnd + 0.07, 0.95), (d, 0),
            ], over: d), forKey: "flare")

            // Container carries the slam (scale about screen centre, so the
            // corners fly in from beyond the bezel) and the lock blinks.
            let rig = CALayer()
            rig.frame = bounds
            rig.opacity = 0
            root.addSublayer(rig)
            rig.add(group([
                keyframes("transform.scale", [
                    (0, 1.10), (slamEnd, 0.985), (settle, 1.0), (d, 1.0),
                ], over: d, eased: true),
                keyframes("opacity", [
                    (0, 0), (0.12, 1),
                    (0.42, 1), (0.47, 0.2), (0.52, 1), (0.60, 0.2), (blinkEnd, 1),
                    (growEnd + 0.15, 1), (d, 0),
                ], over: d),
            ], over: d), forKey: "rig")

            let (cornerMid, length) = BorderGeometry.quarterMetrics(in: bounds)
            let r = BorderGeometry.rect(in: bounds)
            // Bracket arm ≈ 10% of the short side, as a fraction of the quarter path.
            let arm = Double(min(r.width, r.height)) * 0.10 / length
            let start0 = max(0, cornerMid - arm)
            let end0 = min(1, cornerMid + arm)

            for (i, corner) in BorderGeometry.Corner.allCases.enumerated() {
                // Diagonal pairs share a color so the two tones cross the screen.
                let color = gradient[i % 2]
                let bracket = strokeLayer(
                    path: BorderGeometry.quarter(corner, in: bounds),
                    color: color,
                    width: BorderGeometry.lineWidth
                )
                bracket.strokeStart = CGFloat(start0)
                bracket.strokeEnd = CGFloat(end0)
                bracket.opacity = 1
                glow(bracket, i % 2 == 0 ? glowColor : color, radius: 26)
                rig.addSublayer(bracket)

                bracket.add(group([
                    keyframes("strokeStart", [(0, start0), (blinkEnd, start0), (growEnd, 0), (d, 0)],
                              over: d, eased: true),
                    keyframes("strokeEnd", [(0, end0), (blinkEnd, end0), (growEnd, 1), (d, 1)],
                              over: d, eased: true),
                ], over: d), forKey: "grow")
            }
        }, completion: completion)
    }
}

// MARK: - Heartbeat

/// The border thumps inward — lub-dub, three beats — thickening and
/// brightening on each hit. The calm option: rhythmic rather than frantic,
/// but the inward scale is still real motion at the edge, which is what
/// actually catches a glance from off-screen.
final class HeartbeatView: OverlayView {

    private let gradient: [NSColor]
    private let glowColor: NSColor
    private let beats = 3
    private let beat: Double = 0.85

    init(frame: NSRect, gradient: [NSColor], glowColor: NSColor) {
        self.gradient = gradient
        self.glowColor = glowColor
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func play(completion: @escaping () -> Void) {
        guard let root = layer else { return completion() }
        let b = beat

        runTransaction({
            // Scale + opacity live on a container so glow and gradient thump
            // as one body; scaling about screen centre pulls every edge in.
            let heart = CALayer()
            heart.frame = bounds
            heart.opacity = 0
            root.addSublayer(heart)

            let glowStroke = strokeLayer(
                path: BorderGeometry.loop(in: bounds),
                color: glowColor,
                width: BorderGeometry.lineWidth
            )
            glowStroke.strokeEnd = 1
            glowStroke.opacity = 1
            glow(glowStroke, glowColor, radius: 40)
            heart.addSublayer(glowStroke)

            let (rail, _) = BorderGeometry.gradientRail(in: bounds, colors: gradient)
            heart.addSublayer(rail)

            // lub at 0.10, dub at 0.30, then a long rest — the gap is what
            // makes it read as a heartbeat instead of a double-blink.
            heart.add(group([
                keyframes("opacity", [
                    (0, 0.15), (0.10, 1), (0.19, 0.45), (0.30, 1), (0.48, 0.25), (b, 0),
                ], over: b),
                keyframes("transform.scale", [
                    (0, 1), (0.10, 0.984), (0.19, 0.995), (0.30, 0.988), (0.50, 1), (b, 1),
                ], over: b, eased: true),
            ], over: b, repeats: beats), forKey: "beat")

            glowStroke.add(keyframes("lineWidth", [
                (0, 12), (0.10, 26), (0.19, 15), (0.30, 22), (0.50, 12), (b, 12),
            ], over: b, eased: true).repeating(beats), forKey: "swell")
        }, completion: completion)
    }
}

private extension CAAnimation {
    func repeating(_ count: Int) -> Self {
        repeatCount = Float(max(1, count))
        return self
    }
}
