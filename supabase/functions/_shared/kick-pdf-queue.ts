import { log } from "./observability/structured-logger.ts";

const FEATURE = "kick-pdf-queue";

/** Desperta el worker PDF (document + auditoria a la mateixa cua). */
export function kickPdfQueueWorker(supabaseUrl: string, serviceRoleKey: string): void {
  if (!serviceRoleKey) return;
  const url = `${supabaseUrl}/functions/v1/process-document-pdf-queue`;
  fetch(url, {
    method:  "POST",
    headers: { Authorization: `Bearer ${serviceRoleKey}` },
  }).catch((e: Error) => {
    log("warn", FEATURE, "Failed to kick PDF queue worker", { extra: { error: e.message } });
  });
}
