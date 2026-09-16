# 03 — Repositori de plantilles de plataforma

> **Pla:** [`README.md`](./README.md) · contracte [`01-context-and-legal-content.md`](./01-context-and-legal-content.md) · arquitectura [`02-rendering-architecture.md`](./02-rendering-architecture.md)

## 1. Fase 1 — HTML (QT-3)

Nova migració de seed, p.ex. `supabase/migrations/2026XXXXXXXXXX_commercial_templates_seed_html.sql`, seguint el patró exacte de `20260617000001_seed_extra_document_templates.sql` (plantilles de plataforma: `tenant_id=NULL`, `is_platform_default=true`).

**Prefixos d'ID nous** (per no col·lidir amb els ja usats 70/71/72/73 de RRHH/legal): `76xxxxxx-...` per a `document_templates` de `quote`, `77xxxxxx-...` per a `delivery_note`, `78xxxxxx-...`/`79xxxxxx-...` per als `document_template_locales` corresponents.

### 1.1 Pressupostos (`category='quote'`, `template_type='html'`)

| Arquetip | `target_archetypes` | Locales |
|----------|----------------------|---------|
| Genèric | `NULL` (universal) | ca, es |
| Field service | `['field_service']` | ca, es |
| Workshop / maker | `['workshop_maker']` | ca, es |
| Practice | `['practice']` | ca, es |
| Hospitality | `['hospitality']` | ca, es |

5 files a `document_templates`, 10 files a `document_template_locales`. Contingut segons `01-context-and-legal-content.md` §3 i §3.1.

### 1.2 Albarà (`category='delivery_note'`, `template_type='html'`)

| Arquetip | `target_archetypes` | Locales |
|----------|----------------------|---------|
| Genèric | `NULL` (universal) | ca, es |

1 fila a `document_templates`, 2 files a `document_template_locales`. Contingut segons `01-context-and-legal-content.md` §4. *(Ampliar a arquetips específics només si es demana explícitament — no sobredimensionar.)*

### 1.3 `sample_values`

Cada locale ha de portar `sample_values` amb dades fictícies coherents (client "Client Exemple SL", 2-3 línies amb quantitats/preus/descomptes variats, desglossament d'IVA amb almenys dos tipus diferents, total calculat) perquè la previsualització a `/documents/templates` (QT-4) no aparegui buida.

## 2. Fase 2 — DOCX (QT-6)

Estendre `scripts/generate-docx-seed.mjs` (no reescriure'l):

- Afegir les mateixes 5+1 definicions de plantilla a l'array `TEMPLATES`, amb `template_type: 'docx'`, reutilitzant els helpers existents (`V()`, `B()`, `T()`, `dataRow()`, `infoTable()`, `SIGN_SECTION()`, `H1()`, `H2()`).
- **Helpers nous a afegir** al script:
  - `linesTable(columns)` → genera una `Table` amb una fila de capçalera fixa i una fila de plantilla Docxtemplater dins d'un bloc `[[#lines]] ... [[/lines]]` (concepte, quantitat, preu, descompte, import).
  - `totalsBlock()` → paràgrafs amb `[[totals.subtotal]]`, bucle `[[#totals.tax_breakdown]] ... [[/totals.tax_breakdown]]`, `[[totals.total]]`.
  - `acceptRejectBlock()` → dues columnes simètriques (mateixa amplada `WidthType.DXA`) amb caselles "Accepto"/"Refuso" + línia de signatura + data, per garantir la igualtat visual exigida pel requisit legal.
- Reutilitzar els mateixos textos de clàusules definits a `01-context-and-legal-content.md` (no re-redactar-los).
- IDs amb els prefixos `74xxxxxx-...`/`75xxxxxx-...` (DOCX) diferents dels HTML (`76`/`77`) per evitar col·lisions, seguint el patró ja existent al script (prefixos 72/73 per DOCX vs 70/71 per HTML dels documents de RRHH).
- Executar amb `SUPABASE_SERVICE_ROLE_KEY` contra l'entorn local per pujar els DOCX generats al bucket `document-templates` i generar el SQL de seed corresponent (mateix flux que documenta la capçalera del script).

## 3. Manteniment

Aquestes plantilles de plataforma són el material de partida perquè els tenants les **clonin** (`api.create_document_template` amb `p_cloned_from_id`) i les editin. No s'espera que un tenant les faci servir sense personalitzar-les (dades fiscals, condicions pròpies) — el contingut de `01-context-and-legal-content.md` és un punt de partida raonable, no un document legal definitiu.
