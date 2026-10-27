import SwiftUI

/// 탐색·편집·상세 패널이 같은 네이티브 표면과 선택 규칙을 쓰게 한다.
enum StudioStyle {
    static let accent = Color.accentColor
    static let canvas = neutralSurface(0.035)
    static let surface = Color(nsColor: .textBackgroundColor)
    static let sidebar = neutralSurface(0.015)
    static let border = Color.primary.opacity(0.09)
    static let selection = accent.opacity(0.12)
    static let hover = Color.primary.opacity(0.035)
    static let added = Color(nsColor: .systemGreen)
    static let deleted = Color(nsColor: .systemRed)
    static let cornerRadius: CGFloat = 9
    static let rowHeight: CGFloat = 32

    // 시스템의 글자·표면 색 사이에서만 섞어 두 테마에 같은 명도 위계를 만든다.
    private static func neutralSurface(_ fraction: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            var result = NSColor.textBackgroundColor
            appearance.performAsCurrentDrawingAppearance {
                result = NSColor.textBackgroundColor.blended(withFraction: fraction, of: .labelColor) ?? .textBackgroundColor
            }
            return result
        })
    }
}
