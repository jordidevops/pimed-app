# CF-29 — Decisions

> Les fases **no tornen a obrir** aquestes decisions. Segueixen el supòsit de treball.
> Un humà pot canviar un supòsit editant aquest fitxer **abans** de començar la fase que el toca. El canvi s’anota a «Registre» amb data. No s’improvisa al codi.

Cost = ordre de magnitud d’enginyeria, no un pressupost.

## D1 — Destí del flux curt

| Opció | Cost | Risc | És la bona si… |
|-------|------|------|----------------|
| A. Orfe (V2): contacte → línies al document → emetre sense OS | Baix: V2 ja emet | El document 06 està desfasat; el codi sí que emet | El relat és «pressupost abans de la feina» |
| B. Prospecte (C): crea OS `prospect`, línies a `project_lines`, després emet | Baix: C ja existeix | El flux curt crea una OS que l’usuari no ha demanat | Es vol el full de preus ric abans d’enviar |
| C. El tenant tria amb `preferred_entry` | Mitjà | La clau no existeix al codi; només al document 06 | Cal un mode exclusiu per tenant |

**Supòsit de treball:** A. El full de preus (C i order-first) rep el mateix formulari de paràmetres a la fase 6, però no és el camí curt. `preferred_entry` queda fora de l’epic.

## D2 — Servei habitual i calculadora

| Opció | Cost | Risc | És la bona si… |
|-------|------|------|----------------|
| A. Dues fonts, taules separades | Baix | Dos conceptes a la UI | L’hàbit segueix sent pack de catàleg + checklist + PVP viu |
| B. L’hàbit és una calculadora sense paràmetres | Alt | Trenca CF-3/CF-23 (`catalog_item_id` NOT NULL, checklists, PVP viu) | Els tenants no distingeixen els dos un cop usats |

**Supòsit de treball:** A durant tot l’epic. Comparteixen la forma de la línia de sortida i l’adaptador, no la taula. Unificar és un pla posterior.

## D3 — On s’executa el motor

| Opció | Cost | Risc | És la bona si… |
|-------|------|------|----------------|
| A. Paquet TS `packages/price-calculator` importat pel portal (Vite) i per Deno | El monorepo no té workspaces; `packages/ai-schemas` no el consumeix el portal | El cablejat es menja el spike | A importa net en ≤ 2 dies |
| B. Dos mòduls bessons (portal + `supabase/functions/_shared`) i fixtures daurades | Baix, és el patró de l’HTML comercial | Deriva si s’edita un sol costat | A no entra en 2 dies |
| C. Avaluador només SQL | Alt | Latència de previsualització; pitjor encaix amb la IA en TS | A i B no poden garantir els mateixos cèntims |

**Supòsit de treball:** el decideix la fase 0. Es prova A. Si en dos dies el paquet no importa net a Vitest i a Deno, es cau a B. C només si A i B fallen la paritat. Els totals **persistits** segueixen sent `data.line_net` a SQL. El TS només ha de reproduir aquesta fórmula a la previsualització i a l’Edge que aplica.

**Resultat del spike:** _(omplir en tancar la fase 0: A o B, data, què ha fallat)_

## D4 — Model de dades

| Opció | Cost | Risc | És la bona si… |
|-------|------|------|----------------|
| A. Definició + versions immutables, com les checklists | Mitjà | Més taules | Un pressupost antic ha de poder assenyalar la definició que el va generar |
| B. Una fila mutable + snapshot al document | Baix | No hi ha diff honest de «versió nova del catàleg» | No cal reobrir la definició |

**Supòsit de treball:** A. Detall de taules a [`01-schema.md`](./01-schema.md) § Persistència.

## D5 — Avaluador

| Opció | Cost | Risc | És la bona si… |
|-------|------|------|----------------|
| A. Només AST tancat, persistit | Mitjà al constructor (fase 8) | La IA ha d’emetre JSON, no una fórmula | Es vol el mateix límit que el vocabulari de plantilles |
| B. Cadenes (`expr-eval`, mathjs, parser) persistides | Baix d’entrada | `eval` encobert, injecció, esquema que creix sense versió | Cal enganxar Excel com a font de veritat |

**Supòsit de treball:** A al producte. Sense `eval`, sense mathjs. Una cadena només pot existir com a compilador intern (IA o Excel futur) que emet AST; no es desa.

## D6 — Preu zero

`apply_price_sheet` descarta la línia lliure amb `unit_price <= 0`. Un desplaçament inclòs pot ser 0 €.

