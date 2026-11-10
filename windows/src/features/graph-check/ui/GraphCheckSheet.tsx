import { Info, OctagonX, TriangleAlert } from "lucide-react";
import { CircleCheck } from "@/shared/icons";
import { useState } from "react";
import type { GraphViolation } from "@/entities/gitch";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { Button, Card, Modal, Spinner } from "@/shared/ui";

/** 의존 규칙 검사(gitch graph check) 결과: 어긴 규칙과 그 연결 · 순환. 「View as graph」는 같은 검사를 html 로 그려 기본 브라우저로 연다 (맥 버전 GraphCheckSheet) */
export function GraphCheckSheet({ store, close }: { store: RepoStore; close: () => void }) {
  /** 그래프 페이지를 만들지 못한 까닭(gitch 문구) */
  const [pageError, setPageError] = useState<string | null>(null);
  const c = store.graphCheck;
  const done = c?.kind === "done" ? c : null;
  // 규칙이 하나도 없으면 gitch 가 빈 페이지를 만들어서 끈다
  const canShowGraph = !!done && done.rules > 0 && !store.graphJob;
  const finish = () => {
    // 검사가 돌고 있으면 두고 간다 — 바로 다시 열면 새로 돌리지 않고 그 결과를 기다린다(겹쳐 돌면 늦게 끝난 쪽이 덮는다)
    if (store.graphCheck?.kind !== "running") store.graphCheck = null;
    close();
  };
  return (
    <Modal
      title={t("Dependency rules")}
      width={640}
      onClose={finish}
      footer={
        <>
          <Button onClick={() => void store.openGraphRules()}>{t("Edit rules")}</Button>
          <Button
            disabled={!c || c.kind === "running"}
            onClick={() => {
              setPageError(null);
              void store.runGraphCheck();
            }}
          >
            {t("Check again")}
          </Button>
          <span className="spacer" />
          {store.graphJob?.kind === "checkPage" && <Spinner size={13} />}
          <Button
            disabled={!canShowGraph}
            onClick={() => {
              setPageError(null);
              void store.openGraphCheckPage().then(setPageError);
            }}
          >
            {t("View as graph")}
          </Button>
          <Button kind="primary" onClick={finish}>
            {t("Done")}
          </Button>
        </>
      }
    >
      <span className="hint">{done ? `${done.result.file} · ${t("Rules {0}", done.rules)}` : ".gitch/graph.rules"}</span>
      {!c || c.kind === "running" ? (
        <div className="row" style={{ justifyContent: "center", gap: 8, padding: 30 }}>
          <Spinner /> <span className="muted">{t("Checking dependency rules…")}</span>
        </div>
      ) : c.kind === "failed" ? (
        <Card gap={6}>
          <span className="row" style={{ gap: 6, color: "var(--red)", fontWeight: 600 }}>
            <OctagonX size={15} /> {t("Couldn't check the rules")}
          </span>
          <pre className="mono" style={{ margin: 0, whiteSpace: "pre-wrap", userSelect: "text" }}>
            {c.message}
          </pre>
        </Card>
      ) : c.rules === 0 ? (
        // --init 이 만든 예시는 모두 주석 — 위반 없음이 아니라 아직 검사할 규칙이 없다
        <Card>
          <span className="row" style={{ gap: 6 }}>
            <Info size={15} /> {t("No rules yet. Remove the # in front of the examples and adjust them to this repository, then check again.")}
          </span>
        </Card>
      ) : c.result.violations.length === 0 ? (
        <Card>
          <span className="row" style={{ gap: 6, color: "var(--green)", fontWeight: 600 }}>
            <CircleCheck size={15} /> {t("No violations")}
          </span>
        </Card>
      ) : (
        <Violations list={c.result.violations} />
      )}
      {pageError && (
        <span className="hint" style={{ color: "var(--red)", userSelect: "text" }}>
          {pageError}
        </span>
      )}
    </Modal>
  );
}

function Violations({ list }: { list: GraphViolation[] }) {
  // 위반(실패로 세는 것) 먼저, 같은 무게면 규칙 파일의 줄 순서로
  const weight = (v: GraphViolation) => (v.severity === "error" ? 0 : 1);
  const sorted = [...list].sort((a, b) => weight(a) - weight(b) || a.line - b.line);
  const errors = sorted.filter((v) => v.severity === "error").length;
  const warnings = sorted.length - errors;
  return (
    <div className="col" style={{ gap: 8 }}>
      <div className="row" style={{ gap: 14, fontWeight: 600 }}>
        {errors > 0 ? (
          <span className="row" style={{ gap: 6, color: "var(--red)" }}>
            <OctagonX size={15} /> {t("Violations {0}", errors)}
          </span>
        ) : (
          <span className="row" style={{ gap: 6, color: "var(--green)" }}>
            <CircleCheck size={15} /> {t("No violations")}
          </span>
        )}
        {warnings > 0 && (
          <span className="row" style={{ gap: 6, color: "var(--orange)" }}>
            <TriangleAlert size={15} /> {t("Warnings {0}", warnings)}
          </span>
        )}
      </div>
      <div className="col" style={{ gap: 4, maxHeight: 340, overflow: "auto" }}>
        {sorted.map((v, i) => (
          <div key={i} className="form-section" style={{ gap: 3, padding: 8 }}>
            <div className="row" style={{ gap: 8 }}>
              {v.severity === "error" ? <OctagonX size={14} style={{ color: "var(--red)", flex: "none" }} /> : <TriangleAlert size={14} style={{ color: "var(--orange)", flex: "none" }} />}
              {/* 규칙 파일에 쓴 줄 그대로(빈칸만 하나로) */}
              <span className="mono" style={{ fontWeight: 600 }}>
                {v.rule.split(/\s+/).join(" ")}
              </span>
              <span className="muted" style={{ fontSize: 11.5 }}>
                [{v.relation}] · {t("Line {0}", v.line)}
              </span>
            </div>
            <span className="mono muted" style={{ fontSize: 11.5, paddingLeft: 22, userSelect: "text", overflowWrap: "anywhere" }}>
              {v.nodes?.length ? v.nodes.join(" · ") : `${v.source ?? "?"} → ${v.target ?? "?"}`}
            </span>
          </div>
        ))}
      </div>
      {warnings > 0 && <span className="hint">{t("Warnings are links guessed only from names, so they don't count as violations.")}</span>}
    </div>
  );
}
