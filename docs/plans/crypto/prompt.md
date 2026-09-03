# Prompt per a la IA implementadora — Sistema d'Encriptació, Secrets i Rotació de Claus

Tens accés complet al repositori. Aquest prompt cobreix el disseny i la implementació d'un sistema unificat de gestió de secrets i encriptació per a l'aplicació multi-tenant (Supabase + Edge Functions + tenant-portal + admin-portal).

---

## 0. Auditoria prèvia (PRIMER PAS OBLIGATORI)

Abans de dissenyar res, fes una auditoria exhaustiva de com s'encripten i gestionen avui els secrets al codi. Busca i documenta:

### 0.1 Secrets de tenant (BYO — Bring Your Own)
- `tenant_ai_config` / `ai_key_secret_id` — claus d'API de proveïdors IA (OpenAI, Anthropic, Gemini, etc.)
- `tenant_twilio_config` / `auth_token_secret_id` — credencials Twilio SMS/WhatsApp
- `tenant_push_config` / `onesignal_rest_key_secret_id` — OneSignal BYO
- `mcp_api_keys` / `key_hash` — claus MCP (si implementat)
- Qualsevol altre `*_secret_id` o camp que referencïi `vault.secrets`
- Camps que emmagatzemen valors sensibles en clar (revisar si hi ha `api_key text`, `password text`, `token text` sense referència a Vault)

### 0.2 Secrets de plataforma (startup)
- Variables d'entorn a Edge Functions (`Deno.env.get(...)`) que contenen secrets: `RESEND_API_KEY`, `ONESIGNAL_REST_API_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `MCP_API_KEY_SECRET`, etc.
- Secrets a `supabase/config.toml` o `.env` locals
- Qualsevol secret hardcoded o amb fallback en clar al codi

### 0.3 Mecanismes actuals
- Com s'usa `vault.create_secret` / `vault.update_secret` / `vault.decrypted_secrets` (Supabase Vault / pgsodium)
- Quines RPCs existeixen per llegir/escriure secrets (`get_tenant_twilio_credentials_service`, `get_tenant_ai_config_service`, etc.)
- Si hi ha alguna clau mestra (`pgsodium.getkey()`, `app.settings.app_encryption_key`, o similar) i com es gestiona
- Si hi ha algun patró de hashing (HMAC-SHA256 per `mcp_api_keys.key_hash`, etc.) i amb quina clau

### 0.4 Producte de l'auditoria
Generar un document `docs/security/encryption-audit.md` amb:
- Inventari complet de tots els secrets trobats, classificats per tipus (tenant BYO / plataforma / hash) i mecanisme actual (Vault / env var / clar / hash)
- Identificació de gaps: secrets que haurien d'estar al Vault però no hi són, camps en clar que caldria encriptar, RPCs sense validació de `service_role`
- Mapa de dependències: quines Edge Functions llegeixen quins secrets i com

---

## 1. Disseny del sistema unificat

Un cop feta l'auditoria, dissenyar un sistema coherent basat en **dos dominis de secrets** i **una clau mestra per domini**:

### 1.1 Domini 1 — Secrets de tenant (BYO)

Tots els secrets que pertanyen a un tenant específic (`tenant_id` definit):
- Claus API de proveïdors IA (OpenAI, Anthropic, Gemini, Mistral, etc.)
- Credencials Twilio (auth token SMS/WhatsApp)
- OneSignal BYO (REST API key)
- SMTP BYO (si s'implementa: host, port, usuari, password)
- Claus MCP BYO (si aplica)
- Qualsevol altre secret configurat pel tenant

**Clau mestra:** `TENANT_SECRETS_MASTER_KEY` — una clau simètrica (AES-256-GCM o equivalent) gestionada com a secret de plataforma (no accessible als tenants). Tots els secrets de tenant s'encripten amb aquesta clau mestra (o amb claus derivades per tenant via KDF si es vol aïllament per tenant — decidir i justificar).

### 1.2 Domini 2 — Secrets de plataforma (startup)

Secrets que pertanyen a la plataforma, no a cap tenant:
- `RESEND_API_KEY` (email transaccional de la plataforma)
- `ONESIGNAL_APP_ID` + `ONESIGNAL_REST_API_KEY` (push global)
- `MCP_API_KEY_SECRET` (HMAC del servidor MCP)
- `SUPABASE_SERVICE_ROLE_KEY` (gestió interna)
- Claus de signatura JWT si aplica
- Qualsevol altre secret de la infraestructura de la startup

**Gestió:** variables d'entorn de Supabase (secrets d'Edge Functions) per als valors operatius, però amb un registre a BD de quins secrets existeixen, la seva versió, i metadades de rotació (sense emmagatzemar el valor en clar).

