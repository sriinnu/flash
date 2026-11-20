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
/// once, then grow along the edges until they close into one border and
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
                    // One blink, not two: two dips 0.13s apart was ~7 Hz,
                    // over the 3-flashes-a-second photosensitivity line.
                    (0.42, 1), (0.55, 0.2), (blinkEnd, 1),
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

// MARK: - Aurora

/// A wide, soft glow rolls in from the edges in the kind's two colours,
/// swells twice like a slow tide, and ebbs away. No hard edges, no blink:
/// the calm one that still fills your peripheral vision.
final class AuroraView: OverlayView {

    private let gradient: [NSColor]
    private let duration = 3.6

    init(frame: NSRect, gradient: [NSColor]) {
        self.gradient = gradient
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func play(completion: @escaping () -> Void) {
        guard let root = layer else { return completion() }
        let d = duration
        let loop = BorderGeometry.loop(in: bounds)

        runTransaction({
            // Two veils, one per colour, swelling out of phase so the hue
            // drifts between them.
            for (i, color) in gradient.prefix(2).enumerated() {
                let veil = CAShapeLayer()
                veil.frame = bounds
                veil.path = loop
                veil.fillColor = nil
                veil.strokeColor = color.withAlphaComponent(0.55).cgColor
                veil.lineWidth = 40
                veil.opacity = 0
                glow(veil, color, radius: 70)
                root.addSublayer(veil)
                let lag = Double(i) * 0.45
                veil.add(group([
                    keyframes("opacity", [
                        (0, 0), (0.7 + lag, 1), (1.5 + lag, 0.55), (2.3 + lag, 1), (d, 0),
                    ], over: d, eased: true),
                    keyframes("lineWidth", [
                        (0, 10), (0.7 + lag, 70), (1.5 + lag, 35), (2.3 + lag, 90), (d, 20),
                    ], over: d, eased: true),
                ], over: d), forKey: "tide")
            }

            // A crisp rail rides on top so the edge itself still reads.
            let (rail, _) = BorderGeometry.gradientRail(in: bounds, colors: gradient)
            rail.opacity = 0
            root.addSublayer(rail)
            rail.add(keyframes("opacity", [(0, 0), (0.6, 0.9), (d - 0.8, 0.9), (d, 0)], over: d, eased: true), forKey: "rail")
        }, completion: completion)
    }
}

// MARK: - Sonar

/// Rings leave the middle of the screen and travel out to the edges, three
/// pings in a row, and the border lights where each one lands. Your eyes
/// are dragged outward from wherever you were looking.
final class SonarView: OverlayView {

    private let gradient: [NSColor]
    private let glowColor: NSColor
    private let pings = 3
    private let gap = 0.55
    private let travel = 1.1

    init(frame: NSRect, gradient: [NSColor], glowColor: NSColor) {
        self.gradient = gradient
        self.glowColor = glowColor
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func play(completion: @escaping () -> Void) {
        guard let root = layer else { return completion() }
        let total = Double(pings - 1) * gap + travel + 0.6
        let loop = BorderGeometry.loop(in: bounds)

        runTransaction({
            for i in 0..<pings {
                let start = Double(i) * gap
                let ring = CAShapeLayer()
                ring.frame = bounds   // anchor at the centre: scale grows from the middle
                ring.path = loop
                ring.fillColor = nil
                ring.strokeColor = gradient[i % 2].cgColor
                ring.lineWidth = 6
                ring.opacity = 0
                glow(ring, gradient[i % 2], radius: 18)
                root.addSublayer(ring)
                ring.add(group([
                    keyframes("transform.scale", [
                        (0, 0.08), (start, 0.08), (start + travel, 1), (total, 1),
                    ], over: total),
                    keyframes("opacity", [
                        (0, 0), (start, 0), (start + 0.1, 0.9), (start + travel, 0.8), (start + travel + 0.25, 0), (total, 0),
                    ], over: total),
                ], over: total), forKey: "ping")
            }

            // The border flares as each ping lands.
            let edge = strokeLayer(path: loop, color: glowColor, width: BorderGeometry.lineWidth)
            edge.strokeEnd = 1
            glow(edge, glowColor, radius: 36)
            root.addSublayer(edge)
            let (rail, _) = BorderGeometry.gradientRail(in: bounds, colors: gradient)
            rail.opacity = 0
            root.addSublayer(rail)
            var frames: [(Double, Double)] = [(0, 0)]
            for i in 0..<pings {
                let land = Double(i) * gap + travel
                frames += [(land - 0.05, 0.3), (land + 0.05, 1), (land + 0.35, 0.35)]
            }
            frames += [(total, 0)]
            let flare = keyframes("opacity", frames, over: total, eased: true)
            edge.add(flare, forKey: "flare")
            rail.add(flare, forKey: "flare")
        }, completion: completion)
    }
}

// MARK: - Breathe

/// The whole border fades up and down, slow and even, three breaths. The
/// gentlest style that still repeats, under one cycle a second.
final class BreatheView: OverlayView {

