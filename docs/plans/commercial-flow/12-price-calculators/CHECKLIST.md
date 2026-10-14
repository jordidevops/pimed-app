# CF-29 — Checklist

Marcar en tancar la fase. El detall és al document de la fase. Aquí hi ha la porta, no el procediment.

## Fase 0 — Spike

- [ ] Vitest i Deno, mateixos oracles, decimals com a string
- [ ] D3 escrit (A o B) a [`00-decisions.md`](./00-decisions.md)
- [ ] D10 reproduit (vector 1.236 × 81,00 € amb IVA 21%, divergència d’1 cèntim) i enllaçat a [`00-decisions.md`](./00-decisions.md)
- [ ] Sense UI

## Fase 1 — Motor

- [ ] Validador strict: claus desconegudes, `eval`, profunditat, `round` obligatori a quantitat i preu
- [ ] Electricista i persianes amb preus de fixture; variant null → `tariff_incomplete`
- [ ] Errors visibles: divisió per zero, lookup buit, preu 0 sense permís de la línia
- [ ] Hash idèntic als dos runtimes
- [ ] Totals de previsualització = `line_net` + IVA en dos passos
- [ ] Vista `total_with_tax` alineada als dos passos (D10 ja té vector provat) amb migració i test de regressió

## Fase 2 — Persistència

- [ ] Taules, versions immutables, columnes d’origen, RLS creuada
- [ ] `issue_commercial_document` i `ensure_project_from_orphan_quote` copien l’origen
- [ ] Apply no usa `apply_price_sheet`
- [ ] Re-executar substitueix només el grup de la calculadora
- [ ] Hash distint no escriu; `client_op_id` repetit no duplica
- [ ] Document emès i projecte no mutable rebutgen
- [ ] Tests SQL `commercial_cf29_calculator_tests.sql`
- [ ] Edge deriva `p_actor_user_id` del JWT (no del body) i el permís D7 es comprova amb aquest valor, no amb `auth.uid()`
- [ ] Test (Deno/integració) que un usuari sense `commercial.pricing.edit` rep rebuig cridant l’Edge directament
- [ ] `database.types.ts` regenerat a `apps/tenant-portal` **i** copiat a `supabase/functions/_shared`

## Fase 3 — Flux per defecte

- [ ] Amb defaults, C i V2 no tornen a preguntar formalització ni plantilla
- [ ] «Canviar» afecta només aquell document
- [ ] Sense defaults, el wizard d’avui es conserva
- [ ] Acord: la plantilla per defecte no obliga un pas redundant
- [ ] Recorregut al navegador

## Fase 4 — Editor i casos

- [ ] Taules, paràmetres, etiquetes, `when` sempre/mai/booleà
- [ ] La lògica complexa és només lectura
- [ ] No s’activa amb forats, `assumed` o sense cas pass
- [ ] Publicar congela; un canvi posterior no altera pressupostos ja aplicats
- [ ] Estats draft / incomplete / active / archived
- [ ] Recorregut al navegador, inclosa amplada estreta

## Fase 5 — Biblioteca

- [ ] Dues entrades sense cap preu numèric, arquetip `field_service`
- [ ] Clonar copia; no enllaça; no toca el catàleg
- [ ] El clon neix incomplete i no surt al flux fins a la porta de la fase 4
- [ ] Un altre tenant no veu el clon

## Fase 6 — Formulari i flux ràpid

- [ ] Tercera font al full de preus i a l’orfe
- [ ] Mateixos paràmetres → mateix hash als dos destins
- [ ] Recàlcul respecta manuals i línies generades editades a mà
- [ ] Flux curt: contacte → font → (paràmetres) → emetre orfe, sense crear OS
- [ ] Usa els defaults de la fase 3
- [ ] Sense permís de preus, l’acció no hi és
- [ ] Buit: cap calculadora activa, missatge clar
- [ ] Recorregut al navegador, desktop i mòbil

## Fase 7 — IA

- [ ] Amagada si la IA del tenant està apagada
- [ ] Sortida invalidada no es desa
- [ ] Números nous exigeixen confirmació; si no, null + `assumed`
- [ ] Edició per diff, lot sencer o res
- [ ] No s’activa sense cas pass
- [ ] Sense adjunt Excel
- [ ] Recorregut al navegador amb IA activa i amb IA apagada

## Fase 8 — Lògica

- [ ] Blocs, no caixa de fórmules
- [ ] Tot el que desa ja era AST v1
- [ ] Canviar un bloc recalcula previsualització i casos
- [ ] Cap op nova
- [ ] Recorregut al navegador

## Fora de l’epic (no marcar com a pendent d’aquesta llista)

Importador Excel, verticals, unificar amb servei habitual, descompte de capçalera, multi-moneda, cost/marge, checklists a la calculadora, auto-merge de clons, `preferred_entry`, bucles, dependència entre línies.
