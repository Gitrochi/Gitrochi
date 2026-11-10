import { List, ListTree } from "lucide-react";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Segmented } from "./ui";

/** 변경 파일 보기 방식(목록/트리) — 작업 영역과 커밋 상세가 함께 쓴다 */
export function useFileViewMode(key = "fileViewMode", fallback: "list" | "tree" = "list"): "list" | "tree" {
  useObserve(settings);
  return settings.get<"list" | "tree">(key, fallback);
}

/** Requests and comparisons open as a tree (the Changed files board); the choice is apart from the repository's changes */
export const requestFileView = ["requestFileViewMode", "tree"] as const;

/** The list/tree toggle every file list shares. macOS: FileViewToggle */
export function FileViewToggle({ view = ["fileViewMode", "list"] }: { view?: readonly [string, "list" | "tree"] }) {
  const mode = useFileViewMode(...view);
  return (
    <Segmented
      value={mode}
      onChange={(v) => settings.set(view[0], v)}
      options={[
        { value: "list", label: <List size={14} />, tip: t("Show as list") },
        { value: "tree", label: <ListTree size={14} />, tip: t("Show as folder tree") },
      ]}
    />
  );
}
