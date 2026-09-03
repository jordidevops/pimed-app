export function formatPortalPeriodRange(
  periodFrom: string,
  periodTo: string,
  locale: string,
): string {
  if (!periodFrom || !periodTo) return "—";
  const start = new Date(`${periodFrom}T12:00:00`);
  const end = new Date(`${periodTo}T12:00:00`);
  const sameMonth =
    start.getMonth() === end.getMonth() && start.getFullYear() === end.getFullYear();

  if (sameMonth) {
    return `${start.toLocaleDateString(locale, { day: "numeric" })} – ${end.toLocaleDateString(locale, {
      day: "numeric",
      month: "long",
      year: "numeric",
    })}`;
  }

  return `${start.toLocaleDateString(locale, {
    day: "numeric",
    month: "short",
  })} – ${end.toLocaleDateString(locale, {
    day: "numeric",
    month: "short",
    year: "numeric",
  })}`;
}

export function periodRangeFromMetadata(
  metadata: Record<string, unknown> | null | undefined,
): { from: string; to: string } | null {
  if (!metadata) return null;
  const from = metadata.period_from;
  const to = metadata.period_to;
  if (typeof from === "string" && typeof to === "string" && from && to) {
    return { from, to };
  }
  return null;
}
