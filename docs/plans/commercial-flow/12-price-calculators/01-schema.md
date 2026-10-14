# CF-29 — Esquema v1

Font de veritat de la definició, del motor i de les taules. Les fases 1, 2, 4, 5, 7 i 8 implementen això; no n’inventen un de paral·lel.

`schema_version` és `1`. Una operació nova puja la versió. El validador rebutja claus desconegudes.

## Funció

```text
run(definition, params, locale) -> { lines: OutputLine[], errors: CalcError[] }
```

Pura: no sap si el destí és `project_lines` o `commercial_document_lines`. No llegeix el catàleg ni el tenant. No calcula el total del document.

Si hi ha `errors`, `lines` és buit. No es coageix un error a 0.

## Límits

Tancats a la fase 0 si el spike demostra que calen uns altres; si no, aquests:

| Límit | Valor |
|-------|-------|
| Paràmetres | 30 |
| Constants | 30 |
| Taules | 10 |
| Files per taula | 500 |
| Línies de definició | 40 |
| Profunditat d’AST | 12 |
| Nodes per expressió | 200 |
| Claus | `^[a-z][a-z0-9_]{0,40}$` |

Sense bucles, recursió, referències entre línies, `NOW`, aleatori, regex ni text lliure executable.

## Definicció

```ts
type LocaleMap = { ca?: string; es?: string; en?: string }

type Definition = {
  schema_version: 1
  parameters: Parameter[]
  constants?: Constant[]
  tables?: LookupTable[]
  lines: LineDef[]
}

type Parameter = {
  key: string
  type: "number" | "integer" | "money" | "boolean" | "enum"
  label: LocaleMap
  required?: boolean
  default?: number | string | boolean | null
  min?: number
  max?: number
  unit?: string
  /** Només type=enum. Clau d’una taula lookup=exact. Les opcions són rows[].id */
  options_from?: string
  help?: LocaleMap
}

type Constant = {
  key: string
  type: "number" | "money"
  label?: LocaleMap
  value: number | null
  assumed?: boolean
}

type LookupTable = {
  key: string
  lookup: "exact" | "tier"
  /** Clau d’un paràmetre */
  input: string
  /** lookup=exact. Columna de la fila que es compara amb el paràmetre */
  match_column?: string
  /** lookup=tier. Número, o null a la darrera fila (tram obert) */
  bound_column?: string
  rows: TableRow[]
}

type TableRow = Record<string, number | string | boolean | null | LocaleMap> & {
  assumed?: boolean
}

type LineDef = {
  key: string
  name: LocaleMap
  description?: LocaleMap
  /** Enum real de data.catalog_item_kind. No existeix material ni labor. */
  kind: "product" | "service"
  unit: string
  quantity: Expr
  unit_price: Expr
  discount_pct: Expr
  tax_rate: Expr
  when?: Expr
  /** D6. Sense això, unit_price 0 és error. */
  allow_zero_price?: boolean
}
```

`kind: "service"` amb `unit: "h"` és la mà d’obra. `kind: "product"` és la persiana. El v1 no vincula `catalog_item_id`: la línia generada és lliure. El preu queda congelat a la línia.

## Expressions

```ts
type Expr =
  | { op: "const"; value: number | string | boolean | null }
  | { op: "param"; key: string }
  | { op: "const_ref"; key: string }
  | { op: "add" | "mul" | "min" | "max"; args: Expr[] } // mínim 2
  | { op: "sub" | "div"; left: Expr; right: Expr }
  | { op: "round"; value: Expr; decimals: 0 | 2 | 3; mode: "half_away_from_zero" }
  | { op: "if"; cond: Expr; then: Expr; else: Expr }
  | { op: "cmp"; cmp: "gt" | "gte" | "lt" | "lte" | "eq" | "neq"; left: Expr; right: Expr }
  | { op: "and" | "or"; args: Expr[] }
  | { op: "not"; arg: Expr }
  | { op: "lookup_exact"; table: string; field: string }
  | { op: "lookup_tier"; table: string; price: Expr }
  | { op: "row"; field: string } // només legal dins lookup_tier.price
  | { op: "coalesce"; args: Expr[] }
```

Regles:

