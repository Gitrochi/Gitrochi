import Foundation
import AppKit

/// 화면 언어. 한국어 글자를 그대로 키로 쓰고 Resources/<언어>.lproj/Localizable.strings 에서 번역을 찾는다.
/// 기본은 영어이고, 설정 > 화면에서 바꾸면 앱을 다시 시작해 적용한다(AppleLanguages).
enum AppLanguage {
    struct Option: Identifiable, Hashable {
        let code: String
        /// 그 언어로 쓴 이름
        let name: String
        var id: String { code }
    }

    static let options: [Option] = [
        ("id", "Bahasa Indonesia"), ("cs", "Čeština"), ("de", "Deutsch"), ("en", "English"),
        ("es", "Español"), ("fr", "Français"), ("it", "Italiano"), ("hu", "Magyar"),
        ("nl", "Nederlands"), ("pl", "Polski"), ("pt-BR", "Português (Brasil)"), ("tr", "Türkçe"),
        ("ru", "Русский"), ("uk", "Українська"), ("th", "ภาษาไทย"), ("vi", "Tiếng Việt"),
        ("ja", "日本語"), ("ko", "한국어"), ("zh-Hans", "简体中文"), ("zh-Hant", "正體中文"),
    ].map { Option(code: $0.0, name: $0.1) }

    /// 기본 화면 언어(설정에서 바꾸기 전)
    static let defaultCode = "en"
    /// 설정에 저장한 선택("system" 이면 시스템 언어를 따른다)
    static let key = "appLanguage"

    static var choice: String { UserDefaults.standard.string(forKey: key) ?? defaultCode }

    /// 앱이 뜨기 전에 부른다: 고른 언어를 이 앱의 AppleLanguages 로(시스템이면 지운다)
    static func applyChoice() {
        let d = UserDefaults.standard
        if choice == "system" { d.removeObject(forKey: "AppleLanguages") } else { d.set([choice], forKey: "AppleLanguages") }
    }

    static func select(_ code: String) {
        UserDefaults.standard.set(code, forKey: key)
        applyChoice()
    }

    /// 지금 화면에 쓰는 언어(번역 묶음 기준)
    static var current: String { Bundle.main.preferredLocalizations.first ?? defaultCode }

    /// Keep the offline graph in the app language, including an explicit choice before relaunch.
    static var graphCode: String { graphCode(for: choice == "system" ? current : choice) }

    /// Windows: graphLanguage in entities/gitch/model/gitch.ts.
    static func graphCode(for language: String) -> String {
        let code = language.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? "en"
        return ["en", "ko", "ja"].contains(code) ? code : "en"
    }

    static var locale: Locale { Locale(identifier: current) }

    /// AI 에게 쓰라고 할 언어 이름(영어)
    static var englishName: String {
        Locale(identifier: "en").localizedString(forIdentifier: current) ?? "English"
    }

    /// 앱을 끄고 다시 연다(언어를 바꾼 뒤)
    @MainActor static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
