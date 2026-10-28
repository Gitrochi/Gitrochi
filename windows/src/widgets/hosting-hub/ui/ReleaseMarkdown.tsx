import type { RepoTarget } from "@/entities/git";
import { releaseMarkdownLinks } from "@/entities/hosting";
import { Markdown } from "@/shared/ui";

/** The preview and the saved notes share the same revision and URL policy. */
export function ReleaseMarkdown({ text, target, tag }: { text: string; target: RepoTarget | null; tag: string }) {
  return <Markdown text={text} {...releaseMarkdownLinks(target, tag)} className="release-markdown" />;
}
