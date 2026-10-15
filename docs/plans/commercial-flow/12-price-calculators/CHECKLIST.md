# CF-29 — Checklist

Marcar en tancar la fase. El detall és al document de la fase. Aquí hi ha la porta, no el procediment.

## Fase 0 — Spike

- [x] Vitest i Deno, mateixos oracles, decimals com a string
- [x] D3 escrit (A) a [`00-decisions.md`](./00-decisions.md)
- [x] D10 reproduit (vector 1.236 × 81,00 € amb IVA 21%, divergència d’1 cèntim) i enllaçat a [`00-decisions.md`](./00-decisions.md)
- [x] Sense UI

## Fase 1 — Motor

- [x] Validador strict: claus desconegudes, `eval`, profunditat, `round` obligatori a quantitat i preu
- [x] Electricista i persianes amb preus de fixture; variant null → `tariff_incomplete`
- [x] Errors visibles: divisió per zero, lookup buit, preu 0 sense permís de la línia
- [x] Hash idèntic als dos runtimes
- [x] Totals de previsualització = `line_net` + IVA en dos passos
- [x] Vista `total_with_tax` alineada als dos passos (D10 ja té vector provat) amb migració i test de regressió

## Fase 2 — Persistència

- [x] Taules, versions immutables, columnes d’origen, RLS creuada (`20261259000001`)
- [x] `issue_commercial_document` i `ensure_project_from_orphan_quote` copien l’origen (`20261259000002`)
- [x] Apply no usa `apply_price_sheet` (`api.apply_calculator_lines` + Edge)
- [x] Re-executar substitueix només el grup de la calculadora (codi RPC)
- [x] Hash distint no escriu (Edge); `client_op_id` repetit no duplica (RPC)
- [x] Document emès i projecte no mutable rebutgen (tests SQL)
- [x] Tests SQL `commercial_cf29_calculator_tests.sql` PASS
- [x] Edge deriva `p_actor_user_id` del JWT (no del body) i el permís D7 es comprova amb aquest valor, no amb `auth.uid()`
- [ ] Test (Deno/integració) que un usuari sense `commercial.pricing.edit` rep rebuig cridant l’Edge directament
- [x] `database.types.ts` regenerat a `apps/tenant-portal` **i** copiat a `supabase/functions/_shared`

## Fase 3 — Flux per defecte

- [x] Amb defaults, C i V2 no tornen a preguntar formalització ni plantilla (codi + tests helper)
- [x] «Canviar» afecta només aquell document
- [x] Sense defaults, el wizard d’avui es conserva
- [x] Acord: la plantilla per defecte no obliga un pas redundant
- [ ] Recorregut al navegador

## Fase 4 — Editor i casos

- [x] Taules, paràmetres, etiquetes, `when` sempre/mai/booleà (UI + helpers)
- [x] La lògica complexa és només lectura
- [x] No s’activa amb forats, `assumed` o sense cas pass (`activationGaps` + `canActivateCalculator`)
- [x] Publicar congela; desar sobre `active` → `incomplete` (RPC `save_calculator_draft`)
- [x] Estats draft / incomplete / active / archived
- [ ] Recorregut al navegador, inclosa amplada estreta
- [x] Tests validador d’activació (Deno `activation_test.ts`)

## Fase 5 — Biblioteca

- [x] Dues entrades sense cap preu numèric, arquetip `field_service`
- [x] Clonar copia; no enllaça; no toca el catàleg (`clone_calculator_from_catalog`)
- [x] El clon neix incomplete i no surt al flux fins a la porta de la fase 4
- [x] Un altre tenant no veu el clon (test SQL)
- [ ] Recorregut al navegador

## Fase 6 — Formulari i flux ràpid

- [x] Tercera font al full de preus i a l’orfe (`ApplyCalculatorDialog`)
- [x] Mateixos paràmetres → mateix hash als dos destins (mateix Edge + motor)
- [x] Recàlcul respecta manuals i línies generades editades a mà (trigger demote)
- [x] Flux curt: contacte → calculadora → (paràmetres) → emetre orfe (`CreateQuickQuoteDialog`; hàbit pendent)
- [x] Usa els defaults de la fase 3
- [x] Sense permís de preus, l’acció no hi és
- [x] Buit: cap calculadora activa, missatge clar
- [ ] Recorregut al navegador, desktop i mòbil
- [ ] Font hàbit al flux ràpid (calculadora ja hi és)

## Fase 7 — IA

- [x] Amagada si la IA del tenant està apagada (`AIGenerateAction`)
- [x] Sortida invalidada no es desa (`validateDefinition`)
- [x] Números nous exigeixen confirmació; si no, null + `assumed` (`demoteUnconfirmedTariffNumbers`)
- [x] Edició per diff, lot sencer o res
- [x] No s’activa sense cas pass (porta fase 4 intacta)
- [x] Sense adjunt Excel
- [x] Feature seed `commercial.calculator_definition`
- [ ] Recorregut al navegador amb IA activa i amb IA apagada

## Fase 8 — Lògica

- [x] Blocs, no caixa de fórmules (`CalculatorExprBuilder`)
- [x] Tot el que desa ja era AST v1 (validador + test blank line)
- [x] Canviar un bloc recalcula previsualització (mateix `previewCalculator` de l’editor)
- [x] Cap op nova
- [ ] Recorregut al navegador

## Fora de l’epic (no marcar com a pendent d’aquesta llista)

Importador Excel, verticals, unificar amb servei habitual, descompte de capçalera, multi-moneda, cost/marge, checklists a la calculadora, auto-merge de clons, `preferred_entry`, bucles, dependència entre línies.