### 1.3 Principis de disseny

- **Un sol mecanisme** per a secrets de tenant: Supabase Vault (`vault.secrets`) com a font de veritat. No barrejar Vault + camps en clar + hashing ad-hoc en taules diferents sense consistència.
- **Separació de lectura**: els secrets de tenant només es llegeixen via RPCs `SECURITY DEFINER` amb validació `service_role`. Mai exposats via `api.*` views ni accessibles per `authenticated`.
- **Mínima exposició**: el valor desencriptat només existeix en memòria a l'Edge Function i durant el temps necessari per a la crida al proveïdor. Mai es loga, mai es retorna al client, mai s'emmagatzema en cap cau persistent.
- **Auditoria de lectures**: cada cop que es desencripta un secret de tenant, s'ha de registrar (sense el valor) a una taula d'audit (`secret_access_log`): qui ha llegit, quin secret, quan, des de quina funció.

---

## 2. Model de dades

### 2.1 Registre de secrets de tenant

Revisar si `vault.secrets` ja proporciona prou metadades o cal una taula de wrapper. Si cal wrapper:

```sql
-- Wrapper sobre vault.secrets per a metadades de gestió
CREATE TABLE data.tenant_secret_refs (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  secret_id           uuid NOT NULL,        -- vault.secrets.id
  secret_type         text NOT NULL,        -- 'ai_api_key', 'twilio_auth_token', 'smtp_password', 'onesignal_key', 'mcp_key', ...
  provider            text,                 -- 'openai', 'anthropic', 'twilio', 'resend', 'smtp', ...
  label               text,                 -- nom descriptiu per a l'admin
  key_version         integer NOT NULL DEFAULT 1,
  rotation_status     text NOT NULL DEFAULT 'active'
                      CHECK (rotation_status IN ('active', 'rotating', 'deprecated', 'revoked')),
  last_rotated_at     timestamptz,
  rotation_due_at     timestamptz,          -- si es vol rotació periòdica programada
  created_by          uuid REFERENCES data.profiles(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, secret_type, provider)  -- un sol secret actiu per tipus/proveïdor per tenant
);
```

### 2.2 Registre de secrets de plataforma (metadades, sense valor)

```sql
-- Registre de quins secrets de plataforma existeixen i el seu estat (sense emmagatzemar valors)
CREATE TABLE data.platform_secret_registry (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  secret_key          text NOT NULL UNIQUE,  -- nom de la variable d'entorn: 'RESEND_API_KEY', 'ONESIGNAL_REST_API_KEY', ...
  description         text,
  category            text NOT NULL,         -- 'email', 'push', 'mcp', 'auth', 'ai', ...
  key_version         integer NOT NULL DEFAULT 1,
  rotation_status     text NOT NULL DEFAULT 'active'
                      CHECK (rotation_status IN ('active', 'rotating', 'deprecated')),
  last_rotated_at     timestamptz,
  rotation_due_at     timestamptz,
  rotated_by          text,                  -- email o ID de l'admin que va rotar
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
```

### 2.3 Log d'auditoria d'accés a secrets

```sql
CREATE TABLE data.secret_access_log (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid REFERENCES data.tenants(id) ON DELETE SET NULL,
  secret_type     text NOT NULL,
  provider        text,
  accessed_by_fn  text NOT NULL,     -- nom de l'Edge Function o RPC: 'ai-chat-turn', 'process-notification-queue', ...
  access_reason   text,              -- 'send_sms', 'ai_completion', 'mcp_request', ...
  created_at      timestamptz NOT NULL DEFAULT now()
) PARTITION BY RANGE (created_at);   -- particionat des del principi (pot créixer molt)
```

### 2.4 Taula de rotació (historial)

