import { Circle, CircleCheck, CircleDashed, CirclePause, CircleSlash, CircleX, Hand, SkipForward } from "lucide-react";
import { Clock, RefreshCw } from "@/shared/icons";
import type { ReactNode } from "react";
import { Spinner } from "@/shared/ui";
import { type CIStatus, statusInfo } from "../model/types";

/** 파이프라인·작업 상태 아이콘(실행 중이면 도는 표시) — 그래프·PR 목록에서도 쓴다 */
export function CIStatusIcon({ status, size = 14, plain = false }: { status: CIStatus; size?: number; /** Inside a status badge: the badge's colour and no tip of its own */ plain?: boolean }) {
  const info = statusInfo[status];
  let icon: ReactNode;
  switch (status) {
    case "running":
      if (plain) return <RefreshCw size={size} />;
      return (
        <span data-tip={info.title} style={{ display: "inline-flex", width: size, justifyContent: "center", flex: "none" }}>
          <Spinner size={size - 2} />
        </span>
      );
    case "success":
      icon = <CircleCheck size={size} />;
      break;
    case "failed":
      icon = <CircleX size={size} />;
      break;
    case "canceled":
      icon = <CircleSlash size={size} />;
      break;
    case "skipped":
      icon = <SkipForward size={size} />;
      break;
    case "manual":
      icon = <Hand size={size} />;
      break;
    case "waiting":
      icon = <CirclePause size={size} />;
      break;
    case "scheduled":
      icon = <Clock size={size} />;
      break;
    case "created":
    case "pending":
      icon = <CircleDashed size={size} />;
      break;
    default:
      icon = <Circle size={size} />;
  }
  if (plain) return <>{icon}</>;
  return (
    <span data-tip={info.title} style={{ color: info.color, display: "inline-flex", flex: "none" }}>
      {icon}
    </span>
  );
}
