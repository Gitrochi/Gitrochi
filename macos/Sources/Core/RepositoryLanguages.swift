import Foundation

/// File-count statistics describe the loaded Git tree, including documents and configuration.
enum RepositoryLanguages {
    struct Segment: Identifiable, Equatable {
        let language: String
        let count: Int
        let bytes: Int
        let fraction: Double
        var id: String { language }
    }

    private static let languages = ["ts": "TypeScript", "tsx": "TypeScript", "mts": "TypeScript", "cts": "TypeScript",
                         "js": "JavaScript", "jsx": "JavaScript", "mjs": "JavaScript", "cjs": "JavaScript",
                         "md": "Markdown", "markdown": "Markdown", "rst": "reStructuredText", "txt": "Plain text", "log": "Plain text",
                         "json": "JSON", "jsonc": "JSON", "jsonl": "JSON", "yml": "YAML", "yaml": "YAML", "toml": "TOML",
                         "ini": "Configuration", "cfg": "Configuration", "conf": "Configuration", "properties": "Configuration",
                         "html": "HTML", "htm": "HTML", "css": "CSS", "scss": "SCSS", "sass": "Sass", "less": "Less",
                         "xml": "XML", "svg": "SVG", "vue": "Vue", "svelte": "Svelte", "csv": "CSV", "tsv": "TSV",
                         "swift": "Swift", "rs": "Rust", "py": "Python", "pyi": "Python", "go": "Go", "java": "Java",
                         "kt": "Kotlin", "kts": "Kotlin", "cs": "C#", "c": "C", "h": "C", "cpp": "C++", "cc": "C++", "hpp": "C++",
                         "m": "Objective-C", "mm": "Objective-C++", "rb": "Ruby", "php": "PHP", "dart": "Dart",
                         "sh": "Shell", "bash": "Shell", "zsh": "Shell", "fish": "Shell", "ps1": "PowerShell", "sql": "SQL"]

    static func language(for path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        if ["dockerfile", "containerfile"].contains(name) { return "Dockerfile" }
        if ["makefile", "gnumakefile"].contains(name) { return "Makefile" }
        if [".gitignore", ".gitattributes", ".editorconfig", ".npmrc", ".nvmrc"].contains(name) { return "Configuration" }
        let ext = (name as NSString).pathExtension
        return languages[ext] ?? "Other files"
    }

    static func composition(_ entries: [RepositoryTreeEntry]) -> [Segment] {
        var values: [String: (Int, Int)] = [:], total = 0
        for entry in entries where entry.isFile {
            let language = language(for: entry.path), previous = values[language] ?? (0, 0)
            values[language] = (previous.0 + 1, previous.1 + entry.size); total += 1
        }
        guard total > 0 else { return [] }
        return values.map { Segment(language: $0.key, count: $0.value.0, bytes: $0.value.1, fraction: Double($0.value.0) / Double(total)) }
            .sorted { $0.count == $1.count ? $0.language < $1.language : $0.count > $1.count }
    }
}
