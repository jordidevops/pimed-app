/** Zona horària del tenant demo / majoria clients PiMed (evita desfases SSR UTC vs navegador). */
export const PORTAL_TIME_ZONE = "Europe/Madrid";

/** ISO date (YYYY-MM-DD) a la zona horària del portal. */
export function getPortalTodayIso(timeZone = PORTAL_TIME_ZONE): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}

export function getPortalCalendarAnchor(timeZone = PORTAL_TIME_ZONE): {
  year: number;
  month: number;
  todayIso: string;
} {
  const todayIso = getPortalTodayIso(timeZone);
  const [year, month] = todayIso.split("-").map(Number);
  return { year, month: month - 1, todayIso };
}
