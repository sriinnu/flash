import AppKit

// MARK: - Window

/// Full-screen, borderless, click-through window hosting one overlay effect
/// on one display. Single-use: build, `play`, and it orders itself out when
/// the effect finishes. The effect itself lives in an `OverlayView` subclass
/// so the window doesn't care whether it's a comet, a classic pulse or a
/// success ripple.
final class OverlayWindow: NSWindow {

    private let overlay: OverlayView

    init(screen: NSScreen, overlay makeOverlay: (NSRect) -> OverlayView) {
        overlay = makeOverlay(NSRect(origin: .zero, size: screen.frame.size))
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = overlay
    }

    /// Runs the effect once, then orders out. Completion is on the main thread.
    func play(then completion: @escaping () -> Void) {
        alphaValue = 1
        orderFrontRegardless()
        overlay.play { [weak self] in
            self?.orderOut(nil)
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Cuts an alert short — used when the key gets touched mid-comet so the
    /// alert doesn't keep shouting over the success ripple. The layer
    /// animations keep running underneath at alpha 0 and still fire `play`'s
    /// completion when they end, so bookkeeping stays in one place.
    func fadeOut(duration: TimeInterval = 0.18) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            animator().alphaValue = 0
        }
    }
}

/// Base for anything an `OverlayWindow` can play. Subclasses build their
/// layers in init and kick off animations in `play`.
class OverlayView: NSView {

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    func play(completion: @escaping () -> Void) {
        completion()
    }

    /// Wraps `body` in a transaction whose completion fires once every
    /// animation added inside it has finished (or been removed).
    func runTransaction(_ body: () -> Void, completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        body()
        CATransaction.commit()
    }

    // MARK: Shared layer + keyframe plumbing

    /// A full-bounds stroke on `path`, invisible by model value
    /// (strokeEnd 0, opacity 0) — animations bring it to life, and when they
    /// end nothing is left drawn for the frame before orderOut.
    func strokeLayer(path: CGPath, color: NSColor, width: CGFloat) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.frame = bounds
        layer.path = path
        layer.fillColor = nil
        layer.strokeColor = color.cgColor
        layer.lineWidth = width
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.strokeStart = 0
        layer.strokeEnd = 0
        layer.opacity = 0
        return layer
    }

    /// Neon bloom. Shape-layer shadows re-render every frame the path
    /// changes, so use it on the few layers that sell the effect, not all.
    func glow(_ layer: CALayer, _ color: NSColor, radius: CGFloat) {
        layer.shadowColor = color.cgColor
        layer.shadowRadius = radius
        layer.shadowOpacity = 1
        layer.shadowOffset = .zero
    }

    /// Keyframe animation from (seconds, value) pairs laid out over
    /// `duration`. Times are normalised here so effects think in seconds.
    /// `eased` puts ease-in-out on every segment instead of linear — right
    /// for a handful of hand-placed keys, wrong for dense precomputed samples.
    func keyframes(
        _ keyPath: String,
        _ frames: [(Double, Double)],
        over duration: Double,
        eased: Bool = false
    ) -> CAKeyframeAnimation {
        let anim = CAKeyframeAnimation(keyPath: keyPath)
        anim.values = frames.map { $0.1 }
        anim.keyTimes = frames.map { NSNumber(value: min(1, max(0, $0.0 / duration))) }
        anim.duration = duration
        anim.calculationMode = .linear
        if eased, frames.count > 1 {
            anim.timingFunctions = Array(
                repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                count: frames.count - 1
            )
        }
        return anim
    }

    func group(_ animations: [CAAnimation], over duration: Double, repeats: Int = 1) -> CAAnimationGroup {
        let g = CAAnimationGroup()
        g.animations = animations
        g.duration = duration
        g.repeatCount = Float(max(1, repeats))
        return g
    }
}

// MARK: - Shared geometry

/// One source of truth for where the border sits, so the comet rides exactly
/// the rail the classic flash strokes and the success ring starts from it.
enum BorderGeometry {
    static let lineWidth: CGFloat = 12
    static let inset: CGFloat = lineWidth / 2 + 8
    static let cornerRadius: CGFloat = 16

