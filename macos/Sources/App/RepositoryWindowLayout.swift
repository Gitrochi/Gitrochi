import AppKit

/// 저장소 화면은 시스템 타이틀바·툴바 아래의 콘텐츠 영역에만 배치한다.
@MainActor
enum RepositoryWindowLayout {
    static func configure(_ window: NSWindow) {
        guard window.styleMask.contains(.fullSizeContentView) else { return }
        // SwiftUI의 전체 크기 콘텐츠 창은 사용자 정의 사이드바도 창 버튼 뒤까지 확장할 수 있다.
        // AppKit이 툴바·탭·전체화면에 맞춰 콘텐츠 영역을 관리하게 하고, 복원된 창 위치·크기는 유지한다.
        let frame = window.frame
        window.styleMask.remove(.fullSizeContentView)
        window.setFrame(frame, display: false)
    }
}