- `div` amb divisor 0 → error `division_by_zero`. No retorna 0.
- `lookup_exact` sense fila, o fila amb el camp null → error `lookup_miss` (si el null és un forat de tarifa, el missatge és `tariff_incomplete`).
- `lookup_tier` tria la primera fila amb `input <= bound_column`. La fila amb `bound_column: null` només pot ser l’última i vol dir tram obert. Si cap fila tanca l’entrada → `lookup_miss`.
- `row` fora de `lookup_tier.price` → el validador el rebutja.
- `const_ref` amb `value: null` → `tariff_incomplete` en executar. El validador d’activació també ho bloqueja.
- Comparacions numèriques. `eq` entre nombres és igualtat després de `round` si l’expressió ja és arrodonida; no hi ha epsilon amagat.
- El validador exigeix que `quantity` i `unit_price` acabin en `round` (quantitat decimals 3, preu decimals 2), directament o perquè un `if` té les dues branques arrodonides. `discount_pct` i `tax_rate` s’arrodoneixen a 2 en escriure la línia si l’expressió no ho fa; el valor ha de caure a \[0, 100\].

`when` absent = la línia es genera. `when` fals = s’omet, sense error.

## Sortida

```ts
type OutputLine = {
  key: string
  kind: "product" | "service"
  name: string
  description: string | null
  unit: string
  quantity: string   // decimal canònic, 3 decimals
  unit_price: string // 2 decimals
  discount_pct: string
  tax_rate: string
  allow_zero_price: boolean
}

type CalcError = {
  code:
    | "division_by_zero"
    | "lookup_miss"
    | "tariff_incomplete"
    | "param_missing"
    | "param_out_of_range"
    | "type_error"
    | "limit_exceeded"
    | "zero_price_not_allowed"
  path: string
}
```

El nom es resol amb D8. Els placeholders són `{{param}}` d’un sol nivell (el valor d’enum mostra el `label` de la fila si existeix, si no l’`id`). No són expressions.

## Diners

Igual que l’emissió, no com la vista `project_lines`:

```text
net  = ROUND_HALF_AWAY_FROM_ZERO(quantity * unit_price * (1 - discount_pct/100), 2)
tax  = ROUND_HALF_AWAY_FROM_ZERO(net * tax_rate/100, 2)
total_línia = net + tax
```

`data.line_net(qty, price, disc)` és el primer pas. Postgres `ROUND(numeric, scale)` és meitat lluny de zero. `Math.round` de JS **no** serveix (els negatius no coincideixen, i els floats binaris no representen 1.005). Implementació: enters decimals o una llibreria decimal, la mateixa als dos runtimes. El spike mesura:

- `ROUND(1.005, 2)`, `ROUND(1.004, 2)`, `ROUND(-1.5, 0)` contra Postgres
- descompte 10% sobre preu 100, quantitat 1 → net 90.00
- IVA 21% sobre net 10.01 → impost 2.10
- el vector, si existeix, on `total_with_tax` de la vista ≠ net+tax

La calculadora no suma el document. La previsualització suma nets i impostos amb la mateixa regla que `data.recompute_orphan_quote_totals` (suma de línies ja arrodonides, `tax_breakdown` per tipus).

Moneda: EUR, implícita. Fora del v1.

## Activació

Una definició es pot publicar com a versió immutable en `draft`. Només passa a `active` si tot això és cert:

- cap constant ni cel·la de tarifa amb `value` null o `assumed: true`
- almenys un cas desat el resultat del qual és idèntic al que el motor emet avui (D11)
- el validador no retorna avisos de límits

Estats: `draft` | `incomplete` | `active` | `archived`.

- `incomplete`: hi ha forats, `assumed`, o cap cas verd.
- `archived`: no s’executa; les versions ja emeses es conserven.
- Només `active` amb una versió `published` es pot aplicar al flux.

Publicar copia el JSON a `calculator_versions` i el congela (trigger d’immutable, com les checklists). L’esborrany següent és una versió nova. Els documents apunten a `version_id`, no a l’esborrany.

## Hash de paritat (D14)

Canònic: JSON de `lines` amb claus ordenades, sense espais, UTF-8, SHA-256 en hex. Els decimals són strings ja arrodonits, no numbers JS. El mateix bytes als dos runtimes.

