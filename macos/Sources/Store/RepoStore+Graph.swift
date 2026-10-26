import SwiftUI

/// 그래프에 끌어다 놓았을 때 고를 수 있는 동작
struct DropChoice: Identifiable {
    let id = UUID()
    let title: String
    var destructive = false
    let action: @MainActor () async -> Void
}

struct DropRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let choices: [DropChoice]
}

/// 그래프에서 바로 하는 브랜치 작업: 끌어다 놓기(머지·리베이스·빨리 감기·cherry-pick)
extension RepoStore {
    static let branchPayload = "gitrochi-branch:"
    static let commitPayload = "gitrochi-commit:"

    func branch(named name: String) -> Branch? {
        localBranches.first { $0.name == name } ?? remoteBranches.first { $0.name == name }
    }

    private func fullRef(_ name: String) -> String {
        if let b = branch(named: name) { return b.isRemote ? "refs/remotes/\(b.name)" : "refs/heads/\(b.name)" }
        return name
    }

    func isAncestor(_ a: String, of b: String) async -> Bool {
        guard let url, let r = try? await Git.raw(["merge-base", "--is-ancestor", a, b], in: url) else { return false }
        return r.status == 0
    }

    /// 커밋 줄에 무언가를 놓았을 때. 그 줄의 브랜치(현재 브랜치 우선, 없으면 로컬, 원격 순)를 대상으로 삼는다.
    /// 끌고 온 브랜치 자신(과 그 원격 추적 브랜치)은 대상에서 뺀다 — 같은 커밋에 main 과 feature 가 함께 있을 때
    /// feature 를 그 줄에 놓으면 main 이 대상이 되게.
    func handleDrop(_ payload: String, onto entry: GraphEntry) {
        guard !entry.commit.isPending, busy == nil else { return }
        let refs = refsByCommit[entry.id] ?? []
        func pick(_ list: [RefLabel]) -> String? {
            list.first { $0.kind == .local && $0.isCurrent }?.name
                ?? list.first { $0.kind == .local }?.name
                ?? list.first { $0.kind == .remote }?.name
        }

        if payload.hasPrefix(Self.branchPayload) {
            let source = String(payload.dropFirst(Self.branchPayload.count))
            let short = source.split(separator: "/", maxSplits: 1).last.map(String.init) ?? source
            let others = refs.filter { r in
                r.name != source && !(r.kind == .remote && r.name.hasSuffix("/" + short) && branch(named: source)?.isRemote == false)
            }
            if let target = pick(others) {
                Task { await offerBranchDrop(source, onto: target) }
            } else if branch(named: source)?.target == entry.id {
                return      // 자기 자신의 커밋에 놓음
            } else {
                offerBranchOnCommit(source, entry.commit)
            }
        } else if payload.hasPrefix(Self.commitPayload) {
            let target = pick(refs)
            let sha = String(payload.dropFirst(Self.commitPayload.count))
            guard sha != entry.id else { return }
            offerCommitDrop(sha, onto: target)
        }
    }

