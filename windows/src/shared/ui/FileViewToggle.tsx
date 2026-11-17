import { designIcon } from "@/shared/icons";
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

const ListIcon = designIcon("fileList"), TreeIcon = designIcon("fileTree");

/** The list/tree toggle every file list shares: the icon form of Segmented. macOS: FileViewToggle */
export function FileViewToggle({ view = ["fileViewMode", "list"] }: { view?: readonly [string, "list" | "tree"] }) {
  const mode = useFileViewMode(...view);
  return (
    <Segmented
      label={t("File list layout")}
      value={mode}
      onChange={(v) => settings.set(view[0], v)}
      options={[
        { value: "list", icon: true, label: <ListIcon size={13} />, name: t("Show as list") },
        { value: "tree", icon: true, label: <TreeIcon size={13} />, name: t("Show as folder tree") },
      ]}
    />
  );
}