## Exemple A — electricista

Forats de biblioteca: `hour_eur` null. Als tests de la fase 1 s’omple amb 45.

Tram de desplaçament, una sola expressió per a totes les files:

- fins a 10 km → 0
- fins a 30 km → 25
- més enllà → 25 + (km − 30) × 1,2

Hores segons potència: ≤5 → 2 h; ≤15 → 4 h; obert → 8 h.

```json
{
  "schema_version": 1,
  "parameters": [
    {"key": "distance_km", "type": "number", "min": 0, "required": true, "label": {"ca": "Distància", "es": "Distancia", "en": "Distance"}},
    {"key": "power_kw", "type": "number", "min": 0, "required": true, "label": {"ca": "Potència", "es": "Potencia", "en": "Power"}}
  ],
  "constants": [
    {"key": "hour_eur", "type": "money", "value": null, "label": {"ca": "€/hora"}}
  ],
  "tables": [
    {
      "key": "travel",
      "lookup": "tier",
      "input": "distance_km",
      "bound_column": "max_km",
      "rows": [
        {"max_km": 10, "eur_base": 0, "extra_after_km": 0, "eur_per_extra_km": 0},
        {"max_km": 30, "eur_base": 25, "extra_after_km": 0, "eur_per_extra_km": 0},
        {"max_km": null, "eur_base": 25, "extra_after_km": 30, "eur_per_extra_km": 1.2}
      ]
    },
    {
      "key": "labor",
      "lookup": "tier",
      "input": "power_kw",
      "bound_column": "max_kw",
      "rows": [
        {"max_kw": 5, "hours": 2},
        {"max_kw": 15, "hours": 4},
        {"max_kw": null, "hours": 8}
      ]
    }
  ],
  "lines": [
    {
      "key": "travel",
      "when": {"op": "cmp", "cmp": "gt", "left": {"op": "param", "key": "distance_km"}, "right": {"op": "const", "value": 0}},
      "name": {"ca": "Desplaçament"},
      "kind": "service",
      "unit": "u",
      "allow_zero_price": true,
      "quantity": {"op": "round", "decimals": 3, "mode": "half_away_from_zero", "value": {"op": "const", "value": 1}},
      "unit_price": {
        "op": "lookup_tier",
        "table": "travel",
        "price": {
          "op": "round",
          "decimals": 2,
          "mode": "half_away_from_zero",
          "value": {
            "op": "add",
            "args": [
              {"op": "row", "field": "eur_base"},
              {"op": "mul", "args": [
                {"op": "max", "args": [
                  {"op": "const", "value": 0},
                  {"op": "sub", "left": {"op": "param", "key": "distance_km"}, "right": {"op": "row", "field": "extra_after_km"}}
                ]},
                {"op": "row", "field": "eur_per_extra_km"}
              ]}
            ]
          }
        }
      },
      "discount_pct": {"op": "const", "value": 0},
      "tax_rate": {"op": "const", "value": 21}
    },
    {
      "key": "labor",
      "name": {"ca": "Mà d'obra"},
      "kind": "service",
      "unit": "h",
      "quantity": {
        "op": "round",
        "decimals": 3,
        "mode": "half_away_from_zero",
        "value": {"op": "lookup_tier", "table": "labor", "price": {"op": "row", "field": "hours"}}
      },
      "unit_price": {
        "op": "round",
        "decimals": 2,
        "mode": "half_away_from_zero",
        "value": {"op": "const_ref", "key": "hour_eur"}
      },
      "discount_pct": {"op": "const", "value": 0},
      "tax_rate": {"op": "const", "value": 21}
    }
  ]
}
```

Oracles amb `hour_eur = 45` (només fixtures, no la biblioteca):

| distance_km | power_kw | Línies | Net | IVA 21% | Total línia |
|-------------|----------|--------|-----|---------|-------------|
| 0 | 3 | només labor, 2 h × 45 | 90.00 | 18.90 | 108.90 |
| 20 | 3 | travel 25.00 + labor 90.00 | 25.00 i 90.00 | 5.25 i 18.90 | 30.25 i 108.90 |
| 40 | 20 | travel 37.00 (25 + 10×1.2) + labor 8 h × 45 = 360.00 | 37.00 i 360.00 | 7.77 i 75.60 | 44.77 i 435.60 |

