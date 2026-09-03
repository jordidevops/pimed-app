import type { PortalPunchLike, PortalPunchType } from "./punchTypes";

export type { PortalPunchType } from "./punchTypes";

export type PortalPunchDayState = "off" | "day" | "work" | "break" | "travel";

export type PortalPunchStatus =
  | "outside"
  | "on_day"
  | "working"
  | "on_pause"
  | "traveling"
  | "unknown";

export function isMobileWorkProfile(profile: string | null | undefined): boolean {
  return (
    profile === "mobile_peripatetic" ||
    profile === "hybrid" ||
    profile === "delivery"
  );
}

export function isLegacyInOutOnly(
  profile: string | null | undefined,
  legacyInOutOnly?: boolean | null,
): boolean {
  if (!isMobileWorkProfile(profile)) return true;
  return Boolean(legacyInOutOnly);
}

export function punchDayStateAfter(
  state: PortalPunchDayState,
  punchType: string,
): PortalPunchDayState | null {
  switch (punchType) {
    case "day_start":
      if (state === "off" || state === "day") return "day";
      return null;
    case "day_end":
      if (state === "day" || state === "work" || state === "break" || state === "travel") {
        return "off";
      }
      return null;
    case "in":
      if (state === "off" || state === "day" || state === "travel") return "work";
      return null;
    case "out":
      if (state === "work") return "day";
      return null;
    case "break_start":
      if (state === "work") return "break";
      return null;
    case "break_end":
      if (state === "break") return "work";
      return null;
    case "travel_start":
      if (state === "day" || state === "work") return "travel";
      return null;
    case "travel_end":
      if (state === "travel") return "day";
      return null;
    default:
      return null;
  }
}

export function computePunchDayState(punches: PortalPunchLike[]): PortalPunchDayState {
  let state: PortalPunchDayState = "off";
  for (const p of punches) {
    const next = punchDayStateAfter(state, p.punch_type);
    if (next === null) break;
    state = next;
  }
  return state;
}

export function derivePortalPunchStatus(
  lastPunch: PortalPunchLike | null,
  options?: {
    workProfile?: string | null;
    legacyInOutOnly?: boolean | null;
    punches?: PortalPunchLike[];
    dayState?: PortalPunchDayState | string | null;
  },
): PortalPunchStatus {
  const profile = options?.workProfile ?? "fixed_site";
  const legacy = isLegacyInOutOnly(profile, options?.legacyInOutOnly);
  const punches = options?.punches ?? (lastPunch ? [lastPunch] : []);
  const dayState = (options?.dayState as PortalPunchDayState | null) ?? computePunchDayState(punches);

  let valid = true;
  let state: PortalPunchDayState = "off";
  for (const p of punches) {
    const next = punchDayStateAfter(state, p.punch_type);
    if (next === null) {
      valid = false;
      break;
    }
    state = next;
  }
  if (!valid) return "unknown";

  switch (dayState) {
    case "off":
      return "outside";
    case "day":
      return isMobileWorkProfile(profile) && !legacy ? "on_day" : "outside";
    case "work":
      return "working";
    case "break":
      return "on_pause";
    case "travel":
      return "traveling";
    default:
      return "unknown";
  }
}

const MOBILE_ONLY: PortalPunchType[] = [
  "day_start",
  "day_end",
  "travel_start",
  "travel_end",
];

export function getAvailablePortalPunchActions(
  dayState: PortalPunchDayState,
  isMobile: boolean,
  legacyInOutOnly: boolean,
): PortalPunchType[] {
  const candidates: PortalPunchType[] = [
    "day_start",
    "day_end",
    "in",
    "out",
    "travel_start",
    "travel_end",
  ];
  const actions: PortalPunchType[] = [];
  for (const pt of candidates) {
    if (punchDayStateAfter(dayState, pt) === null) continue;
    if (!isMobile && MOBILE_ONLY.includes(pt)) continue;
    if (isMobile && !legacyInOutOnly && dayState === "off" && pt === "in") continue;
    // UI: day_start només quan la jornada encara no ha començat
    if (pt === "day_start" && dayState !== "off") continue;
    // UI: sortir del client abans d'iniciar desplaçament (plan §5.0)
    if (pt === "travel_start" && dayState === "work") continue;
    actions.push(pt);
  }
  return actions;
}

