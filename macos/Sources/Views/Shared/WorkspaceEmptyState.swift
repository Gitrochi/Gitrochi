import SwiftUI

/// 비어 있는 작업 패널에도 같은 정보 위계와 다음 행동을 제공한다.
struct WorkspaceEmptyState: View {
    let title: String
    let systemImage: String
    let description: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 23, weight: .regular))
                .foregroundStyle(StudioStyle.accent)
                .frame(width: 52, height: 52)
                .background(StudioStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(spacing: 5) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(LocalizedStringKey(description))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(LocalizedStringKey(actionTitle), action: action)
                    .controlSize(.regular)
                    .tint(StudioStyle.accent)
                    .padding(.top, 2)
            }
        }
        .padding(24)
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
