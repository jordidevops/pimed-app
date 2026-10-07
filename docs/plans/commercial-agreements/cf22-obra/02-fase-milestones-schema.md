# Fase 2 — Schema i RPC de fites

> **Ordre:** 2 · **Depèn de:** fase 1 · **Bloqueja:** 3, 4  
> **Índex:** [`README.md`](./README.md) · O-D3, O-D11, O-D12, O-D13, O-D14, O-D15

## Objectiu

Persistir fites a la **versió** de l’acord, amb CRUD gated i immutabilitat post-enviament/firma.

## Model proposat

`data.commercial_agreement_milestones`

| Columna | Notes |
|---------|--------|
| `id` uuid PK | |
| `tenant_id` | |
| `version_id` | FK → `commercial_agreement_versions` ON DELETE CASCADE |
| `agreement_id` | FK denormalitzat per RLS/llistes (mateix tenant) |
| `sort_order` int | ≥ 0 |
| `title` text | non-empty |
| `amount_cents` int | ≥ 0; font de veritat (O-D11) |
| `due_on` date | nullable |
| `status` | `planned` \| `completed` \| `cancelled` (O-D15) |
| `completed_at` timestamptz | null si no completed |
| `completed_by` uuid | nullable → profiles |
| `notes` text | nullable |
| `created_at` / `updated_at` | |

Constraints:

- Unique (`version_id`, `sort_order`) o reorder atòmic via RPC.
- CHECK status.
- Trigger / RPC: suma `amount_cents` on `status <> 'cancelled'` ≤ contractat (O-D11). Definir contractat al RPC: suma `authorized_total` dels `commercial_agreement_projects` de l’`agreement_id` al moment de l’write (no congelar a la fita).

**Prohibit:** FK a `commercial_agreement_billing_periods`. **Prohibit:** `invoice_id` a V1.

## Immutabilitat (O-D13)

- Si `versions.status IN ('pending_signature','signed')`: només permetre `status` planned→completed / planned→cancelled via RPC dedicat **si** es vol marcar progrés post-firma; **no** canviar `amount_cents`, `title`, `due_on`, `sort_order`.
- Decisió V1 explícita: post-firma, **sí** marcar completed/cancelled (progrés operatiu); **no** reeditar imports. Documentar al RPC.
- Pre-`pending_signature`: replace set / upsert llista completa OK.

## RPCs (noms orientatius)

- `api.replace_agreement_version_milestones(p_version_id, p_milestones jsonb, p_client_op_id)` — només versió editable; owner/manager.
- `api.set_agreement_milestone_status(p_milestone_id, p_status, p_client_op_id)` — completed/cancelled; owner/manager.
- `api.list_agreement_milestones(p_agreement_id | p_version_id)` — lectura.

Idempotència: mateix patró `client_op_id` / events que la resta d’acords si ja hi ha helper; si no, almenys unique op on writes crítics.

## RLS

- SELECT: mateix criteri que versions/acords (jwt tenant).
- Escritura: **només** via RPC SECURITY DEFINER (REVOKE writes a authenticated), com la resta del mòdul.

## Checklist

- [ ] Migració taula + índexs `(tenant_id, version_id)`, `(agreement_id)`.
- [ ] RPCs + grants.
- [ ] Validació suma amounts.
- [ ] Lock post-firma en imports.
- [ ] Suite `commercial_cf22_milestones_tests.sql` (o nom coherent amb `run_commercial_agreement_tests`).
- [ ] Casos: draft OK; pending_signature bloqueja replace; set completed OK; cancelled exclòs de suma; forbidden sense rol.

## DoD

- [ ] Tests SQL verds en local.
- [ ] Cap camí authenticated UPDATE directe a la taula.
- [ ] O-D12 respectat (cap side-effect de facturació).

## Fora d’aquesta fase

UI, tokens PDF de fites, seguiment contractat/executat.
