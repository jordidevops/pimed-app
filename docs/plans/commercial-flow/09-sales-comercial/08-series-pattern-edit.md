# 08 — Edició gated del patró de sèrie (backlog)

> **Ordre:** follow-up de la fase 3 · **No bloqueja** CF-27 (epic ✅)  
> **Índex:** [`README.md`](./README.md) · checklist: [`CHECKLIST.md`](./CHECKLIST.md)  
> **Estat:** especificat, **no implementat** (2026-10-06)

## Objectiu

Deixar que un tenant amb `invoices.manage` canviï el **patró de numeració** d’una sèrie (`P` / `AMP` / `A` / `F`) **només abans de reservar el primer número d’aquella sèrie en l’any civil de referència**. Si l’any ja té documents numerats d’aquesta sèrie, el patró queda només lectura.

No és Verifactu. No és un editor lliure tot l’any. No s’edita el comptador.

## Per què (i què no)

Avui Settings → Comercial **mostra** `code · pattern · reset_policy` i fa preview; **no desa** el patró. La taula `data.commercial_document_series` és SELECT per `authenticated`. Els números es reserven a `issue_*` via `data.allocate_commercial_document_number` (S-D2: draft **sense** número).

Un write UI obert trencaria correlativitat. Un canvi **ops/SQL** a l’alta del tenant ja resol un prefix puntual. Aquest pla és el model de producte si es vol autoservei.

Verifactu (S-D12, [`07b`](../07b-albara-out-of-scope.md)) **no** depèn d’aquesta UI. Quan s’obri, caldrà un model fiscal amb **més** bloqueig, no menys.

## Context de codi

- Schema / seed / `validate_document_number_pattern` / allocate: [`supabase/migrations/20261217000004_sales_numbering_fiscal.sql`](../../../../supabase/migrations/20261217000004_sales_numbering_fiscal.sql)
- Preview (no reserva): `api.preview_next_document_number`
- Settings: [`apps/tenant-portal/src/pages/settings/CommercialSettingsPage.tsx`](../../../../apps/tenant-portal/src/pages/settings/CommercialSettingsPage.tsx)
- Llista sèries: `listCommercialDocumentSeries` a `commercialFlowService.ts` (SELECT `*`, sense flag d’editable)
- Errors: `commercialErrorMessage.ts`

Seed per tenant: `P-{YYYY}-{####}`, `AMP-…`, `A-…`, `F-…`, `reset_policy = yearly`.

## Decisions (aquest follow-up)

| ID | Decisió |
|----|---------|
| **S-D13** | S’edita **només** `pattern`. No `code`, no `name` (V1), no `reset_policy`, no `active`, no `last_value`, no alta/baixa de sèries, no selector de sèrie a Emmetre. |
| **S-D14** | El patró és **un per fila de sèrie** (no historial per any). Els `doc_number` ja persistits **no** es reescriuen. Un canvi només afecta emissions **posteriors**. |
| **S-D15** | Bloqueig = **sèrie × període de reset**. Per `yearly`: any civil de `issued_on` (fallback: `issued_at` a `Europe/Madrid`). Per `never`: un sol període `all` — el primer número bloqueja **per sempre**. El seed actual és `yearly`. |
| **S-D16** | Any de referència de la UI i del RPC = `EXTRACT(YEAR FROM (now() AT TIME ZONE 'Europe/Madrid'))`. Sense picker. No usar `CURRENT_DATE` del servidor si el TZ no és Madrid (avui `fiscal_year` / freeze ja usen Madrid). |
| **S-D17** | «Document que bloqueja» = fila a `commercial_documents` amb aquest `series_id`, `doc_number` no buit, i any d’emissió = any de referència. `draft` sense número **no** bloqueja. `issued` i `cancelled` **sí** (el número ja es va reservar). |
| **S-D18** | El comptador `commercial_document_number_counters.last_value > 0` del `period_key` corresponent també bloqueja (número reservat encara que el document hagi desaparegut). **Preview no escriu** el comptador → no bloqueja. |
| **S-D19** | Sèries independents: `A-2026-0001` bloqueja albarans el 2026, no factures. Documents **sense** `series_id` (llegat) no bloquegen cap sèrie. |
| **S-D20** | Permís: `invoices.manage` per desa. `invoices.view` veu el patró i el motiu de bloqueig, sense input. |

## Regla operativa

```text
editable(sèrie, Y) ⇔
  no existeix document numerat d’aquesta sèrie amb any(issued_on)=Y
  AND no existeix counter (sèrie, period_key(Y)) amb last_value > 0
```

`period_key(Y)` = `Y::text` si `yearly`; `'all'` si `never` (i llavors Y s’ignora).

Exemples:

- Tenant nou, cap emissió → les 4 sèries editables.
- Gina emet `F-2026-0001` (o l’anul·la) → sèrie factures **bloquejada el 2026**. Pressupostos/albarans segueixen editables si no tenen números 2026.
- 1 gen 2027, cap `F-2027-…` ni counter `period_key=2027` → factures **tornen** editables. Els `F-2026-…` queden.
- Vista prèvia del pròxim `F-2026-0001` → segueix editable.

## Forats i correccions respecte al primer esborrany