    private let gradient: [NSColor]
    private let glowColor: NSColor
    private let breaths = 3
    private let breath = 1.3

    init(frame: NSRect, gradient: [NSColor], glowColor: NSColor) {
        self.gradient = gradient
        self.glowColor = glowColor
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func play(completion: @escaping () -> Void) {
        guard let root = layer else { return completion() }
        let b = breath

        runTransaction({
            let body = CALayer()
            body.frame = bounds
            body.opacity = 0
            root.addSublayer(body)
            let halo = strokeLayer(path: BorderGeometry.loop(in: bounds), color: glowColor, width: BorderGeometry.lineWidth)
            halo.strokeEnd = 1
            halo.opacity = 1
            glow(halo, glowColor, radius: 44)
            body.addSublayer(halo)
            let (rail, _) = BorderGeometry.gradientRail(in: bounds, colors: gradient)
            body.addSublayer(rail)

            body.add(keyframes("opacity", [(0, 0), (b * 0.5, 1), (b, 0.08)], over: b, eased: true)
                .repeating(breaths), forKey: "breathe")
            halo.add(keyframes("shadowRadius", [(0, 20), (b * 0.5, 60), (b, 20)], over: b, eased: true)
                .repeating(breaths), forKey: "bloom")
        }, completion: completion)
    }
}

// MARK: - Shockwave

/// Starts where your eyes already are: a bright point at the mouse pointer,
/// then two shockwaves blast out from it, and the border ignites as each one
/// reaches the edge. On a screen without the pointer it starts mid-screen.
final class ShockwaveView: OverlayView {

    private let gradient: [NSColor]
    private let glowColor: NSColor
    private let travel = 1.15
    private let gap = 0.45

