Explica'm el funcionament de les firmes amb DocuSeal. Què fa la Edge Function: sign-document-router? Gestiona tant les pujades del docx com els events enviats per DocuSeal? Tindrem api keys per i webhook url per local, staging i prod mentre que a DocuSeal tenim api key normal i test mode. Està contemplat amb DOCUSEAL_API_KEY DOCUSEAL_API_URL i els .env de cada entorn?


Ara tinc tot el context necessari. Aquí tens l'explicació completa:

---

# Flux de firmes amb DocuSeal

## Les dues funcions Edge NO fan el mateix

| | [sign-document-router](cci:9://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/sign-document-router:0:0-0:0) | [docuseal-webhook](cci:9://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/docuseal-webhook:0:0-0:0) |
|---|---|---|
| **Qui la crida** | El teu frontend (tenant-portal) | DocuSeal (servidor extern) |
| **Auth** | `verify_jwt = true` — requereix JWT d'usuari | `verify_jwt = false` — endpoint públic, però verificat per HMAC |
| **Responsabilitat** | Inici del procés de signatura | Recepció d'events del cicle de vida |

---

## [sign-document-router](cci:9://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/sign-document-router:0:0-0:0) — Orquestrador d'inici

Fa **tot el flux d'enviament** en seqüència:

1. **Valida body** (`tenant_id`, `action`, `source_type`, `signers`)
2. **Autentica** l'usuari (JWT) i comprova que és membre actiu (no viewer)
3. **Feature flag** `tenant_signing_enabled` — si el tenant no està al rollout → 403
4. **Localitza el fitxer font** al Storage:
   - `source_type=document_existing` → agafa el fitxer de la taula `active_documents` (bucket `documents`)
   - `source_type=template_locale` → agafa el fitxer de `document_template_locales` (bucket `document-templates`)
5. **Idempotència** — si ja existeix una `signing_submission` amb el mateix `external_id`, retorna la mateixa resposta sense repetir res
6. **Resol la clau DocuSeal** (veure secció de modes)
7. **Consumeix crèdit** atòmic (via RPC, si mode `platform`)
8. **Crea `signing_submission`** a la BD (`status=pending`)
9. **Descarrega el fitxer** de Storage (Uint8Array)
10. **Envia a DocuSeal** via `POST /submissions/docx` o `/submissions/pdf` (multipart) → rep `docuseal_submission_id` + `signing_url`
11. **Actualitza la submission** a `status=in_progress` amb els IDs de DocuSeal

> **El DOCX no es converteix aquí**: DocuSeal accepta DOCX directament, i ell mateix gestiona la renderització i firma.

---

## [docuseal-webhook](cci:9://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/docuseal-webhook:0:0-0:0) — Receptor d'events asíncrons

DocuSeal notifica cada canvi d'estat. La funció:

1. **Verifica HMAC-SHA256** (`X-DocuSeal-Signature`) — rebutja amb 401 si no coincideix
2. **Localitza la submission** per `external_id`
3. **Registra l'event** via `append_signing_event` (RPC idempotent per `webhook_event_id`)
4. **Actualitza snapshot de signants** (`signers` JSONB)
5. Si event = `submission.completed`:
   - Descarrega el PDF firmat de la URL que dóna DocuSeal
   - El puja al bucket `documents` → `{tenant_id}/signed/{submission_id}.pdf`
   - Crea una nova `document_version` al DMS
   - Vincula el `result_document_version_id` a la submission

---

## Modes de clau DocuSeal

```
tenant_signing_config.mode = 'platform'  →  usa DOCUSEAL_API_KEY (env var)
tenant_signing_config.mode = 'byo'       →  llegeix del Supabase Vault via
                                             get_docuseal_key_for_signing RPC
```

La columna `docuseal_api_url` a `tenant_signing_config` permet que cada tenant (o l'entorn) apunti a una instància diferent (cloud vs. self-hosted).

---

## Gestió de variables per entorn

```@c:\JordiDevops\windsurf-app-supabase\supabase\functions\.env.example:57-73
# DocuSeal — Document Signing System
DOCUSEAL_API_KEY=
DOCUSEAL_API_URL=https://api.docuseal.eu
DOCUSEAL_WEBHOOK_SECRET=
```

El disseny actual és:

| Entorn | `DOCUSEAL_API_KEY` | `DOCUSEAL_API_URL` | `DOCUSEAL_WEBHOOK_SECRET` |
|---|---|---|---|
| **Local** | [.env.local](cci:7://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/.env.local:0:0-0:0) | [.env.local](cci:7://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/.env.local:0:0-0:0) (pot ser self-hosted) | [.env.local](cci:7://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/.env.local:0:0-0:0) |
| **Staging** | Supabase Vault Secret | Supabase Vault Secret | Supabase Vault Secret |
| **Prod** | Supabase Vault Secret | Supabase Vault Secret | Supabase Vault Secret |

> Per staging/prod: `supabase secrets set DOCUSEAL_API_KEY=xxx --project-ref <ref>`

---

## El problema del test mode de DocuSeal

Aquí hi ha **un gap real no cobert**: DocuSeal té mode test (`https://api.docuseal.eu` amb API key de test) però el codi actual **no té cap variable ni lògica per distingir-ho**. Ara mateix passa una de dues:

- Staging i prod comparteixen `DOCUSEAL_API_KEY` → ❌ risc de documents reals a staging
- Cadascú té la seva key → funciona, però no hi ha res que ho faci explícit

**La solució recomanada** és afegir:
```
DOCUSEAL_API_KEY=<key-de-test-docuseal>    # al Vault de staging
DOCUSEAL_API_URL=https://api.docuseal.eu  # mateixa URL, diferent key (DocuSeal usa la key per determinar si és test)
DOCUSEAL_API_KEY=<key-real>               # al Vault de prod
```

DocuSeal **distingeix test mode per la API key**, no per URL separada. Vols que afegeixi una anotació explícita a [.env.example](cci:7://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/.env.example:0:0-0:0) i al [config.toml](cci:7://file:///c:/JordiDevops/windsurf-app-supabase/supabase/config.toml:0:0-0:0) per documentar-ho, o que implementem algun camp addicional a la BD (`is_test_mode` a `tenant_signing_config`)?





Ara explica'm les taules que s'utilitzen per gestionar les firmes i els seus estats.


Ara tinc tot el context. Aquí tens l'explicació completa del model de dades de firmes.

---

# Taules de gestió de firmes

Totes viuen a l'schema `data.*`. L'accés des del client passa sempre per vistes `api.*` que filtren camps sensibles.

---

## 1. `data.tenant_signing_config` — Configuració DocuSeal per tenant

Relació 1:1 amb `data.tenants`.

| Columna | Tipus | Descripció |
|---|---|---|
| `tenant_id` | PK | Clau estrangera al tenant |
| `mode` | ENUM `platform\|byo` | **platform** = usa la key de l'entorn / **byo** = key pròpia al Vault |
| `signing_credits` | integer ≥ 0 | Crèdits disponibles en mode platform |
| `docuseal_key_secret_id` | uuid | UUID opac de `vault.secrets` — **mai visible al client** |
| `docuseal_api_url` | text | URL de l'API DocuSeal (cloud o self-hosted) |
| `is_active` | boolean | Si la signatura digital està habilitada |

> La vista `api.tenant_signing_status` **exclou deliberadament** `docuseal_key_secret_id`. El client mai pot veure ni endevinar la clau BYO.

---

## 2. `data.document_templates` — Plantilles documentals

Patró idèntic a `email_templates`: XOR estricte entre plataforma i tenant.

| Columna | Descripció |
|---|---|
| `tenant_id IS NULL` + `is_platform_default = true` | Plantilla de plataforma (llegida per tots) |
| `tenant_id IS NOT NULL` + `is_platform_default = false` | Plantilla del tenant |
| `cloned_from_id` | Si ve d'un clone d'una plantilla plataforma |

---

## 3. `data.document_template_locales` — Fitxers per idioma

Constraint `UNIQUE (template_id, locale)`.

| Columna | Descripció |
|---|---|
| `storage_path` | Ruta al bucket `document-templates` |
| `mime_type` | Restringit a DOCX o PDF |
| `variables_schema` | JSON `{key: {type, label, required, default}}` — guia el formulari de l'orchestrator |
| `sample_values` | Valors d'exemple per preview |

---

## 4. `data.signing_submissions` — Cicle de vida complet

La taula central. Una fila per cada enviament a signar o generació.

### Estats (ENUM `signing_submission_status`)

```
draft → pending → in_progress → completed
                             → declined
                             → expired
                             → cancelled
                             → error
```

| Estat | Quan s'estableix |
|---|---|
| `draft` | Valor inicial per defecte |
| `pending` | [sign-document-router](cci:9://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/sign-document-router:0:0-0:0) crea la fila just abans d'enviar a DocuSeal |
| `in_progress` | DocuSeal ha acceptat la submission (tenim `docuseal_submission_id`) |
| `completed` | Webhook `submission.completed` rebut i PDF adjuntat |
| `declined` | Un signant ha rebutjat |
| `expired` | DocuSeal notifica expiració |
| `error` | Error a DocuSeal o al webhook |

### Camps clau d'idempotència

| Columna | Índex | Per a |
|---|---|---|
| `external_id` | UNIQUE parcial (NOT NULL) | La nostra clau idempotent enviada a DocuSeal (`client_request_id` o UUID auto) |
| `docuseal_submission_id` | UNIQUE parcial (NOT NULL) | ID que ens retorna DocuSeal — evita duplicats de webhook |

### Columnes de font i resultat

```
source_document_version_id ──► document existent al DMS
source_template_locale_id  ──► locale d'una plantilla
result_document_version_id ──► document_version creat quan la firma es completa
```

### `signers` (JSONB snapshot)

```json
[{
  "email": "...",
  "name": "...",
  "role": "Signer 1",
  "status": "pending|completed|declined",
  "signing_url": "https://docuseal.eu/s/...",
  "completed_at": "..."
}]
```
S'actualitza en cada event de webhook.

---

## 5. `data.signing_events` — Timeline append-only

Una fila per cada event rebut. **Mai s'esborren ni s'actualitzen.** L'usuari autenticat pot llegir, però **mai inserir directament** (no hi ha política INSERT per `authenticated`).

| Columna | Descripció |
|---|---|
| `event_type` | `form.viewed`, `form.started`, `form.completed`, `submission.completed`, etc. |
| `event_source` | ENUM `webhook\|system\|user` |
| `webhook_event_id` | Clau de dedup: `{event_type}:{ds_id}:{uuid}` — UNIQUE parcial |
| `status_before` / `status_after` | Transició d'estat en aquell event |
| `payload` | JSONB complet de DocuSeal |

---

## Visió global del flux amb les taules

```
Frontend
  └── sign-document-router
        ├── LLEGEIX   tenant_signing_config (mode, credits, is_active)
        ├── LLEGEIX   document_template_locales / active_documents
        ├── CREA      signing_submissions (status=pending)
        ├── DECREMENT signing_credits (si platform)
        └── UPDATE    signing_submissions (status=in_progress + docuseal_submission_id)

DocuSeal ──► docuseal-webhook
               ├── CREA     signing_events (idempotent per webhook_event_id)
               ├── UPDATE   signing_submissions (status, signers snapshot)
               └── si completed:
                     ├── Descarrega PDF
                     ├── Puja a Storage
                     ├── Crea document_versions
                     └── UPDATE signing_submissions (result_document_version_id)
```



Dius tenant_signing_config.mode = 'byo'       →  llegeix del Supabase Vault via
                                             get_docuseal_key_for_signing RPC
Què guardem a Vault? La key de cada tenant i webhook url? Com recupera cada tenant la seva? És millor vault que una taula amb valors encriptats?

Ara tinc el codi complet. Aquí tens l'explicació detallada.

---

# Supabase Vault per a la clau DocuSeal BYO

## Què guardem exactament al Vault

**Una sola cosa per tenant: la API key de DocuSeal** (text pla, però xifrat en repòs per Vault).

```@c:\JordiDevops\windsurf-app-supabase\supabase\migrations\20260522000001_dms_templates_signing_core.sql:1122-1123
v_secret_name := 'docuseal_' || replace(p_tenant_id::text, '-', '');
v_secret_desc := 'DocuSeal BYO API key for tenant ' || p_tenant_id::text;
```

- **Nom del secret**: `docuseal_<tenant_uuid_sense_guions>` → identificable al dashboard
- **Valor**: la API key de DocuSeal del tenant (`dsl_XXXX...`)
- **La `docuseal_api_url`** del tenant **no va al Vault** — és text no sensible i viu a `tenant_signing_config.docuseal_api_url`

**El webhook secret** (`DOCUSEAL_WEBHOOK_SECRET`) tampoc va al Vault per tenant: és **una sola clau global de l'entorn**, perquè DocuSeal fa servir una URL de webhook única per tota la plataforma, no per tenant. Les submissions es fan routing per `external_id`.

---

## Com funciona la cadena de recuperació

```
tenant_signing_config
  ├── docuseal_key_secret_id = "uuid-opac-del-vault"   ← mai al client
  └── docuseal_api_url       = "https://api.docuseal.eu"  ← sí al client

vault.secrets (xifrat AES-256-GCM)
  └── id = "uuid-opac-del-vault"
      secret = "dsl_xxxxx..."  ← desxifrat únicament per la funció SECURITY DEFINER
```

**Flux BYO en [sign-document-router](cci:9://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/sign-document-router:0:0-0:0)**:

```
1. Edge function crida userClient.rpc('get_docuseal_key_for_signing', {p_tenant_id})
2. RPC (SECURITY DEFINER, SET search_path = data, vault):
   a. Comprova que l'usuari és owner/manager del tenant
   b. Llegeix docuseal_key_secret_id de tenant_signing_config
   c. SELECT decrypted_secret FROM vault.decrypted_secrets WHERE id = secret_id
   d. Retorna la key en text pla → NOMÉS a la Edge Function
3. Edge Function usa la key per a la crida a DocuSeal API
4. La key mai toca el client browser
```

---

## Com es guarda la key (RPC `save_tenant_docuseal_config`)

```@c:\JordiDevops\windsurf-app-supabase\supabase\migrations\20260522000001_dms_templates_signing_core.sql:1131-1145
IF v_existing.docuseal_key_secret_id IS NOT NULL THEN
  PERFORM vault.update_secret(
    v_existing.docuseal_key_secret_id, p_api_key, ...
  );
  v_secret_id := v_existing.docuseal_key_secret_id;
ELSE
  v_secret_id := vault.create_secret(p_api_key, v_secret_name, v_secret_desc);
END IF;
```

- **Primera vegada**: `vault.create_secret()` → retorna un UUID, que es guarda a `tenant_signing_config.docuseal_key_secret_id`
- **Actualització**: `vault.update_secret()` → reaprofita el mateix UUID del Vault, simplement actualitza el valor xifrat
- El frontend envia la clau via PostgREST → RPC → Vault. La clau **mai queda loguejada** ni en taules auditables (el log d'auditoria només registra el `mode`, no la key)

---

## Vault vs. columna xifrada a la BD — Comparativa real

| Criteri | **Supabase Vault** | **Columna `pgcrypto` / `aes_encrypt`** |
|---|---|---|
| **Qui gestiona el xifrat** | Supabase (pgroonga extension), clau AES gestionada per ells | Tu (has de gestionar la clau de xifrat, rotar-la, etc.) |
| **Visibilitat accidental** | `vault.secrets` no és accessible per `authenticated` per defecte | Una columna mal configurada pot quedar exposada per PostgREST |
| **Lectura** | `vault.decrypted_secrets` → requereix `SECURITY DEFINER` explícit | Qualsevol `SELECT` si tens accés a la taula |
| **Rotació de clau** | Gestionada per Supabase | Manual, has de re-xifrar totes les files |
| **Auditoria d'accés** | No built-in (has de logar tu) | Igual |
| **Multi-tenant** | Un secret per tenant, UUID opac a la taula del tenant | Risc que una query mal feta retorni keys de múltiples tenants |
| **Complexitat** | Baixa: `vault.create_secret()` / `vault.decrypted_secrets` | Alta: gestió de keys, IV, padding |

**La tria de Vault és la correcta** per aquest cas perquè:
1. Cada tenant té el seu secret aïllat per UUID opac
2. La key mai pot sortir de `SECURITY DEFINER` — és estructuralment impossible via PostgREST directe
3. No cal gestionar la clau de xifrat manualment
4. El dashboard de Supabase permet veure/rotar secrets sense tocar el codi

---

## Resum de la distribució de secrets per entorn

| Secret | On viu | Per qui |
|---|---|---|
| `DOCUSEAL_API_KEY` (platform) | [.env.local](cci:7://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/.env.local:0:0-0:0) / Supabase Vault Secrets | Plataforma (compartit tots els tenants platform) |
| `DOCUSEAL_API_URL` (platform) | [.env.local](cci:7://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/.env.local:0:0-0:0) / Vault Secrets | Plataforma |
| `DOCUSEAL_WEBHOOK_SECRET` | [.env.local](cci:7://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/.env.local:0:0-0:0) / Vault Secrets | Global (una URL de webhook per instància) |
| `docuseal_key_{tenant_id}` | `vault.secrets` (xifrat a DB) | Un per cada tenant BYO |