import SwiftUI
import AppKit

/// 시스템 색을 바탕으로 라벨·선·노드를 맞추고 작은 글자의 명암을 테마별로 보정한다.
enum GraphStyle {
    private static let colors: [Color] = ([
        .systemBlue, .systemOrange, .systemGreen, .systemPurple,
        .systemYellow, .systemTeal, .systemRed, .systemIndigo,
    ] as [NSColor]).map { seed in
        Color(nsColor: NSColor(name: nil) { appearance in
            var result = seed
            appearance.performAsCurrentDrawingAppearance {
                guard let base = NSColor.textBackgroundColor.usingColorSpace(.sRGB),
                      let ink = NSColor.labelColor.usingColorSpace(.sRGB),
                      let original = seed.usingColorSpace(.sRGB) else { return }
                let opaque = original.withAlphaComponent(1)
                let text = ink.withAlphaComponent(1)
                result = opaque
                // 라벨 뒤의 옅은 색과 선택 배경까지 고려해 명암 여유를 둔다.
                for step in 0...24 {
                    result = opaque.blended(withFraction: CGFloat(step) * 0.025, of: text)?.usingColorSpace(.sRGB) ?? opaque
                    let background = base.blended(withFraction: 0.20, of: result) ?? base
                    if contrast(result, background) >= 4.7 { break }
                }
            }
            return result
        })
    }

    static func lane(_ index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }

    static let currentRefText = Color(nsColor: .textBackgroundColor)

    private static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            let rgb = color.usingColorSpace(.sRGB) ?? color
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
