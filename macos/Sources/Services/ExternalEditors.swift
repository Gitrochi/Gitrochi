import AppKit

struct ExternalEditor: Identifiable, Equatable {
    let id: String
    let name: String
    let available: Bool
    let supportsFolders: Bool
    var applicationURL: URL?
}

struct ExternalEditorError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Opens only validated working-copy paths, through fixed application identities.
@MainActor enum ExternalEditors {
    private struct Application {
        let id: String
        let name: String
        let bundles: [String]
        let paths: [String]
        let folders: Bool
    }
    private static let applications = [
        Application(id: "vscode", name: "Visual Studio Code", bundles: ["com.microsoft.VSCode"], paths: ["Visual Studio Code.app"], folders: true),
        Application(id: "vscode-insiders", name: "Visual Studio Code Insiders", bundles: ["com.microsoft.VSCodeInsiders"], paths: ["Visual Studio Code - Insiders.app"], folders: true),
        Application(id: "xcode", name: "Xcode", bundles: ["com.apple.dt.Xcode"], paths: ["Xcode.app"], folders: true),
        Application(id: "intellij", name: "IntelliJ IDEA", bundles: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"], paths: ["IntelliJ IDEA.app", "IntelliJ IDEA CE.app"], folders: true),
        Application(id: "textedit", name: "TextEdit", bundles: ["com.apple.TextEdit"], paths: ["TextEdit.app"], folders: false),
        Application(id: "sublime", name: "Sublime Text", bundles: ["com.sublimetext.4", "com.sublimetext.3"], paths: ["Sublime Text.app"], folders: true)
    ]

    static func editors(resolve: @escaping (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [ExternalEditor] {
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        return [ExternalEditor(id: "system", name: String(localized: "System default"), available: true, supportsFolders: true)] + applications.map { application in
            let registered = application.bundles.lazy.compactMap(resolve).first
            let fallback = roots.flatMap { root in application.paths.map { root.appendingPathComponent($0) } }.first { url in
                exists(url) && application.bundles.contains(Bundle(url: url)?.bundleIdentifier ?? "")
            }
            let url = registered ?? fallback
            return ExternalEditor(id: application.id, name: application.name, available: url != nil, supportsFolders: application.folders, applicationURL: url)
        }
    }

    static func target(repository: URL, file: String?) throws -> URL {
        let root = repository.standardizedFileURL.resolvingSymlinksInPath()
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw ExternalEditorError(message: String(localized: "The repository folder is unavailable.")) }
        guard let file else { return root }
        guard RepositoryBrowser.safePath(file) else { throw ExternalEditorError(message: String(localized: "Choose a file inside this repository.")) }
        let candidate = root.appendingPathComponent(file).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.pathComponents.count > root.pathComponents.count, Array(candidate.pathComponents.prefix(root.pathComponents.count)) == root.pathComponents else { throw ExternalEditorError(message: String(localized: "Choose a file inside this repository.")) }
        guard (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw ExternalEditorError(message: String(localized: "The local file is missing or is not a regular file.")) }
        return candidate
    }

    static func permitsSystemDefault(_ file: URL) -> Bool {
        let executable = (try? file.resourceValues(forKeys: [.isExecutableKey]).isExecutable) == true
        let blocked = Set([
            "app", "command", "sh", "bash", "zsh", "fish", "csh", "ksh", "workflow", "scpt", "scptd", "applescript",
            "exe", "com", "bat", "cmd", "ps1", "psm1", "vbs", "vbe", "js", "jse", "jar", "py", "pyw", "rb", "pl",
            "run", "pkg", "dmg", "lnk", "url", "webloc", "desktop", "html", "htm", "svg", "wsf", "wsh", "msi", "msp",
            "scr", "pif", "hta", "reg", "jnlp", "application", "appref-ms", "xhtml", "xht", "svgz", "mhtml", "mht", "cpl"
        ])
        return !executable && !blocked.contains(file.pathExtension.lowercased())
    }

    static func open(repository: URL, editorID: String, file: String?, available: [ExternalEditor]? = nil, launch: (([URL], URL) async throws -> Void)? = nil) async throws {
        guard let editor = (available ?? editors()).first(where: { $0.id == editorID }), ["system", "vscode", "vscode-insiders", "xcode", "intellij", "textedit", "sublime"].contains(editorID) else { throw ExternalEditorError(message: String(localized: "Choose a supported application.")) }
        guard editor.available else { throw ExternalEditorError(message: String(localized: "This application is not installed.")) }
        guard file != nil || editor.supportsFolders else { throw ExternalEditorError(message: String(localized: "This application cannot open a repository folder.")) }
        let destination = try target(repository: repository, file: file)
        let application: URL?
        if editorID == "system" {
            guard file == nil || permitsSystemDefault(destination) else { throw ExternalEditorError(message: String(localized: "Open executable files in a text editor instead.")) }
            application = file == nil ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") : NSWorkspace.shared.urlForApplication(toOpen: destination)
        } else { application = editor.applicationURL }
        guard let application else { throw ExternalEditorError(message: String(localized: "Not installed")) }
        let root = repository.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let applicationPath = application.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard applicationPath.count < root.count || Array(applicationPath.prefix(root.count)) != root else { throw ExternalEditorError(message: String(localized: "Applications inside the repository cannot be launched.")) }
        if let launch { try await launch([destination], application); return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([destination], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
