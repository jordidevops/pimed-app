
# scripts/

Scripts d'utilitat per al projecte. Cada script té el seu propi `package.json` i cal instal·lar les dependències abans de la primera execució.

---

## `generate-docx-seed.mjs`

Genera i puja els DOCX de plataforma al bucket `document-templates`. N'hi ha **dos grups**:

| Grup | Script | Quants | Migració SQL (registres a BD) |
|---|---|---:|---|
| RRHH / legal / operacions / PRL / firma | `generate-docx-seed.mjs` | 28 | `20260617000001_seed_extra_document_templates.sql` |
| Pressupost / albarà (cos complet) | `generate-commercial-docx-seed.mjs` | 12 (5 quotes + 1 albarà × ca/es) | `20261168000001_commercial_templates_seed_docx.sql` |

`node generate-docx-seed.mjs` **també crida** el generador comercial al final. Per pujar **només** els comercials: `node generate-commercial-docx-seed.mjs`.

### Per a què serveix?

`supabase db reset` aplica les migracions i crea els registres a la BD (`data.document_templates` + `data.document_template_locales` amb `storage_path`), però **no pot pujar fitxers binaris a Storage**. Sense els DOCX al bucket, les plantilles es veuen al catàleg però fallen clonació, preview i generació (`Object not found`).

**Quan cal pujar-los**

- Després de cada `supabase db reset` (o stack local nou).
- Quan canvies el contingut d'una plantilla DOCX de seed i vols actualitzar Storage (`x-upsert: true` pisa el fitxer).
- No cal a cada arrencada si Storage ja té els objectes.

HTML de plataforma (inclosos pressupost/albarà QT-3) **no** passa per aquest script: el cos va a `html_content` a la migració.

### Prerequisits

- Node.js 18+
- Supabase local en marxa (`supabase start`)
- JWT **service_role** (`eyJ…`), no el JWT secret (hex). El secret provoca `403 Invalid Compact JWS`.

Els scripts llegeixen el JWT de `SUPABASE_SERVICE_ROLE_KEY` si és un JWT, o de `supabase status -o json` si no.

### Setup (primera vegada)

```powershell
cd scripts
npm install
```

### Executar (amb pujada a Storage)

```powershell
cd scripts
node generate-docx-seed.mjs
```

> **Nota:** `supabase status --output env` imprimeix `SERVICE_ROLE_KEY=eyJ...` (sense prefix `SUPABASE_`). El valor és el JWT clàssic (format `eyJ...`), diferent de la clau `sb_secret_...` i del JWT secret hex. Si vols forçar-lo a l'entorn:
>
> ```powershell
> $env:SUPABASE_SERVICE_ROLE_KEY = ((supabase status --output env 2>$null | Select-String "^SERVICE_ROLE_KEY=").ToString() -split "=", 2)[1].Trim('"')
> ```

### Executar sense pujada (mode offline)

Si no hi ha JWT (CLI aturat i cap env), l'script genera els DOCX a disc i el SQL però **no puja res**.

### Fitxers generats

| Destí | Contingut |
|---|---|
| `tmp/docx-seed/*.docx` | 28 DOCX RRHH/legal/… |
| `tmp/docx-seed/commercial/*.docx` | 12 DOCX pressupost/albarà |
| `tmp/seed-docx-templates.sql` | SQL DOCX 001-028 |
| `tmp/seed-docx-templates-016-028.sql` | Només plantilles noves (per revisió) |
| `tmp/seed-commercial-docx-templates.sql` | Còpia del SQL comercial (la migració canònica és `20261168000001_…`) |

Rutes a Storage: `platform/docx/…` (RRHH) i `platform/docx/commercial/…` (quote/delivery_note).

### Relació amb les migracions

El SQL amb els INSERTs viu a les migracions, no a `seed.sql`.

Per tant:

- `supabase db reset` → crea els registres a la BD ✅
- `node generate-docx-seed.mjs` → puja RRHH **i** comercials a Storage ✅

**Els dos passos són necessaris.** La BD guarda la ruta (`storage_path`); si el fitxer no existeix a Storage, preview/clonació/generació fallen.

### Workflow complet de setup local des de zero

```powershell
# Des de l'arrel del projecte
supabase db reset                         # aplica migracions + seed.sql

# Pujar els DOCX a Storage (RRHH + comercials)
cd scripts
npm install
node generate-docx-seed.mjs
cd ..
```

### Si s'afegeixen noves plantilles

**RRHH / legal / …**

1. Afegir la definició a l'array `TEMPLATES` de `generate-docx-seed.mjs`
2. Afegir HTML (i opcionalment DOCX generat) a `20260617000001_seed_extra_document_templates.sql` o crear una migració nova
3. Executar l'script per generar DOCX i pujar-los a Storage
4. Fer `supabase db reset` (o migració incremental en producció)

**Pressupost / albarà**

1. Afegir l'entrada a `generate-commercial-docx-seed.mjs` (no al array RRHH)
2. Regenerar: `node generate-commercial-docx-seed.mjs` (actualitza `20261168000001_commercial_templates_seed_docx.sql` i Storage)
3. El text legal és un punt de partida per clonar, no assessorament jurídic

---

## `verify-phase0-observability.mjs`

Comprova que els endpoints de monitorització (REST + `health?check=live|ready`) responen correctament.

```powershell
# Només local (Supabase dev en marxa)
node scripts/verify-phase0-observability.mjs

# Amb entorns cloud (omplir refs i URLs)
$env:STAGING_REF = "<staging-ref>"
$env:PROD_REF = "<prod-ref>"
$env:TENANT_PORTAL_URL_STAGING = "https://..."
node scripts/verify-phase0-observability.mjs
```

Guia de configuració manual (UptimeRobot, Sentry, alertes Supabase): [`docs/runbooks/fase-0-manual-setup.md`](../docs/runbooks/fase-0-manual-setup.md)

---

## `test-operations-flow-e2e.mjs`

E2E API del flux `tenant_operation_logs` + RPCs UI (Operacions). Veure el fitxer per ús.
