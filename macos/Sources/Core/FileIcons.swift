import Foundation

/// Which icon and colour a file gets, from its name: a language's own colour for source code, a type's shape for data,
/// images, archives and the like, grey for the rest. (Windows: shared/lib/file-icon.ts)
struct FileIcon: Equatable {
    enum Kind: Equatable { case code, style, json, config, markdown, text, sql, shell, image, archive, pdf, lock, git, docker, file }

    let kind: Kind
    /// 0xRRGGBB, or nil for the caption grey
    let color: Int?

    static let plain = FileIcon(kind: .file, color: nil)

    static func of(_ path: String) -> FileIcon {
        let name = (path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "").lowercased()
        if let icon = byName[name] { return icon }
        if name.hasPrefix("dockerfile") { return byName["dockerfile"]! }
        if name.hasPrefix(".env") { return byName[".env"]! }
        guard let dot = name.lastIndex(of: "."), name.index(after: dot) < name.endIndex else { return plain }
        return byExtension[String(name[name.index(after: dot)...])] ?? plain
    }

    private static func code(_ color: Int) -> FileIcon { FileIcon(kind: .code, color: color) }

    private static let byExtension: [String: FileIcon] = {
        var map: [String: FileIcon] = [
            "swift": code(0xf05138), "rs": code(0xce422b), "py": code(0x3776ab), "go": code(0x00add8), "java": code(0xb07219),
            "cs": code(0x239120), "rb": code(0xcc342d), "php": code(0x777bb4), "dart": code(0x0175c2), "scala": code(0xdc322f),
            "lua": code(0x51a0cf), "vue": code(0x41b883), "svelte": code(0xff3e00), "xml": code(0xe37933), "zig": code(0xf7a41d),
            "css": FileIcon(kind: .style, color: 0x663399), "less": FileIcon(kind: .style, color: 0x4a6fa5),
            "toml": FileIcon(kind: .config, color: 0x9c4221), "sql": FileIcon(kind: .sql, color: 0xe38c00),
            "svg": FileIcon(kind: .image, color: 0xffb13b), "pdf": FileIcon(kind: .pdf, color: 0xe2574c), "lock": FileIcon(kind: .lock, color: nil),
        ]
        func add(_ extensions: [String], _ icon: FileIcon) { for value in extensions { map[value] = icon } }
        add(["ts", "tsx", "mts", "cts"], code(0x3178c6))
        add(["js", "jsx", "mjs", "cjs"], code(0xd4a017))
        add(["kt", "kts"], code(0x7f52ff))
        add(["c", "h"], code(0x5c6bc0))
        add(["cpp", "cc", "hpp"], code(0x00599c))
        add(["m", "mm"], code(0x438eff))
        add(["html", "htm"], code(0xe34c26))
        add(["scss", "sass"], FileIcon(kind: .style, color: 0xcc6699))
        add(["json", "jsonc", "json5"], FileIcon(kind: .json, color: 0xc09000))
        add(["yml", "yaml"], FileIcon(kind: .config, color: 0xcb171e))
        add(["ini", "conf", "env", "plist"], FileIcon(kind: .config, color: nil))
        add(["md", "markdown", "mdx"], FileIcon(kind: .markdown, color: 0x519aba))
        add(["txt", "log"], FileIcon(kind: .text, color: nil))
        add(["csv", "tsv"], FileIcon(kind: .text, color: 0x217346))
        add(["sh", "bash", "zsh", "fish"], FileIcon(kind: .shell, color: 0x4eaa25))
        add(["ps1", "bat", "cmd"], FileIcon(kind: .shell, color: 0x2671be))
        add(["png", "jpg", "jpeg", "gif", "webp", "ico", "heic"], FileIcon(kind: .image, color: 0xa074c4))
        add(["zip", "tar", "gz", "tgz", "7z", "rar", "dmg"], FileIcon(kind: .archive, color: 0x8d6e63))
        return map
    }()

    private static let byName: [String: FileIcon] = {
        let docker = FileIcon(kind: .docker, color: 0x2496ed), git = FileIcon(kind: .git, color: 0xf14e32), lock = FileIcon(kind: .lock, color: nil)
        return [
            "dockerfile": docker, "docker-compose.yml": docker, "compose.yaml": docker,
            "makefile": FileIcon(kind: .config, color: 0x6d8086), ".gitignore": git, ".gitattributes": git, ".gitmodules": git,
            "package-lock.json": lock, "pnpm-lock.yaml": lock, "yarn.lock": lock,
            "license": FileIcon(kind: .text, color: nil), ".env": FileIcon(kind: .config, color: nil),
        ]
    }()
}