    init(frame: NSRect, gradient: [NSColor], glowColor: NSColor) {
        self.gradient = gradient
        self.glowColor = glowColor
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func origin() -> CGPoint {
        guard let screenFrame = window?.frame else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        let mouse = NSEvent.mouseLocation
        guard screenFrame.contains(mouse) else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        return CGPoint(x: mouse.x - screenFrame.minX, y: mouse.y - screenFrame.minY)
    }

    override func play(completion: @escaping () -> Void) {
        guard let root = layer else { return completion() }
        let p = origin()
        // Far enough to sweep every corner.
        let radius = [CGPoint(x: 0, y: 0), CGPoint(x: bounds.maxX, y: 0),
                      CGPoint(x: 0, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
            .map { hypot($0.x - p.x, $0.y - p.y) }.max() ?? 1
        let nearest = min(p.x, p.y, bounds.maxX - p.x, bounds.maxY - p.y)
        let hit = travel * Double(nearest / radius)   // when a ring meets the nearest edge
        let charge = 0.35
        let total = charge + gap + travel + 0.9

        runTransaction({
            // The charge: a hot point at the pointer that swells and pops.
            let dot = CAShapeLayer()
            let dr: CGFloat = 26
            dot.frame = CGRect(x: p.x - dr, y: p.y - dr, width: dr * 2, height: dr * 2)
            dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
            dot.fillColor = NSColor.white.cgColor
            dot.opacity = 0
            glow(dot, gradient[0], radius: 30)
            root.addSublayer(dot)
            dot.add(group([
                keyframes("opacity", [(0, 0), (charge * 0.6, 1), (charge + 0.15, 0), (total, 0)], over: total),
                keyframes("transform.scale", [(0, 0.2), (charge, 1.3), (charge + 0.15, 0.4), (total, 0.4)], over: total, eased: true),
            ], over: total), forKey: "charge")

            for i in 0..<2 {
                let start = charge + Double(i) * gap
                let ring = CAShapeLayer()
                ring.frame = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
                ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
                ring.fillColor = nil
                ring.strokeColor = (i == 0 ? NSColor.white : gradient[1]).cgColor
                ring.lineWidth = i == 0 ? 7 : 4
                ring.opacity = 0
                glow(ring, gradient[i % 2], radius: 24)
                root.addSublayer(ring)
                ring.add(group([
                    keyframes("transform.scale", [(0, 0.01), (start, 0.01), (start + travel, 1), (total, 1)], over: total),
                    keyframes("opacity", [(0, 0), (start, 0), (start + 0.05, 1), (start + travel * 0.7, 0.7), (start + travel, 0), (total, 0)], over: total),
                ], over: total), forKey: "wave")
            }

            // The border ignites where the first wave lands, flares again on
            // the second, then cools.
            let loop = BorderGeometry.loop(in: bounds)
            let edge = strokeLayer(path: loop, color: glowColor, width: BorderGeometry.lineWidth)
            edge.strokeEnd = 1
            glow(edge, glowColor, radius: 40)
            root.addSublayer(edge)
            let (rail, _) = BorderGeometry.gradientRail(in: bounds, colors: gradient)
            rail.opacity = 0
            root.addSublayer(rail)
            let first = charge + hit, second = charge + gap + hit
            let flare = keyframes("opacity", [
                (0, 0), (first, 0), (first + 0.08, 1), (second - 0.05, 0.55), (second + 0.08, 1), (total, 0),
            ], over: total, eased: true)
            edge.add(flare, forKey: "ignite")
            rail.add(flare, forKey: "ignite")
            edge.add(keyframes("lineWidth", [(0, 12), (first, 12), (first + 0.1, 30), (first + 0.5, 14), (second + 0.1, 26), (total, 12)], over: total, eased: true), forKey: "swell")
        }, completion: completion)
    }
}

// MARK: - Supernova

/// The four corners gather light, collapse, and burst: sparks spray off
/// every edge in the kind's colours and the border burns down afterwards.
final class SupernovaView: OverlayView {

    private let gradient: [NSColor]
    private let glowColor: NSColor
    private let gather = 0.7
    private let total = 3.2
    private var emitter: CAEmitterLayer?

    init(frame: NSRect, gradient: [NSColor], glowColor: NSColor) {
        self.gradient = gradient
        self.glowColor = glowColor
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A soft round spark, drawn once.
    private static let spark: CGImage? = {
        let size = 32
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return nil }
        let c = CGPoint(x: 16, y: 16)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 16, options: [])
        return ctx.makeImage()
    }()

    override func play(completion: @escaping () -> Void) {
        guard let root = layer else { return completion() }
        let t = total, g = gather
        let inset = BorderGeometry.inset

        runTransaction({
            // Corners: four stars that swell, then collapse into the burst.
            let corners = [CGPoint(x: inset, y: inset), CGPoint(x: bounds.maxX - inset, y: inset),
                           CGPoint(x: inset, y: bounds.maxY - inset), CGPoint(x: bounds.maxX - inset, y: bounds.maxY - inset)]
            for c in corners {
                let star = CAShapeLayer()
                let r: CGFloat = 40
                star.frame = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                star.path = CGPath(ellipseIn: star.bounds, transform: nil)
                star.fillColor = NSColor.white.cgColor
                star.opacity = 0
                glow(star, glowColor, radius: 40)
                root.addSublayer(star)
                star.add(group([
                    keyframes("opacity", [(0, 0), (g * 0.8, 1), (g + 0.1, 0), (t, 0)], over: t),
                    keyframes("transform.scale", [(0, 0.1), (g * 0.8, 1), (g, 0.15), (g + 0.1, 2), (t, 2)], over: t, eased: true),
                ], over: t), forKey: "gather")
            }

            // The burst: sparks off the whole outline.
            let e = CAEmitterLayer()
            e.frame = bounds
            e.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
            e.emitterSize = CGSize(width: bounds.width - inset * 2, height: bounds.height - inset * 2)
            e.emitterShape = .rectangle
            e.emitterMode = .outline
            e.renderMode = .additive
            e.birthRate = 0
            e.emitterCells = (gradient.prefix(2) + [NSColor.white]).map { color in
                let cell = CAEmitterCell()
                cell.contents = Self.spark
                cell.birthRate = 220
                cell.lifetime = 1.6
                cell.lifetimeRange = 0.6
                cell.velocity = 260
                cell.velocityRange = 160
                cell.emissionRange = .pi * 2
                cell.scale = 0.35
                cell.scaleRange = 0.2
                cell.scaleSpeed = -0.18
                cell.alphaSpeed = -0.55
                cell.color = color.cgColor
                return cell
            }
            root.addSublayer(e)
            emitter = e

            // The border burns bright at the burst and cools.
            let loop = BorderGeometry.loop(in: bounds)
            let edge = strokeLayer(path: loop, color: glowColor, width: BorderGeometry.lineWidth)
            edge.strokeEnd = 1
            glow(edge, glowColor, radius: 50)
            root.addSublayer(edge)
            let (rail, _) = BorderGeometry.gradientRail(in: bounds, colors: gradient)
            rail.opacity = 0
            root.addSublayer(rail)
            let burn = keyframes("opacity", [(0, 0), (g, 0), (g + 0.08, 1), (g + 0.9, 0.85), (t, 0)], over: t, eased: true)
            edge.add(burn, forKey: "burn")
            rail.add(burn, forKey: "burn")
            edge.add(keyframes("lineWidth", [(0, 12), (g, 12), (g + 0.1, 40), (g + 1.0, 14), (t, 12)], over: t, eased: true), forKey: "swell")
        }, completion: completion)

        // Emitters run on birthRate, not animations: open the tap at the
        // burst, close it 0.45s later so the last sparks die before the end.
        DispatchQueue.main.asyncAfter(deadline: .now() + gather) { [weak self] in self?.emitter?.birthRate = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + gather + 0.45) { [weak self] in self?.emitter?.birthRate = 0 }
    }
}

// MARK: - Lightning

/// Electric arcs crackle along every edge. The arc's shape jumps about a
/// dozen times a second, but its brightness only ramps up and down: what
/// flickers is the line's path, not the light, so it stays well clear of
/// photosensitivity limits.
final class LightningView: OverlayView {

    private let gradient: [NSColor]
    private let glowColor: NSColor
    private let total = 3.0
    private let shapes = 36

    init(frame: NSRect, gradient: [NSColor], glowColor: NSColor) {
        self.gradient = gradient
        self.glowColor = glowColor
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A jagged loop round the screen: the inset rectangle cut into ~28pt
    /// steps, each nudged off the line by up to `jitter`.
    private func arc(jitter: CGFloat) -> CGPath {
        let r = bounds.insetBy(dx: BorderGeometry.inset, dy: BorderGeometry.inset)
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        let path = CGMutablePath()
        path.move(to: corners[0])
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            let length = hypot(b.x - a.x, b.y - a.y)
            let steps = max(2, Int(length / 28))
            // Perpendicular, pointing into the screen half the time.
            let nx = -(b.y - a.y) / length, ny = (b.x - a.x) / length
            for s in 1..<steps {
                let f = CGFloat(s) / CGFloat(steps)
                let off = CGFloat.random(in: -jitter...jitter)
                path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * f + nx * off, y: a.y + (b.y - a.y) * f + ny * off))
            }
            path.addLine(to: b)
        }
        path.closeSubpath()
        return path
    }

