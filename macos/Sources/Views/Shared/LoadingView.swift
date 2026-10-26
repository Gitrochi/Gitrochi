import SwiftUI
import AppKit

/// Shown while a repository opens or clones: the app icon breathes slowly while its newest commit glows.
/// Windows draws the same picture (shared/ui/LoadingView.tsx).
struct LoadingView: View {
    let title: String
    let step: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            Group {
                if reduceMotion {
                    GitrochiMark(phase: 0)
                } else {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        GitrochiMark(phase: t.truncatingRemainder(dividingBy: GitrochiMark.period) / GitrochiMark.period)
                    }
                }
            }
            .frame(width: 176, height: 176)

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(step ?? " ")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.72))
                    .id(step ?? "")
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.25), value: step)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 배경만 가장자리까지 칠하고 로고·진행 문구는 창의 안전 영역 안에 둔다.
        .background {
            ZStack {
                LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.17), Color(red: 0.03, green: 0.04, blue: 0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(red: 0.24, green: 0.35, blue: 1).opacity(0.16), .clear], center: .center, startRadius: 10, endRadius: 340)
            }
            .ignoresSafeArea()
        }
    }
}

/// One frame of the app icon breathing; phase is 0…1 per breath.
struct GitrochiMark: View {
    static let period: Double = 3.2

    let phase: Double

    /// The icon file itself (up to 1024 px); NSApp.applicationIconImage is a small copy the system restyles
    private static let icon: NSImage = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
    private static let rim = Color(red: 0.24, green: 0.35, blue: 1)
    private static let green = Color(red: 0.29, green: 0.87, blue: 0.5)
    /// Where the green commit sits in the icon (unit square)
    private static let newest = CGPoint(x: 0.716, y: 0.648)

    var body: some View {
        let breath = (1 - cos(phase * 2 * .pi)) / 2
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Self.rim.opacity(0.22 + 0.14 * breath), .clear], center: .center, startRadius: s * 0.2, endRadius: s * 0.62))
                    .frame(width: s * 1.3, height: s * 1.3)
                Image(nsImage: Self.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: s, height: s)
                    .overlay {
                        Circle()
                            .fill(RadialGradient(colors: [Self.green.opacity(0.55 * breath), .clear], center: .center, startRadius: 0, endRadius: s * 0.14))
                            .frame(width: s * 0.28, height: s * 0.28)
                            .position(x: Self.newest.x * s, y: Self.newest.y * s)
                            .blendMode(.plusLighter)
                    }
                    .scaleEffect(0.985 + 0.025 * breath)
            }
            .frame(width: s, height: s)
        }
    }
}
