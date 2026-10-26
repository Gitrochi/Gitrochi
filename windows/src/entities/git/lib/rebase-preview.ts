import { t } from "@/shared/i18n";
import { git } from "@/shared/platform";
import { fullObjectID, validRevisionInput } from "./history-tools";
export interface RebasePreview { base: string; head: string; incoming: number; replay: number; commits: { id: string; subject: string }[] }
export const defaultRebaseBase=(names:string[],current:string|null,upstream:string|null):string=>["origin/main","main","origin/master","master",upstream,...names].find((value):value is string=>!!value&&names.includes(value)&&value!==current)??upstream??names[0]??"main";
/** 미리보기는 이름을 고정 SHA로 바꾼 뒤 읽기 명령만 실행한다. */
export async function loadRebasePreview(repo:string,base:string,head:string,read:(args:string[],repo:string)=>Promise<string>=async(args,cwd)=>(await git(args,cwd)).stdout):Promise<RebasePreview>{
  if(!validRevisionInput(base)||!validRevisionInput(head))throw new Error(t("Choose a valid base branch to preview its commits."));
  const [onto,current]=await Promise.all([read(["rev-parse","--verify",base+"^{commit}"],repo),read(["rev-parse","--verify",head+"^{commit}"],repo)]);
  const target=onto.trim(),original=current.trim();if(!fullObjectID(target)||!fullObjectID(original))throw new Error(t("Choose a valid base branch to preview its commits."));
  const [counts,log]=await Promise.all([read(["rev-list","--left-right","--count",`${target}...${original}`],repo),read(["log","-n","12","--format=%H%x09%s",`${target}..${original}`,"--"],repo)]);
  const values=counts.trim().split(/\s+/).map(Number);if(values.length!==2||values.some(value=>!Number.isSafeInteger(value)||value<0))throw new Error(t("The branch summary could not be read. Refresh and try again."));
  const commits=log.split("\n").flatMap(line=>{const at=line.indexOf("\t"),id=line.slice(0,at);return at>0&&fullObjectID(id)?[{id,subject:line.slice(at+1)}]:[];});
  return{base:target,head:original,incoming:values[0],replay:values[1],commits};
}
