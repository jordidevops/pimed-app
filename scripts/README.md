
# scripts/

Scripts d'utilitat per al projecte. Cada script té el seu propi `package.json` i cal instal·lar les dependències abans de la primera execució.

---

## `generate-docx-seed.mjs`

Genera 28 fitxers DOCX (les mateixes plantilles de document que les HTML de la migració de plantilles), els puja al bucket `document-templates` de Supabase Storage i escriu el SQL a `tmp/seed-docx-templates.sql`.

### Per a què serveix?

`supabase db reset` aplica les migracions (incloent `20260617000001_seed_extra_document_templates.sql`) i crea els registres a la BD (`data.document_templates` + `data.document_template_locales`), però **no pot pujar fitxers binaris a Storage**. Cal executar aquest script per completar el setup: sense els DOCX a Storage, les plantilles apareixerien al llistat però fallarien en intentar generar un document.

### Prerequisits

- Node.js 18+
- Supabase local en marxa (`supabase start`)

### Setup (primera vegada)

```powershell
cd scripts
npm install
```

### Executar (amb pujada a Storage)

```powershell
cd scripts

# 1. Obtenir la service role key del stack local
$env:SUPABASE_SERVICE_ROLE_KEY = ((supabase status --output env 2>$null | Select-String "^SERVICE_ROLE_KEY=").ToString() -split "=", 2)[1].Trim('"')

# 2. Executar l'script
node generate-docx-seed.mjs
```

> **Nota:** `supabase status --output env` imprimeix `SERVICE_ROLE_KEY=eyJ...` (sense prefix `SUPABASE_`). El valor és el JWT clàssic (format `eyJ...`), diferent de la clau `sb_secret_...` que usa l'admin-portal.

### Executar sense pujada (mode offline)

Si no s'especifica la clau, l'script genera els DOCX a disc i el SQL però **no puja res**:

```powershell
node generate-docx-seed.mjs
```

### Fitxers generats

| Destí | Contingut |
|---|---|
| `tmp/docx-seed/*.docx` | 28 fitxers DOCX llestos per obrir/revisar |
| `tmp/seed-docx-templates.sql` | SQL complet DOCX 001-028 |
| `tmp/seed-docx-templates-016-028.sql` | Només plantilles noves (per revisió) |

### Relació amb les migracions

El SQL amb els INSERTs a `data.document_templates` i `data.document_template_locales` viu a **`supabase/migrations/20260617000001_seed_extra_document_templates.sql`** (HTML 001-028, DOCX 001-028, `default_block_mapping`). Ja no és a `seed.sql`.

Per tant:

- `supabase db reset` → crea els registres a la BD ✅
- `node generate-docx-seed.mjs` → puja els fitxers físics a Storage ✅

**Els dos passos són necessaris.** La BD guarda la ruta (`storage_path`), però si el fitxer no existeix a Storage, la generació de documents fallaria.

### Workflow complet de setup local des de zero

```powershell
# Des de l'arrel del projecte
supabase db reset                         # aplica migracions + seed.sql

# Pujar els DOCX a Storage
cd scripts
npm install
$env:SUPABASE_SERVICE_ROLE_KEY = ((supabase status --output env 2>$null | Select-String "^SERVICE_ROLE_KEY=").ToString() -split "=", 2)[1].Trim('"')
node generate-docx-seed.mjs
cd ..
```

### Si s'afegeixen noves plantilles

1. Afegir la definició al array `TEMPLATES` de `generate-docx-seed.mjs`
2. Afegir HTML (i opcionalment DOCX generat) a `20260617000001_seed_extra_document_templates.sql` o crear una migració nova
3. Executar l'script per generar DOCX i pujar-los a Storage
4. Fer `supabase db reset` (o migració incremental en producció)

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
