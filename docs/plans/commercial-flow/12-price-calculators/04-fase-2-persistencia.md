# Fase 2 — Persistència, origen i adaptador

> **Tall desplegable:** sí, darrere d’una entrada encara no descobrible (o només en un diàleg de prova retirat al final de la fase si no es vol UI).
> **Schema:** sí
> **Depèn de:** fase 1
> **Contracte:** [`01-schema.md`](./01-schema.md) § Persistència, § RPC, § Edge

## Abast

1. Migració amb les taules `calculator_definitions`, `calculator_versions`, `calculator_cases`, `calculator_runs`, `calculator_catalog` (buida) i les columnes d’origen a `project_lines` i `commercial_document_lines`.
2. Trigger d’immutable a `calculator_versions`.
3. Copiar les columnes noves dins `api.issue_commercial_document` i `api.ensure_project_from_orphan_quote`. Localitzar els `INSERT` actuals (evolució a migracions posteriors a `20261160000001` i `20261245000001`) i reemplaçar la funció sencera a la migració nova, sense perdre la lògica que ja tenen.
4. Exposar les columnes a les vistes `api`. Regenerar `apps/tenant-portal/src/types/database.types.ts` amb el flux de types que ja usa el repo, i copiar el resultat a `supabase/functions/_shared/database.types.ts` (l’Edge `apply-calculator-run` el necessita). No editar cap dels dos fitxers a mà.
5. RPC `api.apply_calculator_lines` tal com la descriu l’esquema. No cridar `apply_price_sheet` ni `apply_pricing_template`.
6. Edge `supabase/functions/apply-calculator-run`: `createUserClient(req)` + `auth.getUser()` per obtenir l’usuari real (patró `invite-member/index.ts`), `run`, hash, i només llavors `createAdminClient()` per cridar la RPC passant `p_actor_user_id`. `calculator_parity_mismatch` no escriu. Detall complet a [`01-schema.md`](./01-schema.md) § RPC i § Edge.
7. Una definició de fixture (electricista amb preus omplerts) inserida per test, no per la UI. Camí mínim per aplicar-la a un projecte i a un document orfe esborrany des del servei del portal (`commercialFlowService`), encara sense formulari polit: n’hi ha prou que un test d’integració o un botó temporal darrere de permís ho exerceixi. Si es fa botó, s’ha de poder treure sense deixar cordes; preferible test SQL + test del servei amb el motor.
8. En aplicar un hàbit (`apply_pricing_template`) i en copiar línies (`copy_project_lines`), estampar `line_origin` `habit` o `copy` a les files noves. Les files velles queden null. No backfill.
9. `log_audit_event` en publicar (la RPC de publicar versió entra aquí, encara que l’editor sigui la fase 4: `api.publish_calculator_version` ha d’existir perquè l’aplicació exigeix versió publicada).

## Regles d’escriptura

- Destí projecte: `data.assert_price_sheet_mutable`. Destí document: només `status = draft` i `project_id` null (orfe). Un document ja emès no es recalcula.
- Re-executar esborra només `line_origin = calculator` del mateix `calculator_definition_id` (D13).
- Preu 0 només amb `allow_zero_price` (D6).
- El mateix `client_op_id` no duplica.
- Permís d’aplicar: `commercial.pricing.edit` (D7). Publicar: owner/manager.

## Tests

Fitxer nou `supabase/tests/commercial_cf29_calculator_tests.sql`, seguint l’estil de `commercial_cf24_v2_orphan_quote_tests.sql`.

- [ ] Tenant A no llegeix ni aplica la definició del tenant B.
- [ ] Aplicar a projecte i a orfe draft crea línies amb origen, versió, key i run.
- [ ] Una línia manual i un hàbit sobreviuen a una segona execució; les línies de la calculadora se substitueixen.
- [ ] Hash distint → cap insert. La RPC és `service_role`; `authenticated` no la pot cridar, l’Edge és l’únic camí (ja decidit a [`01-schema.md`](./01-schema.md) § RPC).
- [ ] Un usuari autenticat sense `commercial.pricing.edit` que crida l’Edge directament (amb un hash vàlid) rep rebuig: test d’integració/Deno de l’Edge, no només SQL, perquè el permís es comprova amb `p_actor_user_id` dins la RPC però l’Edge és qui el deriva del JWT.
- [ ] Emetre un pressupost des del projecte copia les columnes d’origen a `commercial_document_lines`.
- [ ] `ensure_project_from_orphan_quote` les copia cap a `project_lines`.
- [ ] Editar `draft_definition` després de publicar no canvia la versió ni les línies ja escrites.
- [ ] UPDATE d’una versió publicada falla.
- [ ] Document `issued` rebutja l’aplicació.
- [ ] Vitest del client: el hash que calcula el portal sobre els oracles coincideix amb el que l’Edge acceptaria (mateixa funció).

## Acceptació

- [ ] Els tests SQL passen.
- [ ] Un pressupost emès conserva `version_id` i els paràmetres al `calculator_runs` encara que la definició esborrany canviï.
- [ ] Cap ús de `apply_price_sheet` en aquest camí.

## Fora

Editor, biblioteca amb files reals, formulari de paràmetres, flux curt, IA. El catàleg es crea buit.
