interface HorizontalBounds {
  left: number;
  right: number;
}

/** Check the remaining author column inside its card, independently of scrollbar gutters. */
export function authorFillsIdentityColumn(content: HorizontalBounds, avatar: HorizontalBounds, author: HorizontalBounds, gap: number): boolean {
  const left = avatar.right + gap, right = content.right;
  return [content.left, right, avatar.left, avatar.right, author.left, author.right, gap].every(Number.isFinite)
    && gap >= 0 && Math.abs(avatar.left - content.left) <= 1 && avatar.right > avatar.left && right > left
    && Math.abs(author.left - left) <= 1 && Math.abs(author.right - right) <= 1;
}
