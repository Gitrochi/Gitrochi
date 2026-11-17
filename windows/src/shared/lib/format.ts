import { language, t } from "@/shared/i18n";
/** 실행마다 바뀌지 않는 문자열 해시(색 고정용) */
export function stableHash(s: string) {
  let h = 5381;
  for (const ch of s) h = ((h * 33) + (ch.codePointAt(0) ?? 0)) & 0x7fffffff;
  return h;
}

let fmts: { lang: string; relative: Intl.RelativeTimeFormat; day: Intl.DateTimeFormat; long: Intl.DateTimeFormat } | null = null;
/** 화면 언어에 맞춘 날짜 형식(언어는 시작할 때 정해지므로 처음 쓸 때 만든다) */
function formats() {
  if (fmts?.lang !== language) {
    const loc = language;
    fmts = {
      lang: loc,
      relative: new Intl.RelativeTimeFormat(loc, { numeric: "auto", style: "short" }),
      day: new Intl.DateTimeFormat(loc, { year: "numeric", month: "2-digit", day: "2-digit" }),
      long: new Intl.DateTimeFormat(loc, { dateStyle: "long", timeStyle: "short" }),
    };
  }
  return fmts;
}

/** 일주일 이내는 "3시간 전", 그보다 오래면 날짜 */
export function shortDate(sec: number) {
  const diff = Date.now() / 1000 - sec;
  const f = formats();
  if (diff < 7 * 86400) {
    if (diff < 60) return t("Just now");
    if (diff < 3600) return f.relative.format(-Math.floor(diff / 60), "minute");
    if (diff < 86400) return f.relative.format(-Math.floor(diff / 3600), "hour");
    return f.relative.format(-Math.floor(diff / 86400), "day");
  }
  return f.day.format(new Date(sec * 1000));
}

export function longDate(sec: number) {
  return formats().long.format(new Date(sec * 1000));
}

export const trimmed = (s: string) => s.trim();

/** 브랜치 이름으로 쓸 수 있는지 대략 확인 */
export function validBranchName(n: string) {
  const s = n.trim();
  return !!s && !/\s/.test(s) && !s.startsWith("-") && !s.includes("..") && !/[~^:?*[\\]/.test(s) && !s.endsWith("/") && !s.endsWith(".lock");
}
