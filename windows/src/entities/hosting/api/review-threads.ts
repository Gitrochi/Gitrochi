import type { ReviewAccess } from "./review";
import * as Hosting from "./hosting";
import { t } from "@/shared/i18n";
const graphURL = (base: string) => base.replace(/\/api\/v3\/?$/, "/api") + "/graphql";
interface Thread { id: string; isResolved: boolean; viewerCanResolve: boolean; viewerCanUnresolve?: boolean; comments: { nodes: { databaseId: number }[] } }
interface GraphResult { data?: { repository?: { pullRequest?: { reviewThreads: { nodes: Thread[]; pageInfo: { hasNextPage: boolean; endCursor: string | null } } } } }; errors?: { message: string }[] }
export async function githubReviewThreads(c: ReviewAccess, number: number): Promise<Map<number, Thread>> {
  const [owner, name] = c.target.path.split("/");
  const result = new Map<number, Thread>(); let after: string | null = null;
  for (let page = 0; page < 100; page++) {
    const response: GraphResult = await Hosting.send<GraphResult>("github", graphURL(c.apiBase), c.token, "POST", {
      query: "query($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$after){nodes{id isResolved viewerCanResolve viewerCanUnresolve comments(first:1){nodes{databaseId}}} pageInfo{hasNextPage endCursor}}}}}", variables: { owner, name, number, after },
    });
    if (response.errors?.length) throw new Error(response.errors.map((e) => e.message).join("\n"));
    const threads = response.data?.repository?.pullRequest?.reviewThreads;
    if (!threads) throw new Error(t("The server does not expose GitHub review threads. Use the browser for resolution."));
    for (const thread of threads.nodes) for (const comment of thread.comments.nodes) result.set(comment.databaseId, thread);
    if (!threads.pageInfo.hasNextPage) return result;
    if (!threads.pageInfo.endCursor || threads.pageInfo.endCursor === after) break;
    after = threads.pageInfo.endCursor;
  }
  throw new Error(t("The thread list is too large. Use the browser for resolution."));
}
export async function resolveGithubThread(c: ReviewAccess, threadID: string, resolved: boolean) {
  if (!threadID || /^\d+$/.test(threadID)) throw new Error(t("Refresh the conversation before resolving this thread."));
  const operation = resolved ? "resolveReviewThread" : "unresolveReviewThread";
  const result = await Hosting.send<{ errors?: { message: string }[]; data?: Record<string, { thread?: { id: string; isResolved: boolean } }> }>("github", graphURL(c.apiBase), c.token, "POST", { query: `mutation($id:ID!){${operation}(input:{threadId:$id}){thread{id isResolved}}}`, variables: { id: threadID } });
  if (result.errors?.length) throw new Error(result.errors.map((e) => e.message).join("\n"));
  if (result.data?.[operation]?.thread?.isResolved !== resolved) throw new Error(t("The server did not change the thread state. Refresh and try again."));
}