    /// 브랜치를 다른 브랜치에 놓았을 때
    private func offerBranchDrop(_ source: String, onto target: String) async {
        let current = headBranch
        let sourceRef = fullRef(source), targetRef = fullRef(target)
        let targetIsLocal = localBranches.contains { $0.name == target }
        let sourceIsLocal = localBranches.contains { $0.name == source }

        if await isAncestor(sourceRef, of: targetRef) {
            dropRequest = DropRequest(title: String(localized: "'\(source)' is already in '\(target)'"),
                                      message: String(localized: "No new commits to merge."), choices: [])
            return
        }
        var choices: [DropChoice] = []
        // 대상이 원본의 조상이면 머지 커밋 없이 앞으로 옮기기만 하면 된다
        if targetIsLocal, await isAncestor(targetRef, of: sourceRef) {
            if target == current {
                choices.append(DropChoice(title: String(localized: "Fast-forward '\(target)' (current) to '\(source)'")) { [weak self] in
                    await self?.run(String(localized: "Fast-forwarding…"), ["merge", "--ff-only", source])
                })
            } else {
                choices.append(DropChoice(title: String(localized: "Fast-forward '\(target)' to '\(source)'")) { [weak self] in
                    await self?.run(String(localized: "Fast-forwarding…"), ["fetch", ".", "\(sourceRef):refs/heads/\(target)"])
                })
            }
        }
        if target == current {
            choices.append(DropChoice(title: String(localized: "Merge '\(source)' into '\(target)' (current)")) { [weak self] in
                await self?.merge(source)
            })
            choices.append(DropChoice(title: String(localized: "Rebase '\(target)' (current) onto '\(source)'")) { [weak self] in
                await self?.rebase(onto: source)
            })
        } else if source == current {
            // 가장 흔한 경우: 작업한 브랜치(현재)를 main 같은 브랜치에 합치기
            if targetIsLocal {
                choices.append(DropChoice(title: String(localized: "Merge '\(source)' (current) into '\(target)' — checks out '\(target)'")) { [weak self] in
                    await self?.mergeBranch(source, into: target)
                })
            }
            choices.append(DropChoice(title: String(localized: "Rebase '\(source)' (current) onto '\(target)'")) { [weak self] in
                await self?.rebase(onto: target)
            })
            choices.append(DropChoice(title: String(localized: "Merge '\(target)' into '\(source)' (current)")) { [weak self] in
                await self?.merge(target)
            })
        } else {
            if targetIsLocal {
                choices.append(DropChoice(title: String(localized: "Check out '\(target)', then merge '\(source)'")) { [weak self] in
                    guard let self, await self.run(String(localized: "Checking out…"), ["switch", target]) else { return }
                    await self.merge(source)
                })
            }
            if sourceIsLocal {
                choices.append(DropChoice(title: String(localized: "Check out '\(source)', then rebase onto '\(target)'")) { [weak self] in
                    guard let self, await self.run(String(localized: "Checking out…"), ["switch", source]) else { return }
                    await self.rebase(onto: target)
                })
            }
        }
        dropRequest = DropRequest(title: "'\(source)'  →  '\(target)'",
                                  message: choices.isEmpty ? String(localized: "There's nothing you can do here.") : String(localized: "What would you like to do? If there are conflicts, you can resolve them on the right."),
                                  choices: choices)
    }

    /// source 를 target 브랜치에 머지. target 이 현재 브랜치가 아니면 먼저 체크아웃한다(머지는 체크아웃한 브랜치에만 할 수 있다).
    func mergeBranch(_ source: String, into target: String) async {
        if target != headBranch {
            guard await run(String(localized: "Checking out '\(target)'…"), ["switch", target]) else { return }
        }
        await merge(source)
    }

