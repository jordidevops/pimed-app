# Fase 0 — Spike del motor compartit

> **Tall desplegable:** no (només una decisió escrita a [`00-decisions.md`](./00-decisions.md))
> **Schema:** cap
> **Temps:** 1–2 dies. Si passa, es tanca amb B.
> **Depèn de:** res
> **Objectiu:** saber si el portal i Deno executen el mateix TS

## Què es mesura

1. Una funció `lineNet(qty, price, discountPct)` que coincideix amb `data.line_net` i amb `ROUND` de Postgres (meitat lluny de zero), no amb `Math.round`.
2. Un `lookup_tier` mínim.
3. Els dos exemples de [`01-schema.md`](./01-schema.md) amb els preus de fixture (45 €/h, PVC 80 €/m²) i els oracles d’aquella taula.
4. El mateix JSON de sortida (decimals com a string) a Vitest i a `Deno.test`.

No es dissenya UI, ni taules, ni RPC.

## Passos

1. Provar l’opció A de D3: paquet `packages/price-calculator` amb el codi de `lineNet` + tier + `run` dels dos exemples (pot ser un subconjunt del validador; el validador complet és la fase 1).
2. Fer que `apps/tenant-portal` l’importi (alias de Vite o dependència de fitxer) i que un test Deno l’importi. El `deno.json` de `supabase/functions` avui només té un import map npm; no hi ha workspaces.
3. No allargar el cablejat més de dos dies. Si l’import no és net, copiar el mòdul a:
   - `apps/tenant-portal/src/features/commercial/utils/priceCalculator/`
   - `supabase/functions/_shared/price-calculator/`
   i deixar un test que diffi els dos resultats contra la mateixa fixture JSON (opció B).
4. Mesurar Postgres, si hi ha stack local: `ROUND(1.005, 2)`, `ROUND(1.004, 2)`, `ROUND(-1.5, 0)`, i un vector on `api.project_lines.total_with_tax` divergeixi de net+IVA en dos passos. Anotar el resultat a D3 i D10. Si no hi ha Postgres a mà, deixar-ho com a hipòtesi i verificar-ho a la fase 1 amb un test SQL.
5. Escriure el resultat a [`00-decisions.md`](./00-decisions.md) § D3 («Resultat del spike») i al registre si es descarta A.

## Acceptació

- [ ] Vitest (`npm run test:unit` a `apps/tenant-portal`) i `deno test` del fitxer nou passen amb els oracles dels dos exemples.
- [ ] Els decimals de sortida són strings idèntics als dos costats.
- [ ] D3 queda escrit: A o B. D10 queda escrit: vector de divergència, o «no n’hi ha dins el domini provat».
- [ ] Cap pantalla nova.

## Fora

Validador complet, Zod de tota la definició, Edge d’aplicació, migracions.