    static func rect(in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: inset, dy: inset)
    }

    static func loop(in bounds: CGRect) -> CGPath {
        CGPath(
            roundedRect: rect(in: bounds),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
    }

    enum Side { case left, right }

    /// Half the border, from top-centre down one side to bottom-centre.
    /// The comet heads each ride one of these, so `strokeEnd` 0→1 is exactly
    /// "spawn at the top, meet at the bottom" — and since neither path ever
    /// wraps past its own start, there's no seam to hide.
    static func half(_ side: Side, in bounds: CGRect) -> CGPath {
        let r = rect(in: bounds)
        let x = side == .right ? r.maxX : r.minX
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.midX, y: r.maxY))
        path.addArc(tangent1End: CGPoint(x: x, y: r.maxY),
                    tangent2End: CGPoint(x: x, y: r.minY),
                    radius: cornerRadius)
        path.addArc(tangent1End: CGPoint(x: x, y: r.minY),
                    tangent2End: CGPoint(x: r.midX, y: r.minY),
                    radius: cornerRadius)
        path.addLine(to: CGPoint(x: r.midX, y: r.minY))
        return path
    }

    /// Arc-length of `loop(in:)`: straight runs plus four quarter-circles.
    /// Marquee dashes are sized to divide this exactly so the pattern closes
    /// on itself with no half-dash seam at the path's start.
    static func perimeter(in bounds: CGRect) -> CGFloat {
        let r = rect(in: bounds)
        return 2 * (r.width + r.height) - 8 * cornerRadius + 2 * .pi * cornerRadius
    }

    enum Corner: CaseIterable { case topLeft, topRight, bottomRight, bottomLeft }

    /// A quarter of the border: from the middle of the horizontal edge,
    /// round the corner, to the middle of the vertical edge. Four of these
    /// tile the full loop — target lock grows each from its corner outward
    /// until they meet.
    static func quarter(_ corner: Corner, in bounds: CGRect) -> CGPath {
        let r = rect(in: bounds)
        let cx = (corner == .topLeft || corner == .bottomLeft) ? r.minX : r.maxX
        let cy = (corner == .topLeft || corner == .topRight) ? r.maxY : r.minY
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.midX, y: cy))
        path.addArc(tangent1End: CGPoint(x: cx, y: cy),
                    tangent2End: CGPoint(x: cx, y: r.midY),
                    radius: cornerRadius)
        path.addLine(to: CGPoint(x: cx, y: r.midY))
        return path
    }

    /// Fraction along `quarter(_:in:)` where the corner's arc is centred,
    /// and the total length of that path — same for all four corners.
    static func quarterMetrics(in bounds: CGRect) -> (corner: Double, length: Double) {
        let r = rect(in: bounds)
        let h = Double(r.width / 2 - cornerRadius)
        let v = Double(r.height / 2 - cornerRadius)
        let arc = Double.pi / 2 * Double(cornerRadius)
        let total = h + arc + v
        return ((h + arc / 2) / total, total)
    }

    /// Where the two heads meet — bottom-centre, roughly where your hands and
    /// the key are. That's the whole point of the direction: look down, touch.
    static func meetingPoint(in bounds: CGRect) -> CGPoint {
        let r = rect(in: bounds)
        return CGPoint(x: r.midX, y: r.minY)
    }

    /// A conic gradient masked to the border stroke. Built here because both
    /// the classic flash and the comet's faint rail use it.
    static func gradientRail(in bounds: CGRect, colors: [NSColor]) -> (CAGradientLayer, CAShapeLayer) {
        let gradient = CAGradientLayer()
        // First color repeats at the end so the wheel loops with no seam.
        gradient.type = .conic
        gradient.colors = [colors[0], colors[1], colors[0]].map(\.cgColor)
        gradient.locations = [0.0, 0.5, 1.0]
        gradient.frame = bounds

        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path = loop(in: bounds).copy(
            strokingWithWidth: lineWidth,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
        gradient.mask = mask
        return (gradient, mask)
    }
}

