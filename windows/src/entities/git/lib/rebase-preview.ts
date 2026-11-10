import { t } from "@/shared/i18n";
import { git } from "@/shared/platform";
import { fullObjectID, validRevisionInput } from "./history-tools";
/** date: the commit time in seconds, when Git gave one */
export interface RebasePreview { base: string; head: string; incoming: number; replay: number; commits: { id: string; subject: string; date?: number }[] }

/** A branch or tag the current branch can be moved onto (the Rebase page's list). macOS: RebaseBase. */
export interface RebaseBase {
  name: string;
  kind: "branch" | "remote" | "tag";
  /** Commits it has that the current branch lacks; 0 means it is already in this branch, null that Git did not say */
  incoming: number | null;
}

/** One line per ref: its full name, then how far it is ahead of and behind HEAD (Git 2.41 and later) */
export const rebaseBaseArgs = ["for-each-ref", "--format=%(refname)%09%(ahead-behind:HEAD)", "refs/heads", "refs/remotes", "refs/tags"];

/** The current branch and the remotes' HEAD pointers are left out. The usual bases come first, then local branches, remote branches and tags. */
export function parseRebaseBases(output: string, current: string | null): RebaseBase[] {
  const found: RebaseBase[] = [];
  for (const line of output.split("\n")) {
    const at = line.indexOf("\t"), ref = at < 0 ? line : line.slice(0, at);
    const counts = at < 0 ? [] : line.slice(at + 1).trim().split(" ").map(Number);
    const incoming = counts.length === 2 && counts.every(Number.isSafeInteger) ? counts[0] : null;
    if (ref.startsWith("refs/heads/")) {
      const name = ref.slice("refs/heads/".length);
      if (name !== current) found.push({ name, kind: "branch", incoming });
    } else if (ref.startsWith("refs/remotes/")) {
      const name = ref.slice("refs/remotes/".length);
      if (!name.endsWith("/HEAD")) found.push({ name, kind: "remote", incoming });
    } else if (ref.startsWith("refs/tags/")) {
      found.push({ name: ref.slice("refs/tags/".length), kind: "tag", incoming });
    }
  }
  const usual = ["origin/main", "main", "origin/master", "master"];
  const rank = (base: RebaseBase) => {
    const index = base.kind === "tag" ? -1 : usual.indexOf(base.name);
    return index >= 0 ? index : usual.length + (base.kind === "branch" ? 0 : base.kind === "remote" ? 1 : 2);
  };
  return found.map((base, index) => ({ base, index })).sort((a, b) => rank(a.base) - rank(b.base) || a.index - b.index).map(({ base }) => base);
}

export const rebaseBaseMatches = (base: RebaseBase, search: string): boolean => !search.trim() || base.name.toLowerCase().includes(search.trim().toLowerCase());

export async function loadRebaseBases(repo: string, current: string | null, read: (args: string[], repo: string) => Promise<string> = async (args, cwd) => (await git(args, cwd)).stdout): Promise<RebaseBase[]> {
  return parseRebaseBases(await read(rebaseBaseArgs, repo), current);
}
export const defaultRebaseBase=(names:string[],current:string|null,upstream:string|null):string=>["origin/main","main","origin/master","master",upstream,...names].find((value):value is string=>!!value&&names.includes(value)&&value!==current)??upstream??names[0]??"main";
/** 미리보기는 이름을 고정 SHA로 바꾼 뒤 읽기 명령만 실행한다. */
export async function loadRebasePreview(repo:string,base:string,head:string,read:(args:string[],repo:string)=>Promise<string>=async(args,cwd)=>(await git(args,cwd)).stdout):Promise<RebasePreview>{
  if(!validRevisionInput(base)||!validRevisionInput(head))throw new Error(t("Choose a valid base branch to preview its commits."));
  const [onto,current]=await Promise.all([read(["rev-parse","--verify",base+"^{commit}"],repo),read(["rev-parse","--verify",head+"^{commit}"],repo)]);
  const target=onto.trim(),original=current.trim();if(!fullObjectID(target)||!fullObjectID(original))throw new Error(t("Choose a valid base branch to preview its commits."));
  const [counts,log]=await Promise.all([read(["rev-list","--left-right","--count",`${target}...${original}`],repo),read(["log","-n","12","--format=%H%x09%s%x09%ct",`${target}..${original}`,"--"],repo)]);
  const values=counts.trim().split(/\s+/).map(Number);if(values.length!==2||values.some(value=>!Number.isSafeInteger(value)||value<0))throw new Error(t("The branch summary could not be read. Refresh and try again."));
  // the commit time follows the subject; a subject may hold tabs of its own
  const commits=log.split("\n").flatMap(line=>{const at=line.indexOf("\t"),id=line.slice(0,at);if(at<=0||!fullObjectID(id))return[];const rest=line.slice(at+1),tab=rest.lastIndexOf("\t"),time=tab<0?"":rest.slice(tab+1);return /^\d+$/.test(time)?[{id,subject:rest.slice(0,tab),date:Number(time)}]:[{id,subject:rest}];});
  return{base:target,head:original,incoming:values[0],replay:values[1],commits};
}
