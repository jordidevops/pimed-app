type TranslateFn = (key: string, options?: { defaultValue?: string }) => string;

const ACTION_FALLBACKS: Record<string, string> = {
  view_schedule: "Consulta horari",
  view_history: "Consulta historial",
  view_monthly_report: "Consulta registre",
  monthly_confirm: "Confirmació registre (mes)",
  period_confirm: "Confirmació registre (període)",
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
  batch_start: "Lot d'enllaços iniciat",
  batch_fetch: "Descàrrega lot",
  batch_ack: "Lot confirmat",
  token_invalid: "Enllaç no vàlid",
  token_expired: "Enllaç caducat",
};

const FAILURE_FALLBACKS: Record<string, string> = {
  document_mismatch: "Document no coincideix",
  identity_locked: "Massa intents de verificació",
  pin_invalid: "PIN incorrecte",
  pin_locked: "PIN bloquejat",
};

export function portalAccessLogActionLabel(
  action: string,
  t: TranslateFn,
): string {
  return t(`employees.portal_access.logs_action_${action}`, {
    defaultValue: ACTION_FALLBACKS[action] ?? action,
  });
}

export function portalAccessLogFailureLabel(
  failureReason: string | null | undefined,
  t: TranslateFn,
): string | null {
  if (!failureReason) return null;
  return t(`employees.portal_access.logs_failure_${failureReason}`, {
    defaultValue: FAILURE_FALLBACKS[failureReason] ?? failureReason,
  });
}

export function portalAccessLogMetadataDetail(
  metadata: Record<string, unknown> | null | undefined,
  t: TranslateFn,
): string | null {
  if (!metadata || typeof metadata !== "object") return null;
  const last4 = metadata.document_id_last4;
  if (typeof last4 === "string" && last4.length > 0) {
    return t("employees.portal_access.logs_document_last4", {
      defaultValue: "Document ···{{last4}}",
      last4,
    });
  }
  return null;
}
