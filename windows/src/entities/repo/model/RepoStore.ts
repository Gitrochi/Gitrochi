import type { AgentHost } from "@/entities/agent";
import { CIStore } from "@/entities/ci";
import { HostingHubStore } from "@/entities/hosting";
import { RepoAssistant } from "./layers/repository-assistant";

/**
 * 열린 저장소 하나(=탭 하나)의 상태와 모든 git 작업. 화면은 이 객체만 바라본다. (맥 버전 RepoStore)
 * 기능별로 layers/ 아래 파일에 나눠 두고 차례로 이어 붙인다:
 * core → selection → search → filters → actions → undo → drop → worktrees → hosting → ai → terminal → gitch
 */
export class RepoStore extends RepoAssistant implements AgentHost {
  /** Home can open the exact project task before the project panel mounts. */
  readonly hostingHub: HostingHubStore = new HostingHubStore(this);
  /** CI/CD 패널(파이프라인·Actions) */
  readonly ci: CIStore = new CIStore(this);
}
