import SwiftUI

extension RepoStore {
    enum CommitImpactState {
        case idle
        case running
        case ready(CommitReviewReport, stale: Bool)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    /// 스테이지 변경이나 저장소 이동 중에 끝난 이전 요청이 새 결과를 덮지 않게 세대를 확인한다.
    func analyzeCommitImpact() async {
        guard let url, !commitImpactState.isRunning, !status.staged.isEmpty, status.conflicted.isEmpty else { return }
        commitImpactGeneration += 1
        let generation = commitImpactGeneration
        commitImpactValidationTask?.cancel()
        commitImpactValidationError = nil
        commitImpactState = .running
        do {
            let report = try await Gitch.commitReview(in: url)
            guard self.url == url, commitImpactGeneration == generation else { return }
            // 명령이 끝난 뒤의 외부 stage·commit 도 놓치지 않게 현재 값을 다시 읽는다.
            let revision = commitImpactRevision
            do {
                let current = try await Gitch.commitReviewStamp(in: url)
                guard self.url == url, commitImpactGeneration == generation else { return }
                commitImpactState = .ready(report, stale: revision != commitImpactRevision || !report.isCurrent(comparedTo: current))
                if revision != commitImpactRevision { queueCommitImpactValidation() }
            } catch {
                guard self.url == url, commitImpactGeneration == generation else { return }
                commitImpactState = .ready(report, stale: true)
                commitImpactValidationError = describe(error)
            }
        } catch {
            guard self.url == url, commitImpactGeneration == generation else { return }
            commitImpactState = .failed(describe(error))
        }
    }

    /// 인덱스·HEAD 감시 때 먼저 오래된 결과로 표시하고, 값이 같은 메타데이터 갱신은 다시 유효하게 돌린다.
    func queueCommitImpactValidation() {
        commitImpactRevision += 1
        guard case .ready(let report, _) = commitImpactState else { return }
        commitImpactState = .ready(report, stale: true)
        commitImpactValidationTask?.cancel()
        commitImpactValidationTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await validateCommitImpact()
        }
    }

    func validateCommitImpact() async {
        guard let url, case .ready(let report, _) = commitImpactState else { return }
        let generation = commitImpactGeneration
        let revision = commitImpactRevision
        do {
            let current = try await Gitch.commitReviewStamp(in: url)
            guard !Task.isCancelled, self.url == url, generation == commitImpactGeneration,
                  revision == commitImpactRevision else { return }
            commitImpactState = .ready(report, stale: !report.isCurrent(comparedTo: current))
            commitImpactValidationError = nil
        } catch {
            guard !Task.isCancelled, self.url == url, generation == commitImpactGeneration,
                  revision == commitImpactRevision else { return }
            commitImpactState = .ready(report, stale: true)
            commitImpactValidationError = describe(error)
        }
    }

    func resetCommitImpact() {
        commitImpactGeneration += 1
        commitImpactRevision += 1
        commitImpactValidationTask?.cancel()
        commitImpactValidationTask = nil
        commitImpactState = .idle
        commitImpactValidationError = nil
    }

    /// 화면의 결과와 같은 스테이지 범위로 새 그래프를 만들고, 완료 뒤 목록의 유효성도 다시 확인한다.
    func openCommitImpactGraph() async {
        guard let url, graphJob == nil, !status.staged.isEmpty, status.conflicted.isEmpty,
              case .ready(let report, false) = commitImpactState else { return }
        let generation = commitImpactGeneration
        graphJob = .draw(.files)
        defer { graphJob = nil }
        do {
            let before = try await Gitch.commitReviewStamp(in: url)
            guard self.url == url, generation == commitImpactGeneration else { return }
            guard report.isCurrent(comparedTo: before) else {
                commitImpactState = .ready(report, stale: true)
                return
            }
            let page = try await Gitch.commitReviewPage(in: url)
            let after = try await Gitch.commitReviewStamp(in: url)
            guard self.url == url, generation == commitImpactGeneration else { return }
            guard before == after, report.isCurrent(comparedTo: after) else {
                commitImpactState = .ready(report, stale: true)
                return
            }
            await openGraphPage(page)
        } catch {
            guard self.url == url, generation == commitImpactGeneration else { return }
            errorMessage = describe(error)
        }
    }
}