1. **«Editar el patró de l’any Y» no desa un patró per any.** Només **consulta** si Y ja té números. El valor nou és global a la sèrie.
2. **`reset_policy = never`:** la regla «per any» no aplica; primer número = lock definitiu. V1 no cal UI per canviar `reset_policy`.
3. **Data d’emissió retroactiva:** si el 2027 es canvia el patró i després s’emet amb `issued_on` del 2026, el 2026 podria barrejar `F-2026-…` vell i `FAC-2026-…` nou. **V1:** documentar-ho; no historial de patrons. **Harden (mateixa entrega si és barat):** a `allocate`, si el període destí ja té `last_value > 0`, no cal res extra (ja usa el patró actual, risc només si es va canviar *després* del primer número d’aquell període). El lock d’S-D15 **impedeix** canviar el patró mentre el període actual ja té números; el forat és **només** emetre cap a un període **passat** que ja tenia números, un cop canviat el patró en un període nou. Acceptat a V1; no reobrir sense taula d’historial.
4. **`issued_on` NULL:** usar `(issued_at AT TIME ZONE 'Europe/Madrid')::date` com `issue_invoice` ja fa en un fallback.
5. **Any tancat:** tancar exercici **no** és el mateix que bloquejar el patró. Es pot editar el patró d’una sèrie sense números a Y encara que Y estigui tancat (mutació de config, no d’emissió). L’emissió segueix gated per `fiscal_year_closed`.
6. **No** afegir pas a l’onboarding de sector (wizard actual = arquetip). El tenant nou va a Settings **abans** de la primera emissió.

## UI (quan s’implementi)

Pàgina existent: `/settings/commercial`.

- `invoices.manage` + `editable`: input del patró + Desa (per fila). Desa deshabilitat si el text = patró actual o patró invàlid al client (validació dura al servidor).
- Bloquejat o sense `manage`: el text actual (`F · F-{YYYY}-{####} · yearly`) + una línia: «Ja hi ha documents d’aquesta sèrie el {Y}. El patró no es pot canviar.»
- Tokens (copy): `{YYYY}` `{YY}` `{####}` `{###}` `{##}` `{#}` `{code}` `{CODE}`. El servidor ja rebutja desconeguts (`invalid_number_pattern` / `invalid_number_pattern_token:*`).
- V1 **exigeix** almenys un token de seqüència (`{####}` / `{###}` / `{##}` / `{#}`) perquè dos documents no rebin el mateix literal.
- El flag `pattern_editable` el calcula el **servidor** (no `new Date()` al navegador). O bé columna a un RPC `list` o un camp a un view; no confiar només en el client.

## Backend (quan s’implementi)

- `api.update_commercial_document_series_pattern(p_series_id uuid, p_pattern text)`  
  `invoices.manage` · `SECURITY DEFINER` · `search_path = data`.
- Flux: tenant actiu → permís → `SELECT … FOR UPDATE` de la sèrie del tenant → `validate_document_number_pattern` + token de seqüència → comprovar S-D17/S-D18 per l’any S-D16 → `UPDATE pattern` → `updated_at`.
- Idempotència: si `btrim(p_pattern) = series.pattern` i la sèrie existeix, `RETURN` sense error encara que estigui bloquejada.
- RAISE: `unauthenticated`, `active_tenant_required`, `forbidden`, `series_not_found`, `invalid_number_pattern`, `invalid_number_pattern_token:%`, `series_pattern_locked` (any amb números).
- **No** GRANT UPDATE directe a `authenticated` sobre la taula; només el RPC.
- Mapa i18n a `commercialErrorMessage`.
- Opcional útil: `api.commercial_document_series_with_edit` o camp calculat `pattern_editable boolean` per l’any Madrid.

## Proves (quan s’implementi)

Suite SQL nova p. ex. `sales_series_pattern_edit_tests.sql`:

- [ ] Preview no bloqueja ni escriu counter.
- [ ] Update OK amb 0 documents; el preview següent usa el patró nou.
- [ ] Issue reserva número → update RAISE `series_pattern_locked`.
- [ ] Cancel de la factura → segueix locked.
- [ ] Draft sense `doc_number` → update OK.
- [ ] DN 2026 no bloqueja sèrie factura 2026.
- [ ] Counter `last_value > 0` sense fila de document → locked.
- [ ] Simular any nou (counter/docs només a Y-1) → update OK.
- [ ] `never` + un número → locked independent de l’any.
- [ ] Sense `invoices.manage` → `forbidden`.
- [ ] Patró sense token `#` → invalid.
- [ ] Mateix patró + locked → OK.
- [ ] `FOR UPDATE`: no cal test de càrrega; sí dos updates seqüencials issue-then-update.

Vitest: missatges `series_pattern_locked` / `invalid_number_pattern`.

UAT: tenant seed **sense** factures 20XX a la sèrie F, o un tenant/sèrie neta; no tancar l’exercici 2026 a Riera com a efecte secundari.

## DoD (quan s’implementi)

- [ ] RPC + tests SQL verds en local.
- [ ] Settings: input només si `pattern_editable`; lock copy si no.
- [ ] Types regenerats; `commercialErrorMessage` cobert.
- [ ] Aquest arxiu: checkboxes marcats; nota a [`IMPLEMENTATION-LOG.md`](./IMPLEMENTATION-LOG.md) + [`EXECUTION.md`](../EXECUTION.md).
- [ ] **No** deixar l’any fiscal de Riera tancat si es fa smoke de FY.

## Fora d’abast

- Segona sèrie del mateix `doc_type` (cal selector a Emmetre: avui `ORDER BY code LIMIT 1`).
- Editar `last_value` / reenumerar el passat.
- Historial de patrons per període (tanca el forat de data retroactiva).
- Pas d’onboarding de sector.
- Verifactu / sèrie fiscal AEAT.
- EXPLAIN escala.
- Adaptadors ERP.

## Ordre d’implementació suggerit

1. RPC + tests SQL (la regla viu al servidor).
2. Flag `pattern_editable` llegible pel client.
3. Settings UI + i18n.
4. Smoke Gina en una sèrie **sense** números de l’any actual (o tenant de test), no sobre `F` de Riera 2026 un cop ja hi ha `F-2026-0001`.
