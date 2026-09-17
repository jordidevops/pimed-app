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

Implementat a `scripts/generate-commercial-docx-seed.mjs` (cridat també des de `generate-docx-seed.mjs`). **Com i quan pujar els binaris:** [`scripts/README.md`](../../../scripts/README.md). `db reset` crea els registres SQL; Storage s'ha d'omplir a part.

- Helpers `linesTable` / `totalsBlock` / `acceptRejectBlock`; IDs prefix `74`/`75` (plantilles) i `748`/`749` (locales ca/es).
- 5 quotes + 1 albarà × ca/es = 12 fitxers a `platform/docx/commercial/…` (bucket `document-templates`).
- Migració: `20261168000001_commercial_templates_seed_docx.sql`. `html_content` és NULL (constraint DOCX).
- La pujada necessita el JWT `service_role` (`eyJ…`), no el JWT secret. Els scripts el llegeixen de `supabase status` si cal.
- Reutilitza els textos de clàusules de `01-context-and-legal-content.md` (punt de partida, no assessorament jurídic).

## 3. Manteniment

Aquestes plantilles de plataforma són el material de partida perquè els tenants les **clonin** (`api.create_document_template` amb `p_cloned_from_id`) i les editin. No s'espera que un tenant les faci servir sense personalitzar-les (dades fiscals, condicions pròpies) — el contingut de `01-context-and-legal-content.md` és un punt de partida raonable, no un document legal definitiu.