```sql
CREATE TABLE data.secret_rotation_log (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid REFERENCES data.tenants(id) ON DELETE SET NULL,  -- NULL si és secret de plataforma
  secret_type         text NOT NULL,
  provider            text,
  old_key_version     integer NOT NULL,
  new_key_version     integer NOT NULL,
  rotation_type       text NOT NULL  -- 'manual', 'scheduled', 'emergency', 'master_key_rotation'
                      CHECK (rotation_type IN ('manual', 'scheduled', 'emergency', 'master_key_rotation')),
  initiated_by        text,          -- user_id o 'system'
  completed_at        timestamptz,
  status              text NOT NULL DEFAULT 'in_progress'
                      CHECK (status IN ('in_progress', 'completed', 'failed', 'rolled_back')),
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now()
);
```

---

## 3. RPCs i Edge Functions

### 3.1 RPCs de lectura de secrets (service_role only)

Revisar les RPCs existents (`get_tenant_twilio_credentials_service`, etc.) i unificar-les o complementar-les amb:

- `api.get_tenant_secret(p_tenant_id, p_secret_type, p_provider)` — RPC genèrica que retorna el valor desencriptat d'un secret de tenant. Registra accés a `secret_access_log`. Retorna `null` si no existeix o si `rotation_status != 'active'`.
- Mantenir les RPCs específiques per compatibilitat si ja hi ha codi que les usa, però que internament cridin la genèrica.

### 3.2 RPCs d'escriptura (owner/manager del tenant)

- `api.upsert_tenant_secret(p_tenant_id, p_secret_type, p_provider, p_value, p_label)` — crea o actualitza un secret al Vault. Seguir el patró BEGIN/EXCEPTION per cleanup del Vault si l'INSERT falla (ja existent a `upsert_tenant_twilio_config`). Incrementa `key_version`.
- `api.revoke_tenant_secret(p_tenant_id, p_secret_type, p_provider)` — marca com a `revoked`, no esborra del Vault immediatament (per auditoria).

### 3.3 RPC de rotació manual (admin-portal, service_role)

- `api.rotate_tenant_secret(p_tenant_id, p_secret_type, p_provider, p_new_value)` — procediment atòmic:
  1. Crea nou secret al Vault.
  2. Actualitza `tenant_secret_refs` amb nou `secret_id`, incrementa `key_version`, `rotation_status = 'active'`.
  3. Marca l'antic secret al Vault com deprecated (o esborra si la política ho permet).
  4. Registra a `secret_rotation_log`.

### 3.4 Edge Function `rotate-master-key` (per a rotació de clau mestra)

Dissenyar (no necessàriament implementar a V1) el procediment per rotar `TENANT_SECRETS_MASTER_KEY`:
1. Llegir tots els secrets actius del Vault encriptats amb la clau antiga.
2. Re-encriptar cadascun amb la nova clau.
3. Actualitzar el registre.
4. Marcar la nova clau com a activa.

Documentar el procediment com a runbook, fins i tot si no s'automatitza a V1.

---

## 4. Procediments de rotació

### 4.1 Rotació de secret individual de tenant (freqüent, self-service)

Dissenyar la UX a tenant-portal (`/settings/integrations` o equivalent) per a que el tenant owner/manager pugui:
1. Veure els secrets configurats (tipus, proveïdor, `key_version`, `last_rotated_at`, `rotation_due_at`) — **sense veure el valor**.
2. Actualitzar un secret (introduir nou valor) via `upsert_tenant_secret`.
3. Revocar un secret.
4. Veure l'historial de rotacions (`secret_rotation_log` filtrat per `tenant_id`).

### 4.2 Rotació de secrets de plataforma (admin-portal, poc freqüent)

Dissenyar la UI a admin-portal per a:
1. Veure el registre de secrets de plataforma (`platform_secret_registry`): estat, versió, data de l'última rotació, data prevista de la pròxima.
2. Marcar un secret com a "en rotació" (avís als admins).
3. Registrar la rotació completada (actualitzar `platform_secret_registry`).
4. El valor real es rota manualment als secrets d'Edge Functions de Supabase (Dashboard o CLI) — la taula registra les metadades, no el valor.

**Runbook de rotació de secret de plataforma** (documentar a `docs/security/runbooks/rotate-platform-secret.md`):
```
1. Obtenir el nou valor del secret (ex: nova API key de Resend)
2. Afegir el nou secret a Supabase Edge Functions secrets (Dashboard o CLI) amb nom provisional (ex: RESEND_API_KEY_NEW)
3. Desplegar una versió de l'Edge Function que llegeixi el nou nom
4. Verificar que funciona correctament (smoke test)
5. Eliminar la variable antiga (RESEND_API_KEY)
6. Renombrar RESEND_API_KEY_NEW → RESEND_API_KEY (o actualitzar el codi per usar el nom nou)
7. Actualitzar platform_secret_registry: key_version++, last_rotated_at, rotated_by
8. Registrar a secret_rotation_log
```

