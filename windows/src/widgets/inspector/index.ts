// widgets/inspector 의 공개 API — 다른 조각은 이 파일로만 가져온다
export { Inspector } from "./ui/Inspector";
export { IssueDetail } from "./ui/IssueDetail";
export { PullRequestDetailView, type PullRequestPageContext } from "./ui/PullRequestDetailView";
export { branchSummary, type BranchSummary, commentCount, isThisBranch, type RequestSort, reviewRequestedCount, sorted } from "./lib/pull-request-page";
