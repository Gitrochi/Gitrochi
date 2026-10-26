import Foundation

/// 저장소를 바꾸거나 다시 열면 오래된 확인창을 무효화하고, 같은 작업은 한 번만 실행한다.
@MainActor final class RepositoryConfirmationGuard {
    private var generation = UUID()
    func invalidate() { generation = UUID() }
    func wrap(path: String?, currentPath: @escaping @MainActor () -> String?, action: @escaping @MainActor () async -> Void) -> @MainActor () async -> Void {
        let expected = generation
        var consumed = false
        return { [weak self] in
            guard let self, self.generation == expected, currentPath() == path, !consumed else { return }
            consumed = true
            await action()
        }
    }
}
