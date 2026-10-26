import Foundation

/// 공백 위치와 대소문자에 관계없이 커밋을 찾는다.
struct CommitSearchQuery {
    let key: String
    let gitPattern: String

    init(_ text: String) {
        let compact = text.filter { !$0.isWhitespace }
        key = compact.lowercased()
        // Git의 확장 정규식에서도 검색어의 특수문자는 문자 그대로 취급한다.
        let special = ".*+?()[]{}^$|\\"
        gitPattern = compact.unicodeScalars.map { scalar in
            let char = String(scalar)
            return special.contains(char) ? "\\" + char : char
        }.joined(separator: "[[:space:]]*")
    }

    func matches(_ text: String) -> Bool {
        text.filter { !$0.isWhitespace }.lowercased().contains(key)
    }
}
