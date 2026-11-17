interface HorizontalBounds {
  left: number;
  right: number;
}

/**
 * The commit inspector's one-line author: the avatar at the column's left, the name after the gap, and the time
 * whole after the name and inside the column, whatever the scrollbar gutter takes.
 */
export function authorLineFits(content: HorizontalBounds, avatar: HorizontalBounds, name: HorizontalBounds, when: HorizontalBounds, gap: number): boolean {
  return [content.left, content.right, avatar.left, avatar.right, name.left, name.right, when.left, when.right, gap].every(Number.isFinite)
    && gap >= 0 && Math.abs(avatar.left - content.left) <= 1 && avatar.right > avatar.left
    && Math.abs(name.left - (avatar.right + gap)) <= 1 && name.right > name.left
    && when.left >= name.right + gap - 1 && when.right > when.left && when.right <= content.right + 1;
}
