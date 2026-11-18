import AppKit

/// The menu bar item's image: Gitrochi's eyes from the app icon, as a template so macOS draws it in the menu bar's own
/// colour. The same outline is in assets/gitrochi-eyes-black.svg (viewBox 395 x 280).
enum MenuBarIcon {
    static func image(height: CGFloat = 17) -> NSImage {
        let size = NSSize(width: (height * 395 / 280).rounded(), height: height)
        let image = NSImage(size: size, flipped: true) { rect in
            let scale = rect.height / 280
            let path = NSBezierPath()
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: y * scale) }
            path.move(to: p(89.9, 53.5))
            path.curve(to: p(74.3, 73.8), controlPoint1: p(81, 56.6), controlPoint2: p(77.4, 65.5))
            path.curve(to: p(65.1, 129.5), controlPoint1: p(67.5, 91.2), controlPoint2: p(63.5, 110.8))
            path.curve(to: p(86.5, 151), controlPoint1: p(66, 140.5), controlPoint2: p(71.9, 158))
            path.curve(to: p(111.1, 103.5), controlPoint1: p(101.9, 143.6), controlPoint2: p(106.9, 108))
            path.curve(to: p(111.1, 161.6), controlPoint1: p(116.5, 119.2), controlPoint2: p(116, 145.8))
            path.curve(to: p(95.9, 180.4), controlPoint1: p(108.7, 169.5), controlPoint2: p(104.6, 178))
            path.curve(to: p(67.6, 173.9), controlPoint1: p(86.5, 183.1), controlPoint2: p(75.8, 178.1))
            path.curve(to: p(21.5, 125), controlPoint1: p(47.4, 163.7), controlPoint2: p(30.5, 145.8))
            path.curve(to: p(22.1, 36.6), controlPoint1: p(9.5, 97.1), controlPoint2: p(10.6, 64.6))
            path.curve(to: p(40.1, 11.7), controlPoint1: p(25.5, 28.3), controlPoint2: p(30.7, 14.7))
            path.curve(to: p(58.1, 18.4), controlPoint1: p(46.3, 9.7), controlPoint2: p(53.5, 14.8))
            path.curve(to: p(89.9, 53.5), controlPoint1: p(70.2, 28), controlPoint2: p(82.4, 39.8))
            path.close()
            path.move(to: p(309.6, 156.5))
            path.curve(to: p(310.8, 184.3), controlPoint1: p(317.3, 164.8), controlPoint2: p(314.2, 174.3))
            path.curve(to: p(275.5, 240.9), controlPoint1: p(304.7, 202.8), controlPoint2: p(293.2, 230.7))
            path.curve(to: p(251.3, 213.8), controlPoint1: p(252.6, 254.1), controlPoint2: p(245.7, 232.4))
            path.curve(to: p(258.6, 193), controlPoint1: p(253.4, 206.7), controlPoint2: p(255.7, 199.8))
            path.curve(to: p(275.2, 165.5), controlPoint1: p(263, 182.9), controlPoint2: p(268.2, 174))
            path.curve(to: p(262.9, 170.3), controlPoint1: p(270.9, 166.2), controlPoint2: p(266.9, 168.5))
            path.curve(to: p(215, 209.6), controlPoint1: p(244.2, 178.6), controlPoint2: p(225.7, 191.7))
            path.curve(to: p(208.7, 237.9), controlPoint1: p(210.2, 217.7), controlPoint2: p(205, 228.3))
            path.curve(to: p(297.3, 266.7), controlPoint1: p(218.9, 264.6), controlPoint2: p(273.4, 271.2))
            path.curve(to: p(368, 216.5), controlPoint1: p(327.8, 261), controlPoint2: p(351.6, 242.4))
            path.curve(to: p(375.6, 164.9), controlPoint1: p(375.9, 204.1), controlPoint2: p(388.7, 177.3))
            path.curve(to: p(338.5, 155.2), controlPoint1: p(366.6, 156.5), controlPoint2: p(350, 156))
            path.curve(to: p(309.6, 156.5), controlPoint1: p(329.1, 154.5), controlPoint2: p(318.8, 154.9))
            path.close()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Gitrochi"
        return image
    }
}
