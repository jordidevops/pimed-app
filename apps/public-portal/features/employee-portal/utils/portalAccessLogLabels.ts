type TranslateFn = (key: string, fallback: string) => string;

const ACTION_FALLBACKS: Record<string, string> = {
  view_schedule: "Consulta horari",
  view_history: "Consulta historial",
  view_monthly_report: "Consulta registre",
  monthly_confirm: "Confirmació del registre (mes)",
  period_confirm: "Confirmació del registre (període)",
  view_access_logs: "Consulta accessos",
  request_absence: "Sol·licitud absència",
  push_subscribe: "Activació notificacions",
  punch_in: "Entrada",
  punch_out: "Sortida",
  pause_start: "Inici pausa",
  pause_end: "Fi pausa",
  pin_failed: "PIN incorrecte",
  pin_locked: "PIN bloquejat",
  pin_setup: "PIN definit",
  pin_changed: "PIN canviat",
  pin_reset: "PIN restablert",
  identity_verify_failed: "Verificació d'identitat fallida",
  identity_rejected: "Identitat rebutjada",
  identity_confirmed: "Identitat confirmada",
  session_create: "Inici sessió",
  session_refresh: "Renovació sessió",
  token_invalid: "Enllaç no vàlid",
  token_expired: "Enllaç caducat",
};

export function portalAccessLogActionLabel(
  action: string,
  t: TranslateFn,
): string {
  const key = `employee_portal.access.action_${action}`;
  return t(key, ACTION_FALLBACKS[action] ?? action);
}