## Exemple B — persianes

Preu per m² segons model. Quantitat facturable = unitats × max(mínim m², ample×alt/10000).

```json
{
  "schema_version": 1,
  "parameters": [
    {"key": "model", "type": "enum", "options_from": "models", "required": true, "label": {"ca": "Model"}},
    {"key": "width_cm", "type": "number", "min": 1, "required": true, "label": {"ca": "Amplada"}},
    {"key": "height_cm", "type": "number", "min": 1, "required": true, "label": {"ca": "Alçada"}},
    {"key": "units", "type": "integer", "min": 1, "required": true, "default": 1, "label": {"ca": "Unitats"}}
  ],
  "tables": [
    {
      "key": "models",
      "lookup": "exact",
      "input": "model",
      "match_column": "id",
      "rows": [
        {"id": "pvc", "label": {"ca": "PVC"}, "eur_m2": null, "min_m2": 1},
        {"id": "alumini", "label": {"ca": "Alumini"}, "eur_m2": null, "min_m2": 1}
      ]
    }
  ],
  "lines": [
    {
      "key": "blind",
      "name": {"ca": "Persiana {{model}}"},
      "kind": "product",
      "unit": "m2",
      "quantity": {
        "op": "round",
        "decimals": 3,
        "mode": "half_away_from_zero",
        "value": {
          "op": "mul",
          "args": [
            {"op": "param", "key": "units"},
            {"op": "max", "args": [
              {"op": "lookup_exact", "table": "models", "field": "min_m2"},
              {"op": "div",
                "left": {"op": "mul", "args": [
                  {"op": "param", "key": "width_cm"},
                  {"op": "param", "key": "height_cm"}
                ]},
                "right": {"op": "const", "value": 10000}
              }
            ]}
          ]
        }
      },
      "unit_price": {
        "op": "round",
        "decimals": 2,
        "mode": "half_away_from_zero",
        "value": {"op": "lookup_exact", "table": "models", "field": "eur_m2"}
      },
      "discount_pct": {"op": "const", "value": 0},
      "tax_rate": {"op": "const", "value": 21}
    }
  ]
}
```

Oracles amb `eur_m2` de PVC = 80 (fixture):

| model | width | height | units | Quantitat | Net |
|-------|-------|--------|-------|-----------|-----|
| pvc | 100 | 150 | 2 | 3.000 (1.5 m² × 2) | 240.00 |
| pvc | 50 | 50 | 1 | 1.000 (mínim 1 m²) | 80.00 |

IVA 21%: 50.40 i 16.80.

## Què el v1 no representa

- Una línia per cada finestra (bucle). Es modela amb quantitat, o amb `schema_version` posterior.
- Descompte o recàrrec que depèn de la suma d’altres línies.
- Cost, marge, `project_line_financials`.
- Checklists.
- Règim d’IVA. S’escriu un `tax_rate` numèric.
- Multi-moneda.
- `catalog_item_id` viu. El preu no es reconsulta al catàleg en aplicar.

## Persistència (fase 2)

Esquema `data`. RLS activat. Lectura: membre del tenant actiu. Escriptura de definicions: D7.

### `calculator_definitions`

| Columna | Notes |
|---------|--------|
| id | uuid pk |
| tenant_id | not null |
| name | text |
| description | text null |
| status | `draft` \| `incomplete` \| `active` \| `archived` |
| draft_definition | jsonb, el JSON editable |
| published_version_id | uuid null |
| cloned_from_catalog_id | uuid null |
| cloned_from_catalog_version | int null |
| created_by, created_at, updated_at | |

### `calculator_versions`

| Columna | Notes |
|---------|--------|
| id, definition_id, tenant_id | |
| version_number | int > 0, únic per definició |
| definition | jsonb congelat |
| content_hash | sha256 del JSON canònic |
| published_at, published_by | |
| Trigger | UPDATE/DELETE prohibits |

### `calculator_cases`

| Columna | Notes |
|---------|--------|
| id, definition_id, tenant_id, name | |
| params | jsonb |
| expected_lines | jsonb (OutputLine[]) |
| last_result | `unrun` \| `pass` \| `fail` |

