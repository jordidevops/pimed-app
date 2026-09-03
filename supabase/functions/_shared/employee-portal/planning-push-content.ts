/**
 * Build planning push notification content (openings / claims / swaps).
 * EX-07.6 — no PII beyond schedule labels.
 */

export type PlanningPushEvent =
  | "opening_published"
  | "opening_urgent"
  | "claim_accepted"
  | "claim_rejected"
  | "claim_expired"
  | "swap_requested"
  | "swap_approved"
  | "swap_rejected";

export interface PlanningPushPayload {
  entity_type?: string;
  entity_id?: string;
  site_id?: string;
  opening_id?: string;
  opening_date?: string;
  slot_date?: string;
  start_time?: string;
  end_time?: string;
  title?: string | null;
  kind?: string;
  is_urgent?: boolean;
  escalated?: boolean;
}

function formatDate(isoDate: string | undefined): string {
  if (!isoDate) return "";
  const [y, m, d] = isoDate.split("-").map(Number);
  if (!y || !m || !d) return isoDate;
  return new Date(y, m - 1, d).toLocaleDateString("ca-ES", {
    weekday: "short",
    day: "numeric",
    month: "short",
  });
}

function timeRange(payload: PlanningPushPayload): string {
  const start = payload.start_time ?? "";
  const end = payload.end_time ?? "";
  if (!start || !end) return "";
  return `${start}–${end}`;
}

function scheduleLabel(payload: PlanningPushPayload): string {
  const date = formatDate(payload.opening_date ?? payload.slot_date);
  const times = timeRange(payload);
  const title = payload.title?.trim();
  return [title, date, times].filter(Boolean).join(" · ");
}

export function buildPlanningPushNotification(
  event: PlanningPushEvent,
  payload: PlanningPushPayload,
): { title: string; body: string; url: string; tag: string } {
  const detail = scheduleLabel(payload) || "Consulta el portal";
  const entityId = payload.entity_id ?? payload.opening_id ?? "x";

  switch (event) {
    case "opening_published":
      return {
        title: "Nova vacant disponible",
        body: detail,
        url: "/portal/openings",
        tag: `opening-${entityId}-published`,
      };
    case "opening_urgent":
      return {
        title: payload.escalated ? "Vacant urgent: cal cobrir" : "Vacant urgent",
        body: detail,
        url: "/portal/openings",
        tag: `opening-${entityId}-urgent`,
      };
    case "claim_accepted":
      return {
        title: "Candidatura acceptada",
        body: detail,
        url: "/portal/shifts",
        tag: `claim-${entityId}-accepted`,
      };
    case "claim_rejected":
      return {
        title: "Candidatura no acceptada",
        body: detail,
        url: "/portal/openings",
        tag: `claim-${entityId}-rejected`,
      };
    case "claim_expired":
      return {
        title: "Candidatura expirada",
        body: detail,
        url: "/portal/openings",
        tag: `claim-${entityId}-expired`,
      };
    case "swap_requested":
      return {
        title: payload.kind === "give_away" ? "Cessió de torn disponible" : "Petició d'intercanvi",
        body: detail,
        url: "/portal/swaps",
        tag: `swap-${entityId}-requested`,
      };
    case "swap_approved":
      return {
        title: "Canvi de torn aprovat",
        body: detail,
        url: "/portal/swaps",
        tag: `swap-${entityId}-approved`,
      };
    case "swap_rejected":
      return {
        title: "Canvi de torn rebutjat",
        body: detail,
        url: "/portal/swaps",
        tag: `swap-${entityId}-rejected`,
      };
    default:
      return {
        title: "Actualització de planificació",
        body: detail,
        url: "/portal/shifts",
        tag: `planning-${entityId}`,
      };
  }
}
