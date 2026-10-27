/**
 * 화면 언어. 한국어 글자를 그대로 키로 쓰고(t("커밋")), 고른 언어에 번역이 없으면 한국어 그대로 보인다.
 * {0}·{1} 은 차례로 넘긴 값. 언어는 앱을 그리기 전에 한 번 정한다(바꾸면 창을 다시 불러온다). (맥 버전은 Localizable.strings)
 */

export interface Language {
  code: string;
  /** 그 언어로 쓴 이름 */
  name: string;
}

export const languages: Language[] = [
  { code: "id", name: "Bahasa Indonesia" },
  { code: "cs", name: "Čeština" },
  { code: "de", name: "Deutsch" },
  { code: "en", name: "English" },
  { code: "es", name: "Español" },
  { code: "fr", name: "Français" },
  { code: "it", name: "Italiano" },
  { code: "hu", name: "Magyar" },
  { code: "nl", name: "Nederlands" },
  { code: "pl", name: "Polski" },
  { code: "pt-BR", name: "Português (Brasil)" },
  { code: "tr", name: "Türkçe" },
  { code: "ru", name: "Русский" },
  { code: "uk", name: "Українська" },
  { code: "th", name: "ภาษาไทย" },
  { code: "vi", name: "Tiếng Việt" },
  { code: "ja", name: "日本語" },
  { code: "ko", name: "한국어" },
  { code: "zh-Hans", name: "简体中文" },
  { code: "zh-Hant", name: "正體中文" },
];

/** AI 에게 쓰라고 할 언어 이름(영어) */
const englishNames: Record<string, string> = {
  id: "Indonesian", cs: "Czech", de: "German", en: "English", es: "Spanish", fr: "French", it: "Italian", hu: "Hungarian",
  nl: "Dutch", pl: "Polish", "pt-BR": "Brazilian Portuguese", tr: "Turkish", ru: "Russian", uk: "Ukrainian", th: "Thai",
  vi: "Vietnamese", ja: "Japanese", ko: "Korean", "zh-Hans": "Simplified Chinese", "zh-Hant": "Traditional Chinese",
};

let table: Record<string, string> = {};
/** 지금 화면 언어 코드 */
export let language = "ko";

export function t(key: string, ...args: Array<string | number | null | undefined>): string {
  const s = table[key] || key;
  return args.length ? s.replace(/\{(\d+)\}/g, (m, i) => (Number(i) < args.length ? String(args[Number(i)] ?? "") : m)) : s;
}

/** 시스템 언어 목록에서 지원하는 첫 언어(없으면 영어) */
export function systemLanguage(prefs: readonly string[] = typeof navigator === "undefined" ? [] : navigator.languages ?? [navigator.language]): string {
  for (const l of prefs) {
    const low = l.toLowerCase();
    if (low.startsWith("zh")) return /hant|-tw|-hk|-mo/.test(low) ? "zh-Hant" : "zh-Hans";
    if (low.startsWith("pt")) return "pt-BR";
    const hit = languages.find((x) => x.code.toLowerCase() === low.split("-")[0]);
    if (hit) return hit.code;
  }
  return "en";
}

const tables = import.meta.glob<{ default: Record<string, string> }>("./locales/*.json");

/** 기본 화면 언어(설정에서 바꾸기 전) */
export const defaultLanguage = "en";

/** choice: 설정에서 고른 언어(비어 있으면 영어, "system" 이면 시스템 언어를 따른다) */
export async function loadLanguage(choice: string | null | undefined) {
  language = choice === "system" ? systemLanguage() : choice && languages.some((l) => l.code === choice) ? choice : defaultLanguage;
  const load = tables[`./locales/${language}.json`];
  // 영어는 원문이라 번역표가 없다(한국어도 다른 언어처럼 번역표를 읽는다)
  table = load ? (await load()).default : {};
  if (typeof document !== "undefined") document.documentElement.lang = language;
}

/** 화면 언어의 영어 이름(AI 가 글을 쓸 언어) */
export const languageInEnglish = () => englishNames[language] ?? "English";

/** 백엔드(Rust)가 영어로 돌려주는 메시지를 화면 언어로 */
const native: Array<[RegExp, string]> = [
  [/^Request timed out: (.*)$/s, "Request timed out: {0}"],
  [/^Couldn't connect to the server: (.*)$/s, "Couldn't connect to the server: {0}"],
  [/^Folder not found: (.*)$/s, "Folder not found: {0}"],
  [/^Couldn't run (.+?): (.*)$/s, "Couldn't run {0}: {1}"],
  [/^(Only web addresses can be opened|Couldn't find PowerShell|No update was found\. Check again\.|No update was found|The terminal is already closed|The app's window was not found\.|Windows did not bring the app to the front\.|Bringing another app forward is only available on Windows\.)$/, "{0}"],
];

/** 백엔드 오류: 번역한 메시지와 원래 영어(native)를 함께 */
export class NativeError extends Error {
  constructor(
    message: string,
    readonly native: string,
  ) {
    super(message);
  }
}

export function nativeError(e: unknown): unknown {
  if (typeof e !== "string") return e;
  for (const [re, key] of native) {
    const m = e.match(re);
    if (m) return new NativeError(key === "{0}" ? t(m[1]) : t(key, ...m.slice(1)), e);
  }
  return e;
}

/** 프로세스 출력 끝에 붙는 시간 초과 안내 */
export function nativeText(s: string) {
  return s.replace(/\n(.+) didn't finish within (\d+)s and was stopped\./, (_, name: string, secs: string) => "\n" + t("{0} didn't finish within {1}s and was stopped.", name, secs));
}
