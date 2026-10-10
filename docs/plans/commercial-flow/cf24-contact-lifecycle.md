# CF-24 — Cicle de vida derivat del contacte

> **Estat:** implementat al portal (derivació client). Independent del model Quote-first A/B/C.

## Valors

| Valor | UI (ca) | Regla |
|-------|---------|--------|
| `effective` | Efectiu | Té document comercial `accepted`/`signed`, **o** projecte operatiu no cancel·lat (`work_order` / `maintenance` / `internal`) amb `service_mode` `execute` o `assessment` |
| `potential` | Potencial | No efectiu, i (`source` ∈ `public_portal`\|`web` **o** pressupost `issued`/`draft` obert) |
| `agenda` | Agenda | Resta (contacte sense senyal comercial) |

## Notes

- No és un camp persistit a `contacts`; es deriva a [`contactCommercialLifecycle.ts`](../../../apps/tenant-portal/src/features/contacts/utils/contactCommercialLifecycle.ts).
- Amb D1=C: projectes `commercial_stage=prospect` s’exclouen de `effective` (només `execute` compta) i resten com a senyal `potential` via pressupost obert / font lead.
- Factures natives (`doc_type=invoice` accepted/issued) també compten via `hasAcceptedOrSignedDoc` si entren a la consulta de documents.

## UI

Badge a llista `/contacts` (targetes i taula) i al detall del contacte.
