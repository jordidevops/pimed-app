# CF-29 — Calculadores de preu i flux ràpid de pressupost

> **Estat:** 📄 pla executable. Cap fase implementada (2026-10-14).
> **Checklist:** [`CHECKLIST.md`](./CHECKLIST.md)
> **Decisions:** [`00-decisions.md`](./00-decisions.md) — les fases segueixen els supòsits de treball d’allà fins que un humà els canviï.
> **Contracte:** [`01-schema.md`](./01-schema.md)
> **Riscos:** [`RISCOS.md`](./RISCOS.md)
> **No és la fase activa** de [`../EXECUTION.md`](../EXECUTION.md) fins que es triï explícitament.

## Resultat de producte

Un tenant configura una calculadora (paràmetres, taules de tarifa, línies condicionals). Qui fa un pressupost introdueix només els paràmetres i obté línies de preu. Pot fer-ho al full de preus d’una OS o al pressupost orfe, i pot tenir un flux curt: contacte → font de línies → emetre, sense tornar a triar plantilla ni formalització si el tenant ja les ha fixat.

La plantilla de pressupost o contracte no calcula. Mostra línies i totals ja congelats ([`../cf24-closed-vocabulary.md`](../cf24-closed-vocabulary.md)).

## Per què aquest ordre

L’ordre de partida (motor → biblioteca i flux ràpid → defaults → editor → IA → lògica) es corregeix:

- La biblioteca neix sense preus. Una calculadora incompleta no es pot activar. El flux ràpid abans de l’editor deixaria clons inútils.
- Els defaults de plantilla i formalització ja són claus a `tenants.settings.commercial`, però el wizard no les consumeix. Han d’existir abans del flux curt, si no «emetre» torna a preguntar el mateix.

Ordre per defecte: **0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8**.

La fase 3 no depèn del motor. Es pot fer en paral·lel amb 0–2. El flux curt (fase 6) sí que la necessita.

| Fase | Document | Què queda fet | Depèn de |
|------|----------|---------------|----------|
| 0 | [02-fase-0-spike.md](./02-fase-0-spike.md) | On viu el motor (paquet compartit o bessons) | — |
| 1 | [03-fase-1-motor.md](./03-fase-1-motor.md) | AST, validador, dos exemples, diners = `line_net` | 0 |
| 2 | [04-fase-2-persistencia.md](./04-fase-2-persistencia.md) | Versions, origen de línia, apply als dos destins | 1 |
| 3 | [05-fase-3-flux-defecte.md](./05-fase-3-flux-defecte.md) | Saltar plantilla i formalització si hi ha default | — |
| 4 | [06-fase-4-editor.md](./06-fase-4-editor.md) | Editor de taules i paràmetres, estats, cas obligatori | 2 |
| 5 | [07-fase-5-biblioteca.md](./07-fase-5-biblioteca.md) | Catàleg per arquetip, clonar sense preus | 4 |
| 6 | [08-fase-6-flux-rapid.md](./08-fase-6-flux-rapid.md) | Formulari als composers i flux curt orfe | 3, 4 |
| 7 | [09-fase-7-ia.md](./09-fase-7-ia.md) | IA que proposa definició o diff, amb casos | 4 |
| 8 | [10-fase-8-logica.md](./10-fase-8-logica.md) | Constructor de lògica sobre l’AST | 1, 4 |

La fase 7 pot anar abans de la 5 i la 6. No abans de la 4: la prova de casos és obligatòria des del primer dia de la IA.

## Què ja hi ha al codi (2026-10-14)

El codi mana si un pla antic el contradiu.

