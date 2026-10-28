import { lazy, Suspense } from "react";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { Button, Modal, Spinner } from "@/shared/ui";

const SheetHost = lazy(() => import("./SheetHost").then(module => ({ default: module.SheetHost })));

/** 탭 위에 뜨는 대화상자: 시트, 오류, 확인, 저장소 안내 */
export function DialogHost({ store }: { store: RepoStore }) {
  const close = (f: () => void) => () => {
    f();
    store.changed();
  };
  return (
    <>
      {store.sheet && <Suspense fallback={<Modal title={t("Loading…")} onClose={close(() => { store.sheet = null; })}><Spinner /></Modal>}><SheetHost store={store} /></Suspense>}
      {store.errorMessage && (
        <Modal
          title={t("Couldn't complete the operation")}
          width={520}
          onClose={close(() => (store.errorMessage = null))}
          footer={
            <Button kind="primary" autoFocus onClick={close(() => (store.errorMessage = null))}>
              {t("OK")}</Button>
          }
        >
          <div className="modal-message selectable">{store.errorMessage}</div>
        </Modal>
      )}
      {store.notRepoPrompt && (
        <Modal
          title={t("Not a Git repository")}
          onClose={close(() => (store.notRepoPrompt = null))}
          footer={
            <>
              <Button onClick={close(() => (store.notRepoPrompt = null))}>{t("Cancel")}</Button>
              <Button
                kind="primary"
                onClick={() => {
                  const p = store.notRepoPrompt!;
                  store.notRepoPrompt = null;
                  store.changed();
                  void store.initRepository(p);
                }}
              >
                {t("Create repository here")}</Button>
            </>
          }
        >
          <div className="modal-message">{t("Create a new Git repository in {0}?", store.notRepoPrompt)}</div>
        </Modal>
      )}
      {store.unsafePrompt && (
        <Modal
          title={t("git blocked this repository")}
          width={560}
          onClose={close(() => (store.unsafePrompt = null))}
          footer={
            <>
              <Button onClick={close(() => (store.unsafePrompt = null))}>{t("Cancel")}</Button>
              <Button kind="primary" onClick={() => void store.trustRepository()}>
                {t("Mark the repository as safe and open it")}</Button>
            </>
          }
        >
          <div className="modal-message">
            {t("The repository folder is owned by a different user (a repository in WSL, an external disk, etc.), so git didn't open it for safety. If you know this repository, mark it as safe.")}</div>
          <div className="mono selectable" style={{ fontSize: 11.5, wordBreak: "break-all" }}>
            git config --global --add safe.directory '{store.unsafePrompt.safePath}'
          </div>
        </Modal>
      )}
      {store.confirm && (
        <Modal
          title={store.confirm.title}
          onClose={close(() => (store.confirm = null))}
          footer={
            <>
              <Button onClick={close(() => (store.confirm = null))}>{t("Cancel")}</Button>
              <Button
                kind={store.confirm.destructive === false ? "primary" : "danger"}
                autoFocus
                onClick={() => {
                  const c = store.confirm!;
                  store.confirm = null;
                  store.changed();
                  void c.action();
                }}
              >
                {store.confirm.actionTitle}
              </Button>
            </>
          }
        >
          <div className="modal-message">{store.confirm.message}</div>
        </Modal>
      )}
      {store.dropRequest && (
        <Modal
          title={store.dropRequest.title}
          width={480}
          onClose={close(() => (store.dropRequest = null))}
          footer={<Button onClick={close(() => (store.dropRequest = null))}>{store.dropRequest.choices.length ? t("Cancel") : t("OK")}</Button>}
        >
          <div className="modal-message">{store.dropRequest.message}</div>
          {store.dropRequest.choices.map((c, i) => (
            <Button
              key={i}
              kind={i === 0 ? "primary" : "default"}
              block
              size="large"
              style={{ justifyContent: "flex-start", whiteSpace: "normal", height: "auto", minHeight: 34, textAlign: "left" }}
              onClick={() => {
                store.dropRequest = null;
                store.changed();
                void c.action();
              }}
            >
              {c.title}
            </Button>
          ))}
        </Modal>
      )}
    </>
  );
}
