# Fase 1 — Motor, esquema, validador, dos exemples

> **Tall desplegable:** sí, com a llibreria. Cap UI de tenant.
> **Schema:** sí. D10 ja té un vector provat que divergeix (vista `total_with_tax`); cal alinear-la.
> **Depèn de:** fase 0
> **Contracte:** [`01-schema.md`](./01-schema.md)

## Abast

1. Completar `run` i el validador al lloc que hagi triat D3 (paquet únic o els dos bessons).
2. Zod (o l’equivalent ja usat a Deno: el `deno.json` mapeja `zod`) amb `.strict()` a cada node. Claus desconegudes, `eval`, profunditat i límits → error de validació, no d’execució.
3. Fixtures JSON dels dos exemples. Als tests, `hour_eur = 45` i `eur_m2` de PVC = 80. La còpia de biblioteca amb nulls no s’executa: ha de fallar amb `tariff_incomplete`.
4. `previewTotals(lines)` amb net + IVA en dos passos i `tax_breakdown` agrupat per `tax_rate`.
5. D10 ja té un vector real (vegeu `00-decisions.md`): migració que reemplaça el càlcul de `api.project_lines.total_with_tax` pel de dos passos, més test SQL de regressió amb aquest vector.

## Fitxers

- El mòdul triat a la fase 0.
- Tests Vitest al costat del mòdul del portal, patró dels tests existents (`*.test.ts`).
- Test Deno al costat del mòdul `_shared`, patró `supabase/functions/_shared/ai/featurePrompts.test.ts` (`Deno.test`, `assertEquals`).
- Fixtures: `electrician.library.json` (forats null), `electrician.filled.json`, `blinds.library.json`, `blinds.filled.json`, més els casos d’oracle.
- La migració que alinea la vista a `supabase/migrations/` (no editar `20260503000006` si ja ha corregut en algun entorn compartit; preferir una migració nova que faci `CREATE OR REPLACE VIEW`), més el test SQL de regressió amb el vector de D10.

## Casos de test obligatoris

- Els oracles de les dues taules de [`01-schema.md`](./01-schema.md).
- `distance_km = 0` omet la línia de desplaçament.
- `hour_eur` null → `tariff_incomplete`, zero línies.
- Model desconegut → `lookup_miss`.
- Divisor 0 → `division_by_zero`, no 0.
- JSON amb clau `eval`, clau desconeguda, o AST de profunditat 13 → rebuig del validador.
- `row` fora de `lookup_tier.value` → rebuig.
- `quantity` sense `round` a 3 decimals → rebuig.
- Vectors de diners de D3/D10, incloent descompte 10% i IVA sobre 10.01, i el vector de D10 amb divergència provada (quantitat 1.236, preu 81.00, IVA 21%: dos passos 121.15, vista actual 121.14 abans d’alinear-la).
- Els dos runtimes: mateix hash SHA-256 de la sortida canònica.

## Acceptació

- [ ] Els dos exemples omplerts passen. La variant biblioteca (nulls) no s’executa.
- [ ] Portal i Deno emeten les mateixes línies i el mateix hash.
- [ ] La previsualització de totals usa dos passos, no la fórmula d’un sol cop de la vista.
- [ ] Cap ruta ni botó nous al portal.

## Fora

Taules, RPC, editor, IA, formularis.