El cas es recalcula en publicar. `active` exigeix almenys un `pass` contra la versió publicada.

### `calculator_runs`

| Columna | Notes |
|---------|--------|
| id, tenant_id, version_id, definition_id | |
| params | jsonb, els que s’han usat |
| destination | `project` \| `document` |
| project_id, document_id | exactament un |
| lines_hash | el hash D14 |
| client_op_id | uuid, únic per tenant (idempotència, com `price_sheet_ops`) |
| created_by, created_at | |

### `calculator_catalog`

Sense `tenant_id`. Escriptura només per migració / service role.

| Columna | Notes |
|---------|--------|
| id, slug únic | |
| target_archetypes | text[] |
| catalog_version | int |
| definition | jsonb (forats null, sense preus reals) |
| is_active | |

Vista `api` de lectura per a qualsevol autenticat, o RPC `list_calculator_catalog`. No es clona per enllaç: el clon copia el JSON i guarda `cloned_from_*`.

### Columnes noves a les dues taules de línies

A `data.project_lines` i `data.commercial_document_lines`:

| Columna | Notes |
|---------|--------|
| line_origin | text null. Null = llegat, es tracta com a manual. Nous: `manual` \| `habit` \| `calculator` \| `ai_sheet` \| `copy` |
| calculator_definition_id | uuid null |
| calculator_version_id | uuid null |
| calculator_line_key | text null |
| source_run_id | uuid null |

`issue_commercial_document` copia aquestes columnes de `project_lines` a les línies del document. `ensure_project_from_orphan_quote` les copia en sentit invers, a més de `source_quote_line_id`.

Les vistes `api.project_lines` i la projecció de línies de document han d’exposar-les. Regenerar `database.types.ts` del portal.

### RPC

`api.apply_calculator_lines(...)` la crida l’Edge, no el navegador directament, perquè el SQL no avalua l’AST (D3 ≠ C).

Entrada: `version_id`, `params`, `project_id` xor `document_id`, `lines` (ja calculades), `lines_hash`, `client_op_id`.

El que comprova el SQL:

- tenant, document esborrany o projecte mutable (`data.assert_price_sheet_mutable` al projecte; a l’orfe, només `draft`)
- permís D7
- versió publicada i definició `active` d’aquest tenant
- hash coincident amb el que l’Edge ha recalculat (l’Edge és qui compara; el SQL desa el hash que l’Edge li passa i rebutja un segon `client_op_id`)
- preu 0 només amb `allow_zero_price`

El que escriu:

- esborra línies del destí amb el mateix `calculator_definition_id` i `line_origin = calculator` (D13)
- insereix les noves amb origen, claus i `source_run_id`
- si el destí és document, `data.recompute_orphan_quote_totals`
- desa `calculator_runs`

Idempotència: el mateix `client_op_id` retorna el run existent sense duplicar línies.

### Edge `apply-calculator-run`

JWT de l’usuari. Carrega la versió, executa `run`, calcula el hash, el compara amb el del client, i crida la RPC amb service role només després de la paritat. Si difereix: `calculator_parity_mismatch`, zero escriptures.

## Excel (només disseny, no s’implementa)

El v1 ja cobreix el que un full d’ofici sol usar: cel·les d’entrada (paràmetres tipats), VLOOKUP/XLOOKUP exacte (`lookup_exact`), trams (`lookup_tier`), aritmètica, IF, ROUND, MIN/MAX, files que es mostren o no (`when`).

Un importador futur compilarien el full a aquest JSON i retornaria la llista de cel·les no representades. No desaria la fórmula Excel. Mapa opcional, ignorat pel motor, permès des de v1 si es vol deixar el forat: `source: { sheet, cell }` en nodes i files. El validador l’ha d’ignorar (clau coneguda, no executable) o rebutjar-lo fins a la fase d’importació. **Supòsit:** al v1 el validador el rebutja. Així no hi ha un camp mort. Quan arribi l’importador, s’afegeix la clau amb `schema_version` 1 encara, documentat com a metadada no executable.

Quedaria fora de l’informe, sense importar-se: VBA, circulars, `INDIRECT`, fulls externs, taules dinàmiques, fórmules de matriu, més d’un full amb efectes laterals, funcions sense op equivalent.
