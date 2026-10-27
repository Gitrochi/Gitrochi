interface CreationRecovery {
  projectID?: string;
  at: string;
}
const memory = new Map<string, CreationRecovery>();
const storageKey = (key: string) =>
  `gitrochi.project-create-recovery.v1:${key}`;
/** Only non-secret project/account identifiers survive closing an uncertain creation. */
export function readCreationRecovery(
  key: string,
): CreationRecovery | undefined {
  if (!key) return undefined;
  try {
    const value = JSON.parse(localStorage.getItem(storageKey(key)) ?? "null");
    if (value && typeof value.at === "string") return value;
  } catch {
    /* Memory remains authoritative if storage is unavailable. */
  }
  return memory.get(key);
}
export function saveCreationRecovery(key: string, projectID?: string): void {
  if (!key) return;
  const value = { at: new Date().toISOString(), projectID };
  memory.set(key, value);
  try {
    localStorage.setItem(storageKey(key), JSON.stringify(value));
  } catch {
    /* Keep the in-session lock. */
  }
}
export function clearCreationRecovery(key: string): void {
  memory.delete(key);
  try {
    localStorage.removeItem(storageKey(key));
  } catch {
    /* A surviving durable record stays conservative. */
  }
}
