# Fase 0 — Bugs del modal «Registrar factura»

> **Ordre:** 0 · **Depèn de:** res · **Bloqueja:** 1A (el modal canvia a `issue_invoice` després)  
> **Índex:** [`README.md`](./README.md)

## Objectiu

Fer fiable el flux actual de factura externa abans del canvi de model: errors llegibles, estat net del modal i diagnòstic del `PGRST202`.

## Context (codi actual)

- Modal a `DeliveryNotesList.tsx`: `invoiceNumber`, `invoiceDate`, `invoiceTotal` es queden de la sessió anterior.
- Toast: `err instanceof Error ? err.message` — els errors PostgREST són objectes plans → només «Error comercial».
- RPC: `api.register_external_invoice(...)` a `commercialFlowService.ts` / migració `20261216000005`.
- Error vist: `PGRST202` «function without parameters» → schema cache / cos de request / migració no aplicada.

## Checklist d’implementació

### 0.1 Diagnòstic PGRST202

- [ ] Confirmar a l’entorn local que la migració `20261216000005` està aplicada (`supabase migration list` / `\df api.register_external_invoice`).
- [ ] Comparar signatura SQL vs args de `registerExternalInvoice` a `commercialFlowService.ts`.
- [ ] Capturar el cos real de la request al Network (no assumir `NaN`).
- [ ] Forçar `NOTIFY pgrst, 'reload schema'` si cal i revalidar.
- [ ] Documentar la causa arrel en aquest arxiu (secció «Causa PGRST202») quan es conegui.

### 0.2 Helper d’errors comercials

- [ ] Crear `commercialErrorMessage(err)` (p. ex. a `features/commercial/utils/commercialErrorMessage.ts`).
- [ ] Llegir `message`, `code`, `details`, `hint` d’objectes Supabase/PostgREST.
- [ ] Mapa de codis coneguts → català: com a mínim  
  `external_invoice_number_taken`, `delivery_note_invoiced`, `payment_exceeds_remaining`,  
  `active_tenant_required`, `forbidden`, i el text de `PGRST202` / funció no trobada.
- [ ] Substituir toasts comercials que usen `instanceof Error` (hub, panell, pagaments, rectify).
- [ ] Tests TS del helper (objecte pla, `Error`, string, desconegut).

### 0.3 Modal

- [ ] En obrir el modal: reset de número, data (= avui), total.
- [ ] Total = suma dels albarans seleccionats, **només lectura**.
- [ ] Etiquetes visibles + text d’ajuda: Número de factura (ERP), Data d’emissió, Total (suma albarans).
- [ ] No conservar valors entre obertures.

### 0.4 Prova manual

- [ ] Registrar factura amb número nou → OK.
- [ ] Tornar a obrir modal → camps nets; total = selecció.
- [ ] Número duplicat → toast amb missatge llegible (no «Error comercial» sol).
- [ ] Si PGRST202 persistia, verificar que desapareix o el toast explica el diagnòstic.

## Causa PGRST202

> Data: 2026-10-02  
> Causa: `register_external_invoice` missing from generated `database.types.ts` **and/or** PostgREST schema cache / migrations not applied. When the function is absent from the exposed schema (or the client types omit it), PostgREST returns **PGRST202** «Could not find the function … without parameters» even if the request body looks correct.  
> Fix (Phase 0): document the failure; surface a readable error via `commercialErrorMessage` (map PGRST202 / function-not-found). Confirm migration `20261216000005` is applied and force `NOTIFY pgrst, 'reload schema'` if needed.  
> Follow-up: native invoice RPCs (`create_invoice_draft_from_delivery_notes`, `issue_invoice`, …) from CF-27 migrations `20261217000001`+ will be typed in **Phase 7** (`database.types.ts` regen). Until then, treat missing stubs the same way (readable toast, not silent `instanceof Error`).

## Fitxers esperats

| Acció | Fitxer |
|-------|--------|
| Editar | `DeliveryNotesList.tsx` |
| Editar | toasts a components comercials afectats |
| Crear | `commercialErrorMessage.ts` (+ test) |
| Editar | `commercialFlowService.ts` només si cal fix de crida |

## DoD

- [ ] Modal net + etiquetes + total precalculat.
- [ ] Cap toast comercial depèn només d’`instanceof Error`.
- [ ] PGRST202 resolt o documentat amb workaround operable.
- [ ] Fase marcada a [`CHECKLIST.md`](./CHECKLIST.md).

## Notes

Aquesta fase **encara** usa `register_external_invoice`. La Fase 1A el substitueix per `create_invoice_draft` / `issue_invoice`.