### 4.3 Rotació de clau mestra de tenant (`TENANT_SECRETS_MASTER_KEY`)

Documentar com a runbook (`docs/security/runbooks/rotate-master-key.md`) el procediment d'emergència i programat:
- Quan cal (compromís de clau, canvi de proveïdor KMS, política de seguretat).
- Procediment pas a pas (re-encriptar tots els secrets del Vault).
- Finestra de manteniment recomanada.
- Rollback si falla a mitges.
- Verificació post-rotació.

### 4.4 Alertes de rotació

Dissenyar un sistema d'alertes per a secrets que s'apropen a la data de rotació:
- Cron job (pg_cron) que comprova `rotation_due_at < now() + interval '30 days'` a `tenant_secret_refs` i `platform_secret_registry`.
- Genera notificació in-app (i email si cal) als owners del tenant afectat (per secrets BYO) o als admins de la plataforma (per secrets de plataforma).

---

## 5. Preparació per a KMS extern (compliance futur)

### 5.1 Capa d'abstracció (dissenyar ara, implementar quan calgui)

Dissenyar una interfície abstracta per a operacions criptogràfiques que permeti intercanviar el backend sense canviar el codi de negoci:

```typescript
// supabase/functions/_shared/crypto/kms-provider.ts
interface KmsProvider {
  encrypt(plaintext: string, keyRef: string): Promise<{ ciphertext: string; keyVersion: number }>;
  decrypt(ciphertext: string, keyRef: string): Promise<string>;
  generateDataKey(keyRef: string): Promise<{ plaintextKey: string; encryptedKey: string }>;
}

// Implementacions:
// - SupabaseVaultKmsProvider  (actual — pgsodium via Supabase Vault)
// - EnvVarKmsProvider         (secrets simples via env vars, per a plataforma)
// - GcpKmsProvider            (futur — Google Cloud KMS)
// - AwsKmsProvider            (futur — AWS KMS)
// - AzureKeyVaultProvider     (futur — Azure Key Vault)
```

### 5.2 Documentar el camí cap a GCP KMS (o equivalent)

Crear `docs/security/future-kms-migration.md` amb:
- Quan té sentit migrar (compliance SOC2, ISO 27001, clients enterprise, regulació sectorial).
- Diferències entre Supabase Vault (pgsodium, clau gestionada per Supabase) i GCP KMS (clau gestionada pel client, auditoria CloudTrail, HSM, etc.).
- Passos de migració: activar `KmsProvider` abstracte, implementar `GcpKmsProvider`, re-encriptar secrets existents, validar, desactivar Vault per a nous secrets.
- Costos estimats (GCP KMS és ~$0.06/10.000 operacions de xifrat).
- Requisits previs: compte GCP, Service Account amb permisos `cloudkms.cryptoKeyVersions.useToEncrypt/Decrypt`, configuració de keyring per entorn (dev/staging/prod).

---

## 6. Documentació per a futurs desenvolupadors i agents IA

### 6.1 `.cursor/rules/secrets-and-encryption.mdc` (o equivalent)

Crear una regla per a Cursor / agents IA que expliqui les convencions del projecte:

```markdown
# Secrets i Encriptació — Regles obligatòries

## MAI fer això:
- Emmagatzemar valors de secrets (API keys, tokens, passwords) en clar en cap taula de BD
- Retornar valors de secrets desencriptats a respostes HTTP de l'api.* schema
- Logar valors de secrets (ni per debug)
- Usar fallbacks amb valors hardcoded per a secrets en producció
- Crear camps `api_key text`, `password text`, `token text` sense wrapper de Vault

## Sempre fer això:
- Nous secrets de tenant → usar `api.upsert_tenant_secret()` (RPC unificada)
- Llegir secrets de tenant → usar `api.get_tenant_secret()` (service_role only)
- Nous secrets de plataforma → afegir a Supabase Edge Functions secrets + registrar a `platform_secret_registry`
- Documentar el nou secret a `docs/security/encryption-audit.md`

## Patró per a nou tipus de secret de tenant:
1. Afegir `secret_type` al CHECK constraint de `tenant_secret_refs.secret_type`
2. Afegir entrada a `platform_secret_registry` si és secret de plataforma
3. Usar `api.upsert_tenant_secret` per desar, `api.get_tenant_secret` per llegir
4. Registrar accés amb `access_reason` descriptiu
5. Afegir UI a /settings/integrations per que el tenant pugui gestionar-ho

## Rotació:
- Qualsevol canvi de valor d'un secret = rotació, no sobrescriptura directa
- Usar `api.rotate_tenant_secret` per a secrets de tenant
- Seguir el runbook a docs/security/runbooks/ per a secrets de plataforma
```

