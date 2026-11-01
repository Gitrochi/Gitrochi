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

    /// The status tones of docs/design.md (Badges): text on its fill, light as specified there, dark kept to the same hues
    /// with the same contrast. Status never uses the accent.
    enum Tone {
        /// Waiting, draft, running, needs action
        case waiting
        /// Failed, overdue
        case failed
        /// Passed, open
        case passed
        /// Info, assigned, review
        case info
        /// Merged, closed
        case neutral

        var text: Color {
            switch self {
            case .waiting: return Tones.waitingText
            case .failed: return Tones.failedText
            case .passed: return Tones.passedText
            case .info: return Tones.infoText
            case .neutral: return Tones.neutralText
            }
        }

        var fill: Color {
            switch self {
            case .waiting: return Tones.waitingFill
            case .failed: return Tones.failedFill
            case .passed: return Tones.passedFill
            case .info: return Tones.infoFill
            case .neutral: return Tones.neutralFill
            }
        }
    }

    /// Links are the system's link colour, which the accent never changes (docs/design.md, Accent), as link buttons
    /// already draw it
    static let link = Color(nsColor: .linkColor)

    private enum Tones {
        static let waitingText = dynamic(light: 0x8a4600, dark: 0xf2b35e)
        static let waitingFill = dynamic(light: 0xf8ecdc, dark: 0x3a2c18)
        static let failedText = dynamic(light: 0xa8261f, dark: 0xff8f87)
        static let failedFill = dynamic(light: 0xfbe7e6, dark: 0x3d2120)
        static let passedText = dynamic(light: 0x1e6b34, dark: 0x6fd08f)
        static let passedFill = dynamic(light: 0xe3f2e7, dark: 0x1d3324)
        static let infoText = dynamic(light: 0x1f5a9e, dark: 0x8cb8ff)
        static let infoFill = dynamic(light: 0xe4ecf7, dark: 0x1e2c42)
        static let neutralText = dynamic(light: 0x3a3a3c, dark: 0xd1d1d6)
        static let neutralFill = dynamic(light: 0xececef, dark: 0x38383d)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255,
                           blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
        })
    }

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
