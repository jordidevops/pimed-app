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

**Resultat del spike:** **A** (2026-10-14). Paquet `packages/price-calculator` importat pel portal (alias Vite/Vitest/tsconfig + `file:` dep) i per Deno (`deno.json` + reexport `_shared/price-calculator/mod.ts`). Vitest 6/6 i `deno test` 7/7 amb els mateixos oracles i decimals string.

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

La vista arrodoneix en un sol pas. L’emissió fa `line_net` i després l’IVA en un segon pas. **Ja hi ha un vector provat que divergeix**, dins el domini del v1 (preu 2 decimals, quantitat 3 decimals, IVA 21%): quantitat `1.236`, preu `81,00 €`, descompte `0%`.

- Dos passos (el que fa `issue_commercial_document` i el que farà la calculadora): net = ROUND(1,236 × 81, 2) = `100,12`; IVA = ROUND(100,12 × 0,21, 2) = `21,03` → total `121,15`.
- Un pas (vista `total_with_tax` avui): ROUND(1,236 × 81 × 1,21, 2) = `121,14`.
- Divergeixen 1 cèntim. No és un cas vora: amb quantitat de 3 decimals passa sempre que l’arrodoniment intermedi de `net` canviï el resultat, cosa freqüent.

**Supòsit de treball:** la previsualització i l’adaptador usen sempre els dos passos de l’emissió. La fase 1 no «busca» el vector: l’incorpora com a test obligatori (vegeu [`03-fase-1-motor.md`](./03-fase-1-motor.md)) i **alinea la vista `total_with_tax` als dos passos** amb una migració `CREATE OR REPLACE VIEW` nova més un test de regressió SQL. No es tanca aquesta decisió documentant «no n’hi ha cap dins el domini»: ja se n’ha trobat un.

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

L’Edge no pot confiar en `auth.uid()` dins la RPC si aquesta és `service_role` (D7, fase 2): ha de derivar `user_id` del JWT amb `createUserClient(req).auth.getUser()` (patró de `supabase/functions/invite-member/index.ts`) i passar-lo com a paràmetre explícit `p_actor_user_id` a `api.apply_calculator_lines`, que fa la comprovació de D7 amb aquest valor, no amb `auth.uid()`. Només després crida `createAdminClient()` per escriure.

## D15 — Confirmació de xifres noves proposades per la IA

La fase 7 permet que la IA proposi constants, cel·les de tarifa o línies noves. Un número fals que el model no marqui `assumed` no ha d’arribar a `active`.

**Supòsit de treball:** qualsevol valor numèric (constant, cel·la, llindar) que la IA proposi com a NO `assumed` exigeix una confirmació explícita de l’usuari abans de desar-se — un check «aquest import l’he dit jo», un per número. Si l’usuari no confirma, el valor es desa com `value: null` i `assumed: true`, encara que el model no l’hagi marcat així. El servidor no pot saber «qui ho ha dit»; la UI és l’única frontera que ho sap, i és obligatòria abans de qualsevol desat.

## D16 — Tags de classificació

Totes les calculadores actives són universals: apareixen al full de preus, al composer orfe i al flux ràpid sense distinció (cap pla de restringir-ho per destí). Amb molts tenants creant-ne diverses, cal un filtre de cerca, no una porta d’accés.

**Supòsit de treball:** `tags` és text lliure del tenant (`text[]` a `calculator_definitions`), normalitzat en desar (minúscules, trim, deduplicat), màxim 8 per calculadora. No és vocabulari tancat: no hi ha taula de valors permesos ni pantalla d’administració nova. L’editor (fase 4) suggereix autocompletar amb els tags ja usats pel tenant. Les entrades del catàleg (fase 5) poden portar `tags` opcionals; clonar els copia a la calculadora del tenant, que els pot editar després sense cap víncol amb el catàleg. Els tags viuen fora de `draft_definition` i de la versió immutable: no afecten `schema_version`, el hash (D14) ni els casos (D11). S’usen només per filtrar la llista de gestió (fase 4) i els selectors d’ús (fase 6); mai per restringir on una calculadora pot aplicar-se.

## Registre de canvis de supòsit

| Data | Decisió | Canvi | Qui |
|------|---------|-------|-----|
| 2026-10-14 | — | Supòsits inicials d’aquest document | pla CF-29 |
| 2026-10-14 | D10, D15 | D10 reescrit amb vector provat (deixa de ser una incògnita); D15 afegida (confirmació IA, abans amagada dins fase 7) | revisió CF-29 |
| 2026-10-14 | D16 | Tags de classificació afegits (text lliure normalitzat, heretat del catàleg, només filtre, mai restricció) | revisió CF-29 |
| 2026-10-14 | D3 | Spike tancat amb A: paquet `packages/price-calculator` compartit portal+Deno | implementació CF-29 |
