import AppKit

/// Full-screen, borderless, click-through window that strokes a glowing
/// gradient border around one display and pulses it a fixed number of times.
final class BorderWindow: NSWindow {

    init(screen: NSScreen, preset: FlashColor) {
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
            gradient: preset.gradient,
            glowColor: preset.color
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

final class BorderView: NSView {

    private let gradientColors: [NSColor]
    private let glowColor: NSColor

    init(frame: NSRect, gradient: [NSColor], glowColor: NSColor) {
        gradientColors = gradient
        self.glowColor = glowColor
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = 12
        let inset = lineWidth / 2 + 8
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            xRadius: 16,
            yRadius: 16
        )
        path.lineWidth = lineWidth

        // Pass 1: soft neon glow bleeding outward from the stroke.
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = glowColor
        glow.shadowBlurRadius = 34
        glow.shadowOffset = .zero
        glow.set()
        glowColor.withAlphaComponent(0.85).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Pass 2: gradient core — clip to the stroke's shape, paint a
        // two-tone diagonal gradient through it.
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        let strokeShape = path.cgPath.copy(
            strokingWithWidth: lineWidth,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
        context.addPath(strokeShape)
        context.clip()
        NSGradient(colors: gradientColors)?.draw(in: bounds, angle: -45)
        NSGraphicsContext.restoreGraphicsState()
    }
}
