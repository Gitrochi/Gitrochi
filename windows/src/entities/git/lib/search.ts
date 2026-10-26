/** 공백 위치와 대소문자에 관계없이 커밋을 찾는다. */
export class CommitSearchQuery {
  readonly key: string;
  readonly gitPattern: string;

  constructor(text: string) {
    const compact = text.replace(/\s/gu, "");
    this.key = compact.toLowerCase();
    // Git의 확장 정규식에서도 검색어의 특수문자는 문자 그대로 취급한다.
    this.gitPattern = Array.from(compact, (char) => char.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("[[:space:]]*");
  }

  matches(text: string): boolean {
    return text.replace(/\s/gu, "").toLowerCase().includes(this.key);
  }
}
