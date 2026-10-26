#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

@main struct MarkdownTests {
    static func inlineNodes(_ blocks: [Markdown.Block]) -> [Markdown.Inline] {
        blocks.flatMap { block in
            switch block {
            case .paragraph(let nodes), .heading(_, let nodes): return nodes
            case .quote(let blocks), .details(_, let blocks): return inlineNodes(blocks)
            case .list(_, _, let items): return items.flatMap { inlineNodes($0.blocks) }
            case .table(_, let head, let rows): return head.flatMap { $0 } + rows.flatMap { $0.flatMap { $0 } }
            default: return []
            }
        }
    }
    static func imageURLs(_ nodes: [Markdown.Inline]) -> [String] {
        nodes.flatMap { node in
            switch node {
            case .image(let src, _): return [src]
            case .strong(let children), .em(let children), .strike(let children), .link(_, let children): return imageURLs(children)
            default: return []
            }
        }
    }
    static func images(_ source: String, page: URL? = nil, base: URL? = nil) -> [String] {
        imageURLs(inlineNodes(Markdown.parse(source, baseURL: page, imageBaseURL: base)))
    }
    static func main() {
        let source = """
        ## What and **why**

        A paragraph with [a link](https://example.com), *emphasis*, ~~removed~~ and `inline code`.

        - [x] **Complete**
          - Nested item
        - [ ] Pending

        3. Third
        4. Fourth

        > A quote
        >
        > Second paragraph

        ```html
        <img src="https://example.com/code.png">
        ```

        | Name | Value |
        | :--- | ---: |
        | one | 1 |

        ![Screenshot](https://example.com/image.png)

        ---

        <details><summary>More</summary>

        Hidden **detail**

        </details>
        """
        let blocks = Markdown.parse(source)
        precondition(blocks.count == 10)
        precondition(blocks[0] == .heading(level: 2, [.text("What and "), .strong([.text("why")])]))
        if case .list(false, _, let items) = blocks[2] {
            precondition(items.count == 2 && items[0].task == true && items[1].task == false)
            precondition(items[0].blocks.count == 2, "Nested task detail must stay in its parent")
        } else { fatalError("Task structure lost") }
        if case .list(true, 3, let items) = blocks[3] { precondition(items.count == 2) }
        else { fatalError("Ordered list start lost") }
        if case .table(let align, let head, let rows) = blocks[6] {
            precondition(align == [.left, .right] && head.count == 2 && rows.count == 1)
        } else { fatalError("Table structure lost") }
        precondition(images(source) == ["https://example.com/image.png"], "Code samples must not become images")
        precondition(Markdown.parse("<!-- hidden -->\n\nVisible") == [.paragraph([.text("Visible")])])
        let refs = Markdown.Refs(issue: { "https://example.com/issues/" + $0 }, request: { "https://example.com/requests/" + $0 }, user: { "https://example.com/" + $0 })
        precondition(inlineNodes(Markdown.parse("#12 !4 @reviewer", refs: refs)).filter { if case .link = $0 { return true }; return false }.count == 3)

        let ghPage = URL(string: "https://github.com/team/repo/pull/42")!
        let ghBase = Markdown.repositoryImageBaseURL(webURL: ghPage, revision: "abc123")!
        precondition(ghBase.absoluteString == "https://github.com/team/repo/raw/abc123/")
        precondition(images("![relative](images/settings.png) ![blob](../blob/main/docs/settings.png?raw=true) ![absolute](https://github.com/team/repo/blob/main/docs/settings.png)", page: ghPage, base: ghBase) == ["https://github.com/team/repo/raw/abc123/images/settings.png", "https://github.com/team/repo/raw/main/docs/settings.png?raw=true", "https://github.com/team/repo/raw/main/docs/settings.png"])
        let marker = Markdown.parse("[🖼 Dark settings](images/dark.png) [Regular image link](images/light.png) [🖼 Documentation](guide.md)", baseURL: ghPage, imageBaseURL: ghBase)
        precondition(imageURLs(inlineNodes(marker)) == ["https://github.com/team/repo/raw/abc123/images/dark.png"])
        let linked = Markdown.parse("Before [![Build](badge.png) status](../checks) after", baseURL: ghPage, imageBaseURL: ghBase)
        precondition(imageURLs(inlineNodes(linked)) == ["https://github.com/team/repo/raw/abc123/badge.png"])
        precondition(inlineNodes(linked).contains(.link(href: "https://github.com/team/repo/checks", children: [.image(src: "https://github.com/team/repo/raw/abc123/badge.png", alt: "Build"), .text(" status")])))
        let glPage = URL(string: "https://gitlab.test/group/sub/repo/-/merge_requests/7")!
        let glBase = Markdown.repositoryImageBaseURL(webURL: glPage, revision: "feature/images")!
        precondition(glBase.absoluteString == "https://gitlab.test/group/sub/repo/-/raw/feature%2Fimages/")
        precondition(images("![branch](images/settings.png) ![upload](/uploads/hash/settings.png) ![blob](https://gitlab.test/group/sub/repo/-/blob/main/settings.png)", page: glPage, base: glBase) == ["https://gitlab.test/group/sub/repo/-/raw/feature%2Fimages/images/settings.png", "https://gitlab.test/group/sub/repo/uploads/hash/settings.png", "https://gitlab.test/group/sub/repo/-/raw/main/settings.png"])
        precondition(images("<p align='center'><img alt='Dark &amp; light > preview' src='https://example.com/image.png?one=1&amp;two=2'></p>\n\n| Preview | Status |\n| --- | --- |\n| <IMG ALT='Settings' SRC='https://example.com/settings.png'> | Ready |") == ["https://example.com/image.png?one=1&two=2", "https://example.com/settings.png"])
        precondition(images("![private](file:///tmp/private) ![auth](https://name:secret@example.com/image.png) <img src='javascript:alert(1)'>").isEmpty)
        precondition(Markdown.resolvedURL("https://name:secret@example.com/image.png", baseURL: nil, allowMail: false) == nil)
        precondition(images("`<img src=\"https://example.com/code.png\">`\n\n    <img src=\"https://example.com/code.png\">").isEmpty)
        precondition(Markdown.parse("").isEmpty)
        print("PASS: Markdown structure, refs, linked/HTML/table/marker images, head-relative paths, GitLab uploads and safe URLs")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 \
    "$ROOT/Sources/Core/Markdown.swift" "$ROOT/Sources/Core/MarkdownInline.swift" \
    "$ROOT/Sources/Core/Models.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/markdown-tests"
"$TASK_TMP/markdown-tests"