    override func play(completion: @escaping () -> Void) {
        guard let root = layer else { return completion() }
        let t = total

        runTransaction({
            // Two arcs, one per colour, crackling out of step, and a thin
            // white core riding inside the first.
            let outer = (0..<shapes).map { _ in arc(jitter: 9) }
            let inner = (0..<shapes).map { _ in arc(jitter: 14) }
            let strands: [(NSColor, CGFloat, [CGPath], Bool)] = [
                (gradient[0], 3.5, outer, true),
                (gradient[1], 3.5, inner, true),
                (.white, 1.5, outer, false),
            ]
            for (color, width, paths, glows) in strands {
                let bolt = CAShapeLayer()
                bolt.frame = bounds
                bolt.fillColor = nil
                bolt.strokeColor = color.cgColor
                bolt.lineWidth = width
                bolt.lineJoin = .miter
                bolt.opacity = 0
                if glows { glow(bolt, color, radius: 18) }
                root.addSublayer(bolt)

                let crackle = CAKeyframeAnimation(keyPath: "path")
                crackle.values = paths
                crackle.calculationMode = .discrete
                crackle.duration = t
                bolt.add(crackle, forKey: "crackle")
                bolt.add(keyframes("opacity", [(0, 0), (0.25, 1), (t - 0.7, 0.9), (t, 0)], over: t, eased: true), forKey: "charge")
            }

            // A soft halo under the arcs so the edge glows, not just the line.
            let loop = BorderGeometry.loop(in: bounds)
            let halo = strokeLayer(path: loop, color: glowColor.withAlphaComponent(0.35), width: 26)
            halo.strokeEnd = 1
            glow(halo, glowColor, radius: 50)
            root.insertSublayer(halo, at: 0)
            halo.add(keyframes("opacity", [(0, 0), (0.3, 0.8), (t - 0.7, 0.6), (t, 0)], over: t, eased: true), forKey: "halo")
        }, completion: completion)
    }

}

private extension CAAnimation {
    func repeating(_ count: Int) -> Self {
        repeatCount = Float(max(1, count))
        return self
    }
}