    /// 머지할 대상으로 고를 만한 로컬 브랜치(main·master·develop 먼저)
    func mergeTargets(excluding name: String) -> [Branch] {
        let preferred = ["main", "master", "develop", "dev"]
        return localBranches.filter { $0.name != name }.sorted { a, b in
            let ia = preferred.firstIndex(of: a.name) ?? preferred.count, ib = preferred.firstIndex(of: b.name) ?? preferred.count
            return ia != ib ? ia < ib : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// 브랜치를 브랜치 없는 커밋에 놓았을 때(현재 브랜치일 때만 의미가 있다)
    private func offerBranchOnCommit(_ source: String, _ commit: Commit) {
        let short = commit.short
        var choices: [DropChoice] = []
        if source == headBranch {
            choices.append(DropChoice(title: String(localized: "Merge this commit (\(short)) into '\(source)' (current)")) { [weak self] in
                await self?.merge(commit.id)
            })
            choices.append(DropChoice(title: String(localized: "Rebase '\(source)' (current) onto this commit (\(short))")) { [weak self] in
                await self?.rebase(onto: commit.id)
            })
        } else if localBranches.contains(where: { $0.name == source }) {
            choices.append(DropChoice(title: String(localized: "Check out '\(source)', then rebase onto this commit (\(short))")) { [weak self] in
                guard let self, await self.run(String(localized: "Checking out…"), ["switch", source]) else { return }
                await self.rebase(onto: commit.id)
            })
        }
        dropRequest = DropRequest(title: String(localized: "'\(source)'  →  commit \(short)"),
                                  message: choices.isEmpty ? String(localized: "There's nothing you can do here.") : String(localized: "What would you like to do?"),
                                  choices: choices)
    }

    /// 커밋을 브랜치에 놓았을 때: cherry-pick
    private func offerCommitDrop(_ sha: String, onto target: String?) {
        guard let target else { return }
        let short = String(sha.prefix(7))
        var choices: [DropChoice] = []
        if target == headBranch {
            choices.append(DropChoice(title: String(localized: "Cherry-pick commit \(short) onto '\(target)' (current)")) { [weak self] in
                await self?.cherryPick(sha)
            })
        } else if localBranches.contains(where: { $0.name == target }) {
            choices.append(DropChoice(title: String(localized: "Check out '\(target)', then cherry-pick commit \(short)")) { [weak self] in
                guard let self, await self.run(String(localized: "Checking out…"), ["switch", target]) else { return }
                await self.cherryPick(sha)
            })
        }
        dropRequest = DropRequest(title: String(localized: "Commit \(short)  →  '\(target)'"),
                                  message: choices.isEmpty ? String(localized: "You can't cherry-pick onto a remote branch directly.") : String(localized: "What would you like to do?"),
                                  choices: choices)
    }
}

/// 브랜치·태그 배지 우클릭 메뉴(그래프 배지와 커밋 메뉴에서 같이 쓴다)
struct RefMenu: View {
    @Environment(RepoStore.self) private var store
    let ref: RefLabel

    var body: some View {
        switch ref.kind {
        case .local, .remote:
            if let b = store.branch(named: ref.name) {
                Button(b.isRemote ? "Check out (local tracking branch)" : "Check out") { Task { await store.checkout(b) } }
                    .disabled(b.isCurrent)
                if let current = store.headBranch, !b.isCurrent {
                    Button("Merge '\(b.name)' into '\(current)'") { Task { await store.merge(b.name) } }
                    Button("Rebase '\(current)' onto '\(b.name)'") { Task { await store.rebase(onto: b.name) } }
                }
                MergeIntoMenu(source: b.name)
                Divider()
                Button("New branch from here…") { store.requestNewBranch(from: b.target, label: b.name) }
                if !b.isRemote {
                    Button("Check out in a new worktree…") { store.sheet = .addWorktree(branch: b.name, start: nil) }
                        .disabled(b.isCurrent || store.worktree(using: b.name) != nil)
                    Button("Push") { Task { await store.pushBranch(b) } }
                }
                Button("Copy name") { store.copy(b.name) }
                Button("Hide from graph") { Task { await store.setHidden(b, true) } }
                    .disabled(b.isCurrent)
                Divider()
                Button(b.isRemote ? "Delete from remote…" : "Delete…", role: .destructive) { store.confirmDelete(b) }
                    .disabled(b.isCurrent)
            }
        case .tag:
            if let t = store.tags.first(where: { $0.name == ref.name }) {
                Button("Push tag") { Task { await store.pushTag(t) } }
                Button("Copy name") { store.copy(t.name) }
                Divider()
                Button("Delete tag…", role: .destructive) { store.deleteTag(t) }
            }
        case .head:
            EmptyView()
        }
    }
}

/// '이 브랜치를 다른 브랜치에 머지' 하위 메뉴(고른 브랜치를 체크아웃한 뒤 머지)
struct MergeIntoMenu: View {
    @Environment(RepoStore.self) private var store
    let source: String

    var body: some View {
        let targets = store.mergeTargets(excluding: source)
        if !targets.isEmpty {
            Menu("Merge '\(source)' into another branch") {
                ForEach(targets) { t in
                    Button(t.isCurrent ? String(localized: "\(t.name) (current)") : t.name) { Task { await store.mergeBranch(source, into: t.name) } }
                }
            }
        }
    }
}
