import Foundation

/// 원래 프로세스 출력과 서버 본문에는 비밀값이 있을 수 있어 연결 단계만 화면에 전달한다.
enum AccountConnectionFailure: LocalizedError {
    case missingCLI
    case credentialRead
    case verification(status: Int?)
    case identityMismatch
    case credentialSave(status: Int32?)
    case credentialAccess(status: Int32)

    var errorDescription: String? {
        switch self {
        case .missingCLI:
            return String(localized: "Couldn't find the gh CLI.")
        case .credentialRead:
            return String(localized: "Couldn't read the approved GitHub login from GitHub CLI. Retry connecting; if it still fails, sign in again.")
        case .verification(status: 401):
            return String(localized: "GitHub rejected the approved login (401). Sign in again.")
        case .verification(status: 403):
            return String(localized: "GitHub didn't allow account verification (403). Check the login's permissions, then retry connecting.")
        case let .verification(status: status?):
            guard (100...599).contains(status) else { return Self.verificationMessage }
            let code = String(status)
            return String(localized: "GitHub account verification failed (HTTP \(code)). Retry connecting.")
        case .verification:
            return Self.verificationMessage
        case .identityMismatch:
            return String(localized: "The signed-in GitHub account doesn't match this account. Sign in with the intended account.")
        case let .credentialSave(status):
            let message = String(localized: "Couldn't save the login in macOS Keychain. Allow Keychain access, then retry connecting.")
            guard let status else { return message }
            let code = String(status)
            return message + " " + String(localized: "Keychain error \(code).")
        case .credentialAccess:
            return String(localized: "Couldn't access the saved account. Allow the macOS Keychain request, then try again.")
        }
    }

    private static var verificationMessage: String {
        String(localized: "Couldn't verify the approved GitHub account. Check your connection, then retry connecting.")
    }

    static func message(for error: Error) -> String {
        if let mismatch = error as? GitHubLoginIdentity.Mismatch { return mismatch.errorDescription! }
        if let failure = error as? Self { return failure.errorDescription! }
        return String(localized: "Couldn't connect the approved GitHub account. Retry connecting before continuing.")
    }
}