// MARK: - Classic flash

/// The original look: full glowing border, opacity-pulsed `flashes` times.
/// Still the loudest thing Flash can do, which is why it's also what the
/// reminder escalates to when a comet got ignored.
///
/// Layer-backed instead of draw(_:)-backed: a static linear gradient drawn
/// across the whole screen and clipped to a thin 12pt stroke barely reads as
/// a gradient at all. A conic gradient masked to the stroke guarantees both
/// colors are always visible somewhere around the border, and spinning it
/// during the pulse is what actually makes it read as a gradient.
final class ClassicFlashView: OverlayView {

    private let flashes: Int
    private let glowLayer = CAShapeLayer()
    private var gradientLayer = CAGradientLayer()
    private var gradientMask = CAShapeLayer()

    init(frame: NSRect, gradient: [NSColor], glowColor: NSColor, flashes: Int) {
        self.flashes = flashes
        super.init(frame: frame)

        glowLayer.fillColor = nil
        glowLayer.strokeColor = glowColor.cgColor
        glowLayer.lineWidth = BorderGeometry.lineWidth
        glowLayer.shadowColor = glowColor.cgColor
        glowLayer.shadowRadius = 42
        glowLayer.shadowOpacity = 1
        glowLayer.shadowOffset = .zero
        layer?.addSublayer(glowLayer)

        (gradientLayer, gradientMask) = BorderGeometry.gradientRail(in: bounds, colors: gradient)
        layer?.addSublayer(gradientLayer)

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = 1.6
        spin.repeatCount = .infinity
        gradientLayer.add(spin, forKey: "spin")

        updateGeometry()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    private func updateGeometry() {
        glowLayer.frame = bounds
        glowLayer.path = BorderGeometry.loop(in: bounds)
        gradientLayer.frame = bounds
        gradientMask.frame = bounds
        gradientMask.path = BorderGeometry.loop(in: bounds).copy(
            strokingWithWidth: BorderGeometry.lineWidth,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
    }

    /// ~0.5s per flash, then done.
    override func play(completion: @escaping () -> Void) {
        guard let layer else { return completion() }

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0.0, 1.0, 1.0, 0.08]
        anim.keyTimes = [0.0, 0.25, 0.55, 1.0]
        anim.duration = 0.5
        anim.repeatCount = Float(flashes)
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        runTransaction({ layer.add(anim, forKey: "flashPulse") }, completion: completion)
    }
}

// MARK: - Comet chase

/// Two comets spawn at top-centre, race down opposite sides and meet at
/// bottom-centre in a flare + shockwave. Motion at the screen edge is what
/// peripheral vision is good at; a static fade is what it's bad at — that's
/// the whole bet this view makes over the classic flash.
///
/// Every layer here is driven by keyframes precomputed from one easing curve
/// (see `CometTimeline`) instead of stacking CAMediaTimingFunctions — the
/// head and each tail segment have to agree on "where is the comet right now"
/// down to the frame, or the tail visibly detaches on the curve.
final class CometChaseView: OverlayView {

    /// Tail segments, back to front. Length is a fraction of one half-border;
    /// on a 1512×982 laptop screen a half is ~2.4k pt, so 0.22 ≈ 540pt of tail.
    /// Stacked translucent strokes fake a fading tail — CoreAnimation can't
    /// cheaply gradient a stroke *along* its length.
    private static let tail: [(length: Double, alpha: Float, width: CGFloat)] = [
        (0.22, 0.14, 10),
        (0.14, 0.28, 11),
        (0.08, 0.55, 12),
    ]

    private let gradient: [NSColor]
    private let glowColor: NSColor
    private let passes: Int
    private let timeline = CometTimeline()

