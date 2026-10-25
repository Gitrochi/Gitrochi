import { t } from "@/shared/i18n";

/** CLI의 변경 코드와 유사도 점수를 파일 목록과 같은 사용자용 문구로 보여 준다. */
export function reviewChangeStatusLabel(status: string): string {
  const code = status.match(/^([ACDMRTU])(?:\d{1,3})?$/)?.[1];
  const labels: Record<string, string> = { A: "Added", C: "Copied", D: "Deleted", M: "Modified", R: "Renamed", T: "Type changed", U: "Conflict" };
  return t(code ? labels[code] : "Unknown");
}