**Supòsit de treball:** el preu 0 es persisteix només si la línia de la definició té `allow_zero_price: true`. Si no, l’execució falla amb error visible. No es crida `apply_price_sheet`.

## D7 — Qui publica i qui executa

Avui: escriure `pricing_templates` és owner/manager (RLS). Escriure un preu lliure exigeix `commercial.pricing.edit`. El patch de `settings.commercial` exigeix `settings.manage` via `assert_setting_write_access`; la UI a més amaga la secció si el rol no és owner/manager.

**Supòsit de treball:**

- Crear, editar, publicar, activar, arxivar, clonar: rol global owner o manager (mateix patró que les plantilles de preu).
- Executar (aplicar línies): `commercial.pricing.edit`. No s’obre una porta a línies lliures arbitràries per a qui no el té.
- Si més endavant un tècnic ha d’executar sense aquest permís, cal una decisió nova i una RPC que només apliqui versions `active`, no un editor de preus.

Auditoria amb `data.log_audit_event` en publicar, activar, arxivar i clonar. Els errors no van a `audit_logs`.

## D8 — Idiomes de les etiquetes

La UI del portal és ca/es/en (`t('clau', 'Fallback català')`). Al DB el patró multi-idioma real és un jsonb `{ca,es,en}` o files per locale.

**Supòsit de treball:** `label` / `name` de la definició són jsonb amb claus opcionals `ca`, `es`, `en`. Resolució: idioma actiu → `ca` → primera clau no buida. El catàleg de plataforma porta les tres quan es pugui. L’editor del tenant edita l’idioma actiu i pot deixar els altres buits. La UI cromada (botons, estats) va als JSON de locales ca/es/en, no dins la definició.

## D9 — On viuen electricista i persianes

No hi ha taula de verticals. `sector_profiles.archetype` no té `electrician`.

**Supòsit de treball:** les entrades de catàleg porten `target_archetypes: ["field_service"]`. Es mostren als tenants d’aquest arquetip i, si no n’hi ha cap de més específic, també als `generic`. No es crea `industry_verticals` en aquest epic.

## D10 — Vista `total_with_tax`

La vista arrodoneix en un sol pas. L’emissió fa `line_net` i després l’IVA. Poden diferir un cèntim. No s’ha verificat un vector concret en aquest pla: la fase 0 l’ha de trobar a Postgres, o documentar que dins el domini (preus ≥ 0, 2 decimals, IVA 0/4/10/21, quantitat a 3 decimals) no n’hi ha.

**Supòsit de treball:** la previsualització i l’adaptador usen sempre els dos passos de l’emissió. A la fase 1, si el spike troba un vector que divergeix, s’alinea la vista amb els dos passos i un test de regressió. Si no n’hi ha, la vista no es toca.

## D11 — Activar

| Opció | És la bona si… |
|-------|----------------|
| A. N’hi ha prou d’haver obert la previsualització | Es vol fricció mínima |
| B. Cal un cas desat (entrades + línies esperades) que el motor reprodueix | Un preu inventat o una fórmula silenciosa no ha d’arribar a un client |

**Supòsit de treball:** B, per a definicions humanes i de la IA. La previsualització sola no activa.

## D12 — Valors suposats

**Supòsit de treball:** qualsevol preu, percentatge o llindar que no vingui d’una font de l’usuari es desa com a `value: null` i `assumed: true`. Prohibit omplir-lo amb un número plausible. Per activar, el tenant ha d’informar el valor i treure `assumed`. Obrir la pantalla no n’hi ha prou. La biblioteca no porta imports: els forats són `null` sense `assumed` (no hi ha res a «reconèixer», hi ha un buit).

## D13 — Substituir en re-executar

**Supòsit de treball:** esborrar les línies del mateix destí amb `line_origin = 'calculator'` i el mateix `calculator_definition_id`, sigui quina sigui la versió anterior. No tocar `manual`, `habit`, `ai_sheet` ni `copy`. Una versió nova de la mateixa calculadora substitueix el grup anterior.

## D14 — Paritat portal / servidor

**Supòsit de treball:** l’Edge executa el mateix motor que el portal. El client envia un hash de les línies de sortida. Si el servidor calcula un altre hash, no escriu i torna `calculator_parity_mismatch`. El SQL no avalua l’AST al v1 (això només canvia si D3 acaba sent C).

## Registre de canvis de supòsit

| Data | Decisió | Canvi | Qui |
|------|---------|-------|-----|
| 2026-10-14 | — | Supòsits inicials d’aquest document | pla CF-29 |
