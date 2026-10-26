import { t } from "@/shared/i18n";

/** Push 검토에 필요한 설정·커밋·도착지를 묶는다. 확인한 SHA 와 refspec 만 실제 push 에 사용한다. */
export interface PushReviewPlan {
  repo: string;
  branch: string;
  sourceOID: string;
  remote: string;
  destination: string;
  pushURL: string;
  displayURL: string;
  destinationOID: string | null;
  force: boolean;
  setUpstream: boolean;
  stamp: string;
  author: string;
  account: string;
  credentialAccount: string;
  preflight: { result: string; checks: { level: string; code: string; message: string }[] };
  commits: { sha: string; subject: string; author: string; email: string }[];
  commitCount: number;
  files: string[];
  fileCount: number;
  fileScope: "changes" | "snapshot";
  comparisonBase: string | null;
}

export type PushConfig = Record<string, string[]>;

/** NUL 형식 config 를 읽어 같은 키의 여러 값도 보존한다. */
export function parsePushConfig(output: string): PushConfig {
  const out: PushConfig = {};
  for (const entry of output.split("\0")) {
    const at = entry.indexOf("\n");
    if (at < 0) continue;
    const key = entry.slice(0, at);
    (out[key] ??= []).push(entry.slice(at + 1));
  }
  return out;
}

/** URL 에 들어 있는 암호·토큰을 화면에 표시하지 않는다. */
export function displayPushURL(value: string): string {
  return value.replace(/((?:https?|ssh|git|ftp):\/\/)[^/@]+@/gi, "$1[redacted]@").replace(/([?&](?:token|access_token|private_token|oauth_token|api_key|password)=)[^&\s]*/gi, "$1[redacted]");
}

/** 복수 목적지나 암묵적인 강제 push 를 단일 브랜치 검토로 잘못 표현하지 않는다. */
export function resolvePushDestination(config: PushConfig, remotes: string[], branch: string, currentBranch: string | null, remoteOverride?: string): { remote: string; destination: string; setUpstream: boolean } {
  const value = (key: string) => config[key]?.at(-1) ?? "";
  const remote = remoteOverride || value(`branch.${branch}.pushremote`) || value("remote.pushdefault") || value(`branch.${branch}.remote`) || (remotes.includes("origin") ? "origin" : remotes.length === 1 ? remotes[0] : "");
  if (!remote || !remotes.includes(remote)) throw new Error(t("The push remote is missing or ambiguous. Configure a named remote first."));
  if (["true", "yes", "on", "1"].includes(value(`remote.${remote}.mirror`).toLowerCase())) throw new Error(t("Mirror pushes cannot be reviewed as a single branch. Disable remote mirror mode first."));
  const upstreamRemote = value(`branch.${branch}.remote`);
  const upstream = value(`branch.${branch}.merge`);
  let destination = `refs/heads/${branch}`;
  if (!remoteOverride) {
    const specs = config[`remote.${remote}.push`] ?? [];
    if (specs.length) {
      if (specs.length !== 1 || /[*+^]/.test(specs[0])) throw new Error(t("Multiple, wildcard or forced push refspecs cannot be reviewed as a single branch. Configure one explicit branch refspec."));
      const parts = specs[0].split(":");
      const source = parts[0];
      if (![branch, `refs/heads/${branch}`, ...(currentBranch === branch ? ["HEAD"] : [])].includes(source) || parts.length > 2) throw new Error(t("The configured push refspec does not select this branch. Configure one explicit branch refspec."));
      destination = parts.length === 2 ? parts[1] : `refs/heads/${branch}`;
      if (!destination.startsWith("refs/")) destination = `refs/heads/${destination}`;
    } else {
      const mode = value("push.default") || "simple";
      if (["nothing", "matching"].includes(mode)) throw new Error(t("This push.default mode does not select a single branch. Use current, simple or upstream."));
      if (["upstream", "tracking"].includes(mode)) {
        if (upstreamRemote !== remote || !upstream) throw new Error(t("The upstream push destination is missing or belongs to a different remote."));
        destination = upstream;
      } else if (mode === "simple") {
        if (upstreamRemote === remote && upstream && upstream !== destination) throw new Error(t("The upstream branch has a different name. Select an explicit push refspec or use push.default=upstream."));
      } else if (mode !== "current") throw new Error(t("The push.default mode is unsupported. Select an explicit branch refspec."));
    }
  }
  if (!destination.startsWith("refs/heads/") || destination === "refs/heads/" || /[\s~^:?*[\\]/.test(destination) || destination.includes("//") || destination.includes("..") || destination.includes("@{") || destination.endsWith("/") || destination.endsWith(".") || destination.split("/").some((p) => p.startsWith(".") || p.endsWith(".lock"))) throw new Error(t("The push destination is not a valid branch ref."));
  return { remote, destination, setUpstream: !upstreamRemote || !upstream };
}

/** 목적지·인증·히스토리에 관련된 설정만 정렬해 재확인 때 비교한다. */
export function pushConfigStamp(config: PushConfig): string {
  return JSON.stringify(Object.entries(config).filter(([key]) => /^(branch\.|remote\.|push\.|url\.|user\.|gitsw\.|core\.sshcommand|credential\.)/.test(key)).sort(([a], [b]) => a.localeCompare(b)));
}

/** 원본 SHA 를 고정하고 설정에 포함된 암묵적인 태그·서브모듈 push 를 막는다. */
export function reviewedPushArguments(plan: PushReviewPlan): string[] {
  return ["push", "--porcelain", "--no-follow-tags", "--recurse-submodules=no", ...(plan.force ? [`--force-with-lease=${plan.destination}:${plan.destinationOID ?? ""}`] : []), plan.remote, `${plan.sourceOID}:${plan.destination}`];
}