const PRIMARY_PRIORITY: PortalPunchType[] = [
  "day_start",
  "in",
  "out",
  "travel_end",
  "day_end",
  "travel_start",
];

function primaryPriorityForState(dayState: PortalPunchDayState): PortalPunchType[] {
  if (dayState === "travel") {
    // Arribada abans d'entrar al següent client
    return ["travel_end", "in", "day_end", "out", "day_start", "travel_start"];
  }
  if (dayState === "work") {
    return ["out", "break_start", "in", "travel_end", "day_end", "travel_start", "day_start"];
  }
  return PRIMARY_PRIORITY;
}

export function getPrimaryPortalPunchAction(
  dayState: PortalPunchDayState,
  isMobile: boolean,
  legacyInOutOnly: boolean,
): PortalPunchType | null {
  const available = getAvailablePortalPunchActions(dayState, isMobile, legacyInOutOnly);
  for (const p of primaryPriorityForState(dayState)) {
    if (available.includes(p)) return p;
  }
  return available[0] ?? null;
}

export function getSecondaryPortalPunchActions(
  dayState: PortalPunchDayState,
  isMobile: boolean,
  legacyInOutOnly: boolean,
): PortalPunchType[] {
  const primary = getPrimaryPortalPunchAction(dayState, isMobile, legacyInOutOnly);
  return getAvailablePortalPunchActions(dayState, isMobile, legacyInOutOnly).filter(
    (a) => a !== primary,
  );
}

export function nextPortalPunchAction(status: PortalPunchStatus): PortalPunchType | null {
  if (status === "outside" || status === "unknown" || status === "on_day") return "in";
  if (status === "working") return "out";
  return null;
}

export function formatPortalTime(iso: string | null | undefined): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleTimeString("ca-ES", { hour: "2-digit", minute: "2-digit" });
}

export const PORTAL_PUNCH_I18N: Record<PortalPunchType, { short: string; confirm: string; shortDefault: string }> = {
  in: { short: "employee_portal.punch_in_short", confirm: "employee_portal.punch_in", shortDefault: "Entrar" },
  out: { short: "employee_portal.punch_out_short", confirm: "employee_portal.punch_out", shortDefault: "Sortir" },
  day_start: { short: "employee_portal.punch_day_start_short", confirm: "employee_portal.punch_day_start", shortDefault: "Inici jornada" },
  day_end: { short: "employee_portal.punch_day_end_short", confirm: "employee_portal.punch_day_end", shortDefault: "Fi jornada" },
  travel_start: { short: "employee_portal.punch_travel_start_short", confirm: "employee_portal.punch_travel_start", shortDefault: "Desplaçament" },
  travel_end: { short: "employee_portal.punch_travel_end_short", confirm: "employee_portal.punch_travel_end", shortDefault: "Arribada" },
  break_start: { short: "employee_portal.pause_start_short", confirm: "employee_portal.pause_start", shortDefault: "Pausa" },
  break_end: { short: "employee_portal.pause_end_short", confirm: "employee_portal.pause_end", shortDefault: "Tancar pausa" },
};

export const PORTAL_TIMELINE_I18N: Record<PortalPunchType, string> = {
  in: "employee_portal.timeline_in",
  out: "employee_portal.timeline_out",
  day_start: "employee_portal.timeline_day_start",
  day_end: "employee_portal.timeline_day_end",
  travel_start: "employee_portal.timeline_travel_start",
  travel_end: "employee_portal.timeline_travel_end",
  break_start: "employee_portal.timeline_break_start",
  break_end: "employee_portal.timeline_break_end",
};
