import { rpcErrorMessage } from './rpcError'

const CODE_MESSAGES: Record<string, string> = {
  external_invoice_number_taken: 'Aquest número de factura ja existeix al tenant.',
  delivery_note_invoiced: 'Aquest albarà ja està inclòs en una factura.',
  payment_exceeds_remaining: 'L’import supera el pendent de cobrament.',
  active_tenant_required: 'Cal seleccionar un tenant actiu.',
  forbidden: 'No tens permís per a aquesta operació.',
  invoice_total_mismatch: 'El total de la factura no coincideix amb les línies dels albarans.',
  invoice_totals_mismatch: 'El total de la factura no coincideix amb les línies dels albarans.',
  invoice_delivery_notes_empty_lines:
    'Els albarans seleccionats no tenen línies; no es pot emetre la factura.',
  fiscal_year_closed: 'L’exercici està tancat i no admet aquesta operació.',
  delivery_note_already_linked: 'Un dels albarans ja està reservat o facturat.',
  delivery_already_invoiced: 'Un dels albarans ja està inclòs en una factura.',
  invoice_has_payments: 'No es pot anul·lar una factura amb cobraments propis.',
  invoice_not_cancellable: 'Aquesta factura no es pot anul·lar en l’estat actual.',
  client_op_id_required: 'Falta l’identificador d’operació; torna a provar.',
  commercial_signature_field_missing:
    'El PDF no té casella de firma. Usa una plantilla de pressupost amb camp de firma (Accepto / client_accept) o el format per defecte del sistema.',
  signature_field_not_found:
    'No s’ha trobat la casella de firma al PDF. Revisa la plantilla o regenera el document.',
  missing_required_fields: 'Falten dades obligatòries per estampar la firma.',
  session_not_found: 'La sessió de firma no existeix o ha caducat. Torna a començar.',
  already_signed: 'Aquest document ja està firmat.',
  session_declined: 'La sessió de firma està rebutjada.',
  pdf_job_not_ready: 'El PDF encara s’està generant. Espera uns segons i torna-ho a provar.',
  PGRST202: 'La funció no està disponible al servidor (schema cache o migració pendent). Recarrega o aplica les migracions.',
}

function extractCode(err: unknown): string | null {
  if (typeof err !== 'object' || err === null) return null
  const row = err as { code?: unknown; message?: unknown; details?: unknown; hint?: unknown }
  const code = typeof row.code === 'string' ? row.code.trim() : ''
  if (code && CODE_MESSAGES[code]) return code

  const message = typeof row.message === 'string' ? row.message : ''
  const details = typeof row.details === 'string' ? row.details : ''
  const hint = typeof row.hint === 'string' ? row.hint : ''
  const blob = `${code}\n${message}\n${details}\n${hint}`
  for (const key of Object.keys(CODE_MESSAGES)) {
    if (blob.includes(key)) return key
  }
  if (code === 'PGRST202' || blob.includes('Could not find the function') || blob.includes('schema cache')) {
    return 'PGRST202'
  }
  return code || null
}

/** True when commercial decision requests are turned off for the tenant (optional path). */
export function isDecisionRequestsDisabledError(err: unknown): boolean {
  return commercialErrorMessage(err, '').includes('decision_requests_disabled')
}

/**
 * Human-readable commercial / PostgREST error for toasts.
 * Prefer this over `err instanceof Error` — Supabase errors are plain objects.
 */
export function commercialErrorMessage(
  err: unknown,
  fallback = 'No s’ha pogut completar l’operació comercial.',
): string {
  const code = extractCode(err)
  if (code && CODE_MESSAGES[code]) return CODE_MESSAGES[code]

  if (typeof err === 'object' && err !== null) {
    const row = err as { message?: unknown; details?: unknown; hint?: unknown }
    const parts: string[] = []
    if (typeof row.message === 'string' && row.message.trim()) parts.push(row.message.trim())
    if (typeof row.details === 'string' && row.details.trim()) parts.push(row.details.trim())
    if (typeof row.hint === 'string' && row.hint.trim()) parts.push(row.hint.trim())
    if (parts.length) return parts.join(' — ')
  }

  const fromRpc = rpcErrorMessage(err)
  if (fromRpc) return fromRpc
  if (typeof err === 'string' && err.trim()) return err.trim()
  return fallback
}