    init(frame: NSRect, gradient: [NSColor], glowColor: NSColor, passes: Int) {
        self.gradient = gradient
        self.glowColor = glowColor
        self.passes = max(1, passes)
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func play(completion: @escaping () -> Void) {
        guard let root = layer else { return completion() }

        runTransaction({
            addRail(to: root)
            for side in [BorderGeometry.Side.left, .right] {
                addComet(side, to: root)
            }
            addFlare(to: root)
        }, completion: completion)
    }

    // MARK: Rail — faint border the comets ride, spikes on impact

    private func addRail(to root: CALayer) {
        let (rail, _) = BorderGeometry.gradientRail(in: bounds, colors: gradient)
        rail.opacity = 0
        root.addSublayer(rail)

        let t = timeline
        rail.add(repeating(keyframes(
            "opacity",
            [(0, 0), (t.travel * 0.3, 0.2), (t.travel, 0.2),
             (t.travel + 0.05, 0.9), (t.travel + 0.35, 0), (t.cycle, 0)]
        )), forKey: "rail")
    }

    // MARK: Comet — tail segments + glowing head + white-hot core

    private func addComet(_ side: BorderGeometry.Side, to root: CALayer) {
        let path = BorderGeometry.half(side, in: bounds)

        // Tail: back segments shade toward the gradient's second stop so
        // the comet reads as two-tone like the rest of the app.
        for (i, seg) in Self.tail.enumerated() {
            let shade = CGFloat(i) / CGFloat(max(1, Self.tail.count - 1))
            let color = gradient[1].blended(withFraction: shade, of: gradient[0]) ?? gradient[0]
            let layer = strokeLayer(path: path, color: color, width: seg.width)
            root.addSublayer(layer)
            layer.add(repeating(cometGroup(tail: seg.length, peakAlpha: seg.alpha)), forKey: "tail\(i)")
        }

        // Head: short, bright, glowing. The shadow is what sells it from
        // across the room — shape-layer shadows re-render per frame, so it
        // stays on this one layer only.
        let head = strokeLayer(path: path, color: glowColor, width: BorderGeometry.lineWidth + 2)
        glow(head, glowColor, radius: 28)
        root.addSublayer(head)
        head.add(repeating(cometGroup(tail: 0.025, peakAlpha: 1)), forKey: "head")

        let core = strokeLayer(path: path, color: .white, width: 4)
        root.addSublayer(core)
        core.add(repeating(cometGroup(tail: 0.012, peakAlpha: 0.95)), forKey: "core")
    }

    /// strokeEnd leads, strokeStart trails by `tail`; after impact the tail
    /// keeps sliding into the meeting point so the comet visibly *lands*
    /// instead of blinking out mid-stroke.
    private func cometGroup(tail: Double, peakAlpha: Float) -> CAAnimationGroup {
        let t = timeline
        var ends: [(Double, Double)] = []
        var starts: [(Double, Double)] = []
        for (time, progress) in t.samples {
            ends.append((time, progress))
            starts.append((time, max(0, progress - tail)))
        }
        ends.append((t.cycle, 1))
        starts.append((t.travel + 0.12, 1))
        starts.append((t.cycle, 1))

        let fadeIn = min(0.06, t.travel * 0.1)
        let opacity = keyframes("opacity", [
            (0, 0), (fadeIn, Double(peakAlpha)), (t.travel, Double(peakAlpha)),
            (t.travel + 0.12, 0), (t.cycle, 0),
        ])

        let group = CAAnimationGroup()
        group.animations = [keyframes("strokeEnd", ends), keyframes("strokeStart", starts), opacity]
        group.duration = t.cycle
        return group
    }

    // MARK: Flare — burst + shockwave ring at the meeting point

    private func addFlare(to root: CALayer) {
        let point = BorderGeometry.meetingPoint(in: bounds)
        let t = timeline
        let hit = t.travel

        let burst = circleLayer(radius: 34, at: point)
        burst.fillColor = glowColor.cgColor
        glow(burst, glowColor, radius: 50)
        root.addSublayer(burst)
        burst.add(repeating(group([
            keyframes("transform.scale", [(0, 0.2), (hit, 0.2), (hit + 0.18, 2.4), (t.cycle, 2.4)]),
            keyframes("opacity", [(0, 0), (hit, 0), (hit + 0.03, 1), (hit + 0.4, 0), (t.cycle, 0)]),
        ])), forKey: "burst")

        let ring = circleLayer(radius: 34, at: point)
        ring.fillColor = nil
        ring.strokeColor = gradient[1].cgColor
        ring.lineWidth = 3
        root.addSublayer(ring)
        ring.add(repeating(group([
            keyframes("transform.scale", [(0, 0.3), (hit, 0.3), (hit + 0.5, 7), (t.cycle, 7)]),
            keyframes("opacity", [(0, 0), (hit, 0), (hit + 0.03, 0.9), (hit + 0.5, 0), (t.cycle, 0)]),
        ])), forKey: "ring")
    }

    private func circleLayer(radius: CGFloat, at point: CGPoint) -> CAShapeLayer {
        let layer = CAShapeLayer()
        let box = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        layer.bounds = box
        layer.position = point
        layer.path = CGPath(ellipseIn: box, transform: nil)
        layer.opacity = 0
        return layer
    }

    // MARK: Keyframe plumbing

    /// One comet cycle is the time base for everything in this view.
    private func keyframes(_ keyPath: String, _ frames: [(Double, Double)]) -> CAKeyframeAnimation {
        keyframes(keyPath, frames, over: timeline.cycle)
    }

    private func group(_ animations: [CAAnimation]) -> CAAnimationGroup {
        group(animations, over: timeline.cycle)
    }

    private func repeating(_ anim: CAAnimation) -> CAAnimation {
        anim.repeatCount = Float(passes)
        return anim
    }
}

/// Timing for one comet pass, in seconds. Travel eases in and out (sine) so
/// the heads launch visibly and brake into the collision; the samples are
/// dense enough that linear interpolation between them is indistinguishable
/// from the curve.
struct CometTimeline {
    let travel: Double = 0.95
    let flare: Double = 0.55
    var cycle: Double { travel + flare }

