#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

enum Provider: String { case github, gitlab }
struct RepoTarget { var provider: Provider; var remote: String; var host: String; var path: String }
struct PullRequest { var number: Int; var title: String; var author: String; var source: String; var target: String; var url: String; var isDraft: Bool; var updated: Date?; var body: String; var headSHA: String?; var fromFork: Bool }
struct RemoteRepo { var fullName: String; var cloneURL: String; var isPrivate: Bool; var summary: String? }
@main struct TargetTests {
    static func main() {
        let aliases = ["github-jjunhaa0211": "github.com", "gitlab-hyginopjh": "gitlab.smart-fact.co.kr"]
        let target = Hosting.target(remotes: ["origin"], urls: ["origin": "git@github-jjunhaa0211:Gitrochi/Gitrochi.git"], gitlabHosts: [], sshAliases: aliases)
        precondition(target?.provider == .github && target?.host == "github.com" && target?.path == "Gitrochi/Gitrochi")
        let gitlab = Hosting.target(remotes: ["origin"], urls: ["origin": "ssh://git@gitlab-hyginopjh:2222/group/sub/repo.git"], gitlabHosts: ["gitlab.smart-fact.co.kr"], sshAliases: aliases)
        precondition(gitlab?.provider == .gitlab && gitlab?.host == "gitlab.smart-fact.co.kr" && gitlab?.path == "group/sub/repo")
        precondition(Hosting.target(remotes: ["origin"], urls: ["origin": "https://github-jjunhaa0211/owner/repo.git"], gitlabHosts: [], sshAliases: aliases) == nil)
        precondition(Hosting.target(remotes: ["origin"], urls: ["origin": "git@github-unknown:owner/repo.git"], gitlabHosts: [], sshAliases: aliases) == nil)
        precondition(Hosting.target(remotes: ["upstream", "origin"], urls: ["upstream": "https://github.com/other/repo", "origin": "git@github-jjunhaa0211:Gitrochi/Gitrochi.git"], gitlabHosts: [], sshAliases: aliases)?.remote == "origin")
        print("Hosting targets: connected SSH aliases, GitHub/GitLab canonical API hosts, HTTPS isolation, unknown aliases and origin preference passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Services/Hosting.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-target"
"$TASK_TMP/test-target"
