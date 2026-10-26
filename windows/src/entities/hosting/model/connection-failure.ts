import { t } from "@/shared/i18n";

type ConnectionStage = "missing-cli" | "credential-read" | "verification" | "identity-mismatch" | "credential-save";

/** 프로세스 출력·서버 본문·비밀 저장소 오류를 그대로 노출하지 않고 실패한 연결 단계를 보인다. */
export class AccountConnectionFailure extends Error {
  constructor(readonly stage: ConnectionStage, details: { status?: number; expectedLogin?: string } = {}) {
    super(AccountConnectionFailure.describe(stage, details));
  }

  private static describe(stage: ConnectionStage, details: { status?: number; expectedLogin?: string }) {
    switch (stage) {
      case "missing-cli": return t("Couldn't find the gh CLI.");
      case "credential-read": return t("Couldn't read the approved GitHub login from GitHub CLI. Retry connecting; if it still fails, sign in again.");
      case "verification":
        if (details.status === 401) return t("GitHub rejected the approved login (401). Sign in again.");
        if (details.status === 403) return t("GitHub didn't allow account verification (403). Check the login's permissions, then retry connecting.");
        if (Number.isInteger(details.status) && details.status! >= 100 && details.status! <= 599) return t("GitHub account verification failed (HTTP {0}). Retry connecting.", details.status!);
        return t("Couldn't verify the approved GitHub account. Check your connection, then retry connecting.");
      case "identity-mismatch":
        if (details.expectedLogin && /^[a-z\d](?:[a-z\d-]{0,38})$/i.test(details.expectedLogin)) return t("Sign in as {0} to connect this Git identity.", details.expectedLogin);
        return t("The signed-in GitHub account doesn't match this account. Sign in with the intended account.");
      case "credential-save": return t("Couldn't save the login in Windows Credential Manager. Unlock your credentials, then retry connecting.");
    }
  }
}

export function accountConnectionMessage(error: unknown) {
  return error instanceof AccountConnectionFailure ? error.message : t("Couldn't connect the approved GitHub account. Retry connecting before continuing.");
}