    /// (seconds, progress 0…1) along the half-border.
    var samples: [(Double, Double)] {
        let n = 48
        return (0...n).map { i in
            let u = Double(i) / Double(n)
            return (travel * u, 0.5 - cos(.pi * u) / 2)
        }
    }
}

// MARK: - Success ripple

/// Thin green rings that start on the border and collapse inward as they
/// fade — "got it, you're done". Quiet on purpose: success doesn't need to
/// shout, it just needs to close the loop the alert opened.
final class SuccessRippleView: OverlayView {

    private let reduceMotion: Bool

    init(frame: NSRect, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func play(completion: @escaping () -> Void) {
        guard let root = layer else { return completion() }
        let green = NSColor(red: 0.20, green: 0.95, blue: 0.45, alpha: 1)

        runTransaction({
            // Second ring trails the first — two reads as a ripple, one
            // reads as a blink.
            for (i, delay) in [0.0, 0.14].enumerated() {
                let ring = CAShapeLayer()
                ring.frame = bounds   // anchorPoint 0.5 → scales about screen centre
                ring.path = BorderGeometry.loop(in: bounds)
                ring.fillColor = nil
                ring.strokeColor = green.cgColor
                ring.lineWidth = 6
                ring.shadowColor = green.cgColor
                ring.shadowRadius = 24
                ring.shadowOpacity = 1
                ring.shadowOffset = .zero
                ring.opacity = 0
                root.addSublayer(ring)

                var anims: [CAAnimation] = []
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0.0, i == 0 ? 1.0 : 0.6, 0.0]
                fade.keyTimes = [0, 0.18, 1]
                anims.append(fade)

                if !reduceMotion {
                    let shrink = CABasicAnimation(keyPath: "transform.scale")
                    shrink.fromValue = 1.0
                    shrink.toValue = 0.93
                    shrink.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    anims.append(shrink)

                    let thin = CABasicAnimation(keyPath: "lineWidth")
                    thin.fromValue = 7
                    thin.toValue = 1.5
                    anims.append(thin)
                }

                let g = CAAnimationGroup()
                g.animations = anims
                g.duration = 0.7
                g.beginTime = ring.convertTime(CACurrentMediaTime(), from: nil) + delay
                g.fillMode = .backwards
                ring.add(g, forKey: "ripple")
            }
        }, completion: completion)
    }
}