- **Camí C, entregat.** `api.create_prospect_work_order` (`commercial_stage=prospect`) a `supabase/migrations/20261230000001_cf24_commercial_stage_prospect.sql`. Full de preus: `apps/tenant-portal/src/features/projects/components/ProjectLinesSection.tsx`. Emissió: `api.issue_commercial_document` (copia `project_lines` → `commercial_document_lines`). **Acceptar no promou a `execute` tot sol**: `data.apply_commercial_decision` (`20261245000001`) només canvia l’estat del document i recalcula l’autoritzat; cal una crida explícita a `api.promote_project_to_execute` (`20261230000001`). Una fase que assumeixi `execute` just després d’acceptar s’equivoca.
- **Camí V2, implementat.** No és només un pla. Draft, línies i emissió: `supabase/migrations/20261231000001_cf24_v2_orphan_quote.sql`. UI: `OrphanQuoteComposer.tsx`. En acceptar **no** es crea OS (`20261245000001_orphan_accept_defer_os.sql`, spike `../cf24-v2-orphan-spike.md`). L’oficina crida `api.ensure_project_from_orphan_quote` o `api.mark_orphan_quote_project_not_needed`. [`../06-sales-entry-modes-quote-first.md`](../06-sales-entry-modes-quote-first.md) encara diu el contrari (V2 en curs, composer sense IA/hàbits, accept → OS). El composer ja aplica servei habitual i IA escrivint línies de document des del client.
- **Order-first.** Mateix full de preus sobre una OS `execute`. `api.apply_pricing_template` i `api.apply_price_sheet` només escriuen `project_lines`.
- **Servei habitual.** `pricing_templates` + ítems amb `catalog_item_id` obligatori, `default_quantity`, `prompt_quantity`, `prompt_label`. En aplicar es copia el PVP viu del catàleg i, si n’hi ha, checklists (CF-23). No hi ha fórmules. Reaplicar **afegeix** línies; no substitueix les anteriors. `pricing_template_applications.project_id` és NOT NULL.
- **`apply_price_sheet` no és l’adaptador.** El mode `replace` esborra totes les línies del projecte. Rebutja línia lliure amb preu ≤ 0. Les línies lliures exigeixen `commercial.pricing.edit`.
- **Cap origen de línia.** Ni `project_lines` ni `commercial_document_lines` tenen `origin`, `template_id` ni `metadata`. La traça és `source_project_line_id`, `source_quote_line_id` i el rebut d’aplicació de l’hàbit.
- **Diners.** `data.line_net` = `ROUND(qty * price * (1 - disc/100), 2)`. Després `ROUND(net * tax_rate/100, 2)`. La vista `api.project_lines.total_with_tax` arrodoneix el brut amb IVA d’un sol cop (`20260503000006_catalog_and_project_lines.sql`). Moneda `EUR`. Quantitat `numeric(10,3)`. Descompte només per línia. `kind` de línia: enum `product` | `service` (no «material» ni «labor»).
- **Settings.** `data.tenants.settings.commercial`: `quote_template_id`, `agreement_template_id`, `formalization_mode_default`. UI: `CommercialDocumentTemplatesSection.tsx` (owner/manager). El wizard no els llegeix: `CreateQuoteWizardDialog.tsx` sempre pregunta la formalització; `PrepareQuoteWizard.tsx` torna a demanar plantilla. `commercial.preferred_entry` només està escrit al document 06.
- **IA reutilitzable.** `generate-ai-content`, `useAiGenerate`, `platform_ai_feature_prompts`, addon `tenant_ai_config.is_active`, ledger de tokens (no euros). Features actuals `commercial.price_sheet` i `catalog.pricing_template` proposen línies concretes, no una definició executable. El parse del portal és `JSON.parse`, sense Zod de domini.
- **Versions a copiar.** `checklist_template_versions` (`20261159000001_checklist_maintenance_engine.sql`): draft / published immutable.
- **Arquetips.** `sector_profiles`: `field_service`, `practice`, `hospitality`, `workshop_maker`, `generic`. No existeixen verticals «electricista» ni «persianes».
- **Codi compartit.** No hi ha workspaces pnpm. `packages/ai-schemas` no el consumeix el portal. Les Edge Functions importen `supabase/functions/_shared`. Tests Deno: `Deno.test` a `_shared/**/*.test.ts`. Tests portal: `npm run test:unit` a `apps/tenant-portal` (vitest).

## Què falta

Definició executable, validador, versions immutables, marca d’origen a les dues taules de línies, adaptador que substitueixi només les generades, formulari de paràmetres, biblioteca, editor i una feature d’IA de definicions. El flux «contacte → font → emetre» no existeix.

## Què depèn de V2 i de C

Independent del camí: esquema, motor, validador, versions, biblioteca, editor, IA, casos, settings per defecte.

L’adaptador escriu a un destí o a l’altre. V2 ja persisteix línies de document i ja emet. C ja persisteix `project_lines` i ja emet. No cal una unificació nova de RPCs de full de preus.

El flux curt (fase 6) tria l’orfe, supòsit D1. Canviar-lo a prospecte és canviar la clau de destí, no el motor. La calculadora no crea l’OS en acceptar un orfe: això ja és manual.

`issue_commercial_document` i `ensure_project_from_orphan_quote` han de copiar origen, definició, versió, key i run. Si no, la traça mor a l’emissió o en crear l’OS. Això és feina de la fase 2.

## Fora d’aquest epic

Importador Excel (el mapa que el faria possible està a [`01-schema.md`](./01-schema.md) § Excel), verticals noves, unificar servei habitual i calculadora, descompte de capçalera, multi-moneda, cost i marge, checklists des de la calculadora, auto-actualització de clons, `preferred_entry`, bucles «una línia per finestra», línies que depenen del total d’altres línies.

## Com executar una fase

1. Llegir aquest README, el supòsit de treball que la fase cita a [`00-decisions.md`](./00-decisions.md), i [`01-schema.md`](./01-schema.md) si toca el motor o el JSON.
2. Implementar només el document de la fase. No anticipar la UI de fases posteriors.
3. Complir el checklist d’aquella fase a [`CHECKLIST.md`](./CHECKLIST.md).
4. Les fases amb UI es comproven al navegador (recorregut, no només una captura).
5. En tancar: marcar la fase a [`CHECKLIST.md`](./CHECKLIST.md) i una línia a [`../STATUS.md`](../STATUS.md).