### 6.2 `docs/security/README.md`

Índex del directori de seguretat amb:
- `encryption-audit.md` — inventari actual de tots els secrets
- `encryption-design.md` — disseny del sistema (aquest pla)
- `runbooks/rotate-platform-secret.md`
- `runbooks/rotate-master-key.md`
- `runbooks/emergency-key-compromise.md` — procediment d'emergència si es compromet una clau
- `future-kms-migration.md`

### 6.3 `docs/security/runbooks/emergency-key-compromise.md`

Procediment per al cas pitjor: compromís d'una clau de tenant o de la clau mestra:
1. Revocar immediatament la clau compromesa (Supabase Dashboard).
2. Notificar els tenants afectats.
3. Re-encriptar tots els secrets afectats amb nova clau.
4. Revisar `secret_access_log` per detectar accessos anòmals.
5. Reportar als tenants si aplica (GDPR: notificació de bretxa en 72h).

---

## 7. Admin-portal — Gestió de secrets i rotació

### 7.1 Pantalla de secrets de plataforma (`/admin/security/secrets`)

- Taula amb totes les entrades de `platform_secret_registry`: nom, categoria, versió, estat, última rotació, propera rotació prevista.
- Botó "Marcar com a rotat" + formulari per registrar rotació (data, qui, notes).
- Badge de color per estat (`active` = verd, `rotating` = groc, `deprecated` = vermell).
- Filtre per categoria i estat.
- Export de l'historial de rotacions (`secret_rotation_log`) per a auditories de compliance.

### 7.2 Pantalla d'activitat global de secrets (`/admin/security/access-log`)

- Taula paginada de `secret_access_log` (cross-tenant, agregada).
- Filtres: tenant, `secret_type`, `accessed_by_fn`, rang de dates.
- Útil per detectar anomalies: un tenant que de sobte fa 10.000 accesos a secrets en 1 hora.
- Alertes configurables: si un `secret_type` es llegeix des d'una funció inesperada → alerta a l'admin.

### 7.3 Vista per tenant a l'admin-portal

- Des de la fitxa d'un tenant: llista de secrets configurats (tipus, proveïdor, versió, estat) — sense valors.
- Poder revocar un secret de tenant des de l'admin (en cas de compromís o abús).
- Historial de rotacions del tenant.

---

## 8. Entregables esperats

1. **`docs/security/encryption-audit.md`** — inventari complet de l'estat actual.
2. **Migracions SQL** (`YYYYMMDD_secret_management_core.sql`):
   - `data.tenant_secret_refs`
   - `data.platform_secret_registry` (amb seed de tots els secrets de plataforma identificats a l'auditoria)
   - `data.secret_access_log` (particionada)
   - `data.secret_rotation_log`
   - RPCs: `api.get_tenant_secret`, `api.upsert_tenant_secret`, `api.revoke_tenant_secret`, `api.rotate_tenant_secret`
   - Cron job d'alertes de rotació
3. **Refactors de codi** per unificar secrets existents sota el nou sistema (si cal — prioritzar els que no segueixen el patró).
4. **`supabase/functions/_shared/crypto/kms-provider.ts`** — interfície abstracta + implementació `SupabaseVaultKmsProvider`.
5. **Documentació de seguretat** (`docs/security/` complet).
6. **Regla Cursor** (`.cursor/rules/secrets-and-encryption.mdc`).
7. **UI admin-portal** — pantalles de gestió de secrets i access log.
8. **Seed de `platform_secret_registry`** amb tots els secrets de plataforma identificats a l'auditoria (sense valors, només metadades).
9. **Resum de decisions** — especialment: si s'usa clau mestra única per a tots els secrets de tenant o claus derivades per tenant (KDF), i justificació.