/**
 * Build shift change push notification content (CA default).
 */

export type ShiftPushEvent = "assigned" | "changed" | "cancelled";

export interface ShiftSlotPushContext {
  slot_id: string;
  tenant_id: string;
  employee_id: string;
  slot_date: string;
  start_time: string;
  end_time: string;
  status: string;
  shift_name: string;
}

function formatSlotDate(isoDate: string): string {
  const [y, m, d] = isoDate.split("-").map(Number);
  if (!y || !m || !d) return isoDate;
  return new Date(y, m - 1, d).toLocaleDateString("ca-ES", {
    weekday: "short",
    day: "numeric",
    month: "short",
  });
}

export function buildShiftPushNotification(
  event: ShiftPushEvent,
  ctx: ShiftSlotPushContext,
): { title: string; body: string; url: string; tag: string } {
  const dateLabel = formatSlotDate(ctx.slot_date);
  const timeLabel = `${ctx.start_time}–${ctx.end_time}`;
  const detail = `${ctx.shift_name} · ${dateLabel} ${timeLabel}`;

  switch (event) {
    case "assigned":
      return {
        title: "Nou torn assignat",
        body: detail,
        url: `/portal/shifts?date=${encodeURIComponent(ctx.slot_date)}`,
        tag: `shift-${ctx.slot_id}-assigned`,
      };
    case "changed":
      return {
        title: "El teu torn ha canviat",
        body: detail,
        url: `/portal/shifts?date=${encodeURIComponent(ctx.slot_date)}`,
        tag: `shift-${ctx.slot_id}-changed`,
      };
    case "cancelled":
      return {
        title: "Torn cancel·lat",
        body: detail,
        url: `/portal/shifts?date=${encodeURIComponent(ctx.slot_date)}`,
        tag: `shift-${ctx.slot_id}-cancelled`,
      };
    default:
      return {
        title: "Actualització d'horari",
        body: detail,
        url: `/portal/shifts?date=${encodeURIComponent(ctx.slot_date)}`,
        tag: `shift-${ctx.slot_id}`,
      };
  }
}
