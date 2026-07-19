import AppKit

/// Full-screen, borderless, click-through window that strokes a glowing
/// gradient border around one display and pulses it a fixed number of times.
final class BorderWindow: NSWindow {

    /// `gradient`/`glowColor` are resolved by the caller, once per alert —
    /// not read from a preset here — so that when the color is "random",
    /// every display in a multi-monitor pulse shows the same roll instead
    /// of each window rolling its own.
    init(screen: NSScreen, gradient: [NSColor], glowColor: NSColor) {
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = BorderView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            gradient: gradient,
            glowColor: glowColor
        )
    }

    /// Pulses the border `flashes` times over ~2s, then dismisses.
    /// Completion is called on the main thread.
    func pulse(flashes: Int, then completion: @escaping () -> Void) {
        alphaValue = 1
        orderFrontRegardless()

        guard let layer = contentView?.layer else {
            orderOut(nil)
            DispatchQueue.main.async(execute: completion)
            return
        }

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0.0, 1.0, 1.0, 0.08]
        anim.keyTimes = [0.0, 0.25, 0.55, 1.0]
        anim.duration = 0.5
        anim.repeatCount = Float(flashes)
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.orderOut(nil)
            DispatchQueue.main.async(execute: completion)
        }
        layer.add(anim, forKey: "flashPulse")
        CATransaction.commit()
    }
}

/// Layer-backed instead of draw(_:)-backed: a static linear gradient drawn
/// across the whole screen and clipped to a thin 12pt stroke barely reads as
/// a gradient at all — most of any given edge sits in a narrow slice of that
/// diagonal, and the solid-color glow bleeding outward drowns it out further.
/// A conic gradient masked to the stroke guarantees both colors are always
/// visible somewhere around the border, and spinning it during the pulse is
/// what actually makes it read as a gradient instead of a flat wash.
final class BorderView: NSView {

    private let lineWidth: CGFloat = 12
    private let inset: CGFloat
    private let glowLayer = CAShapeLayer()
    private let gradientLayer = CAGradientLayer()
    private let gradientMask = CAShapeLayer()

    init(frame: NSRect, gradient: [NSColor], glowColor: NSColor) {
        inset = lineWidth / 2 + 8
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear

        glowLayer.fillColor = nil
        glowLayer.strokeColor = glowColor.cgColor
        glowLayer.lineWidth = lineWidth
        glowLayer.shadowColor = glowColor.cgColor
        glowLayer.shadowRadius = 42
        glowLayer.shadowOpacity = 1
        glowLayer.shadowOffset = .zero
        layer?.addSublayer(glowLayer)

        // First color repeats at the end so the wheel loops with no seam.
        gradientLayer.type = .conic
        gradientLayer.colors = [gradient[0], gradient[1], gradient[0]].map(\.cgColor)
        gradientLayer.locations = [0.0, 0.5, 1.0]
        gradientMask.fillRule = .evenOdd
        gradientLayer.mask = gradientMask
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
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            xRadius: 16,
            yRadius: 16
        )
        path.lineWidth = lineWidth

        glowLayer.frame = bounds
        glowLayer.path = path.cgPath

        gradientLayer.frame = bounds
        gradientMask.frame = bounds
        gradientMask.path = path.cgPath.copy(
            strokingWithWidth: lineWidth,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
    }
}
