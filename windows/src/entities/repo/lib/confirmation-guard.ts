/** 같은 경로를 다시 연 경우에도 오래된 확인창이 다른 저장소 세션에서 실행되지 않게 한다. */
export class RepositoryConfirmationGuard {
  private generation = 0;
  invalidate() { ++this.generation; }
  wrap(path: string | null, currentPath: () => string | null, action: () => void | Promise<unknown>): () => Promise<void> {
    const expected = this.generation;
    let consumed = false;
    return async () => {
      if (this.generation !== expected || currentPath() !== path || consumed) return;
      consumed = true;
      await action();
    };
  }
}
