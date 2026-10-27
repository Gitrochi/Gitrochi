const key = (context: string) => `gitrochi.project-portfolio-selection.v1:${context}`;

/** Stores project identifiers only; absence and an explicitly empty portfolio are distinct. */
export function readProjectPortfolioSelection(context: string): string[] | null {
  if (!context) return null;
  try {
    const value: unknown = JSON.parse(localStorage.getItem(key(context)) ?? "null");
    if (Array.isArray(value) && value.every((id): id is string => typeof id === "string" && !!id)) return [...new Set(value)];
  } catch {
    /* A damaged or unavailable preference must not hide the user's project catalog. */
  }
  return null;
}

export function saveProjectPortfolioSelection(context: string, ids: string[]): void {
  if (!context || ids.some((id) => !id)) return;
  try {
    localStorage.setItem(key(context), JSON.stringify([...new Set(ids)].sort()));
  } catch {
    /* Choosing projects still works in memory when storage is unavailable. */
  }
}
