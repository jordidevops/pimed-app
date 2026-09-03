# Auditoria de secrets i encriptació

**Data:** 2025-06-25  
**Abast:** Inventari pre-implementació del sistema unificat de secrets (`docs/plans/crypto/plan.md`)

---

## Resum executiu

L'aplicació protegeix credencials d'integració mitjançant **Supabase Vault**. El **field-level PII** (IBAN + NSS) usa envelope encryption: DEK per tenant (`tenant_field_dek`) al Vault + ciphertext EtM (AES+HMAC) a `employee_private_profiles`. **`pgcrypto`** també s'usa per a tokens i hashes d'integritat.

**Gaps tancats (V1 secrets):** `tenant_webhooks.secret` i `api_key_secret_ref` migrats a Vault. Inventari centralitzat a `tenant_secret_refs`.

**Field PII (20261128):** IBAN + NSS xifrats; vista API sense plaintext ni ciphertext; reveal auditat.

---

## 1. Secrets de tenant (BYO)

| Taula | Columna Vault | Tipus | secret_type (nou) | provider |
|-------|---------------|-------|-------------------|----------|
| `data.tenant_ai_provider_config` | `ai_key_secret_id` | API key IA | `ai_api_key` | `openai`, `anthropic`, etc. |
| `data.tenant_twilio_config` | `auth_token_secret_id` | Auth token Twilio | `twilio_auth_token` | `twilio` |
| `data.tenant_push_config` | `onesignal_rest_key_secret_id` | REST key OneSignal | `onesignal_key` | `onesignal` |
| `data.tenant_signing_config` | `docuseal_key_secret_id` | API key DocuSeal BYO | `docuseal_key` | `docuseal` |
| `data.storage_providers` | `secret_key_id` | Secret access key S3/R2/GCS | `storage_secret_key` | `storage:{provider_id}` |
| `data.tenant_webhooks` | `secret` (plaintext) | HMAC webhook | `webhook_secret` | `webhook:{webhook_id}` |
| `data.tenant_geocoding_provider_configs` | `api_key_secret_id` → Vault | API key geocoding BYO | `geocoding_api_key` | `provider_key` |
| `data.tenant_secret_refs` (DEK) | `secret_id` → Vault | Envelope DEK PII | `tenant_field_dek` | `default` ( + `previous` durant rotació) |

### PII xifrat (no Vault per valor)

| Taula | Camps | Notes |
|-------|-------|-------|
| `data.employee_private_profiles` | `iban_ciphertext`, `ssn_ciphertext` (+ nonce, last4, dek_version) | EtM; AAD tenant\|employee\|field; reveal via RPC |

### Camps que NO són secrets

| Taula | Camp | Motiu |
|-------|------|-------|
| `data.storage_providers` | `access_key` | Clau pública (Access Key ID). Documentat al schema com a segur d'emmagatzemar. |
| `data.tenant_twilio_config` | `account_sid` | Identificador públic Twilio |
| `data.tenant_push_config` | `onesignal_app_id` | Identificador públic OneSignal |

### Platform AI (no és tenant BYO)

`data.platform_ai_defaults.ai_key_secret_id` — secret de plataforma al Vault, no entra a `tenant_secret_refs`. Metadades a `platform_secret_registry`.

---

## 2. Secrets de plataforma (env vars)

Font: [`supabase/functions/.env.example`](../../supabase/functions/.env.example)

| Variable | Categoria | Ús principal |
|----------|-----------|--------------|
| `RESEND_API_KEY` | email | `process-email-queue`, email transaccional |
| `RESEND_WEBHOOK_SECRET` | email | `resend-webhook` HMAC |
| `ONESIGNAL_APP_ID` | push | `_shared/notifications/adapters/onesignal-adapter.ts` |
| `ONESIGNAL_REST_API_KEY` | push | mateix adapter (fallback platform) |
| `DOCUSEAL_API_KEY` | signing | `sign-document-router`, `signing-session-manager` |
| `DOCUSEAL_WEBHOOK_SECRET` | signing | `docuseal-webhook` |
| `DOCUSEAL_API_URL` | signing | URL base (no secret) |
| `TWILIO_AUTH_TOKEN` | sms | `twilio-status-callback` (validació platform) |
| `GOTENBERG_WEBHOOK_SECRET` | pdf | `process-gotenberg-callback` |
| `AI_PROPOSAL_SECRET` | ai | `_shared/ai/tools/proposal-token.ts` HMAC |
| `UPSTASH_REDIS_REST_URL` | infra | rate limiter / cues |
| `UPSTASH_REDIS_REST_TOKEN` | infra | mateix |
| `SENTRY_DSN` | observability | Sentry adapter |
| `ENVIRONMENT` | observability | etiqueta entorn |
| `SUPABASE_SERVICE_ROLE_KEY` | auth | injectat per Supabase en prod |
| `SERVICE_ROLE_KEY` | auth | només local dev |

### Vault infra (pg_cron → Edge Functions)

| Nom Vault | Ús |
|-----------|-----|
| `app_supabase_url` | Workers pg_cron invoquen Edge Functions |
| `app_service_role_key` | mateix |

---

## 3. Mecanismes actuals

### Vault (pgsodium)

- **Escriure:** `vault.create_secret()` / `vault.update_secret()` dins RPCs `SECURITY DEFINER`
- **Llegir:** `SELECT decrypted_secret FROM vault.decrypted_secrets WHERE id = ...`
- **Clau mestre:** gestionada per Supabase (pgsodium). No hi ha `TENANT_SECRETS_MASTER_KEY` d'aplicació.

### pgcrypto (no secrets)

- `gen_random_bytes()` — tokens de share/signing
- `digest(..., 'sha256')` — cadena d'integritat entity timeline

### Hashing (no Vault)

- `AI_PROPOSAL_SECRET` — HMAC propostes IA
- Webhooks outbound — HMAC amb secret (avui plaintext a BD)

---

## 4. RPCs existents

### Lectura (service_role only)

| RPC | Secret |
|-----|--------|
| `api.get_tenant_twilio_credentials_service` | Twilio auth token |
| `api.get_tenant_push_config_service` | OneSignal REST key |
| `api.get_ai_api_key_for_generation` | AI API key + metadata |
| `api.get_storage_provider_with_secret` | BYOS secret key |
| `api.get_platform_ai_api_key_for_sync` | Platform AI key |
| `api.get_webhook_dispatch_context` | Webhook secret (plaintext avui) |

### Lectura (excepció — JWT owner/manager)

| RPC | Notes |
|-----|-------|
| `api.get_docuseal_key_for_signing` | Retorna plaintext API key. Gated per JWT owner/manager. Documentar com a excepció controlada; valorar migració a service_role-only. |

### Escriptura

| RPC | Secret |
|-----|--------|
| `api.upsert_tenant_twilio_config` | Twilio |
| `api.upsert_tenant_push_config` | OneSignal |
| `api.save_tenant_ai_provider_secret` | AI (service_role des de Edge) |
| `api.save_storage_config` | BYOS (service_role des de Edge) |
| `api.save_tenant_docuseal_config` | DocuSeal |
| `api.upsert_tenant_webhook` | Webhook secret (plaintext avui) |

---

## 5. Mapa Edge Function → secret

| Edge Function | Font | RPC / env |
|---------------|------|-----------|
| `save-tenant-api-key` | Vault (escriu) | `save_tenant_ai_provider_secret` |
| `ai-chat-turn` | Vault | `get_ai_api_key_for_generation` |
| `process-notification-queue` | Vault + env | Twilio/OneSignal RPCs |
| `twilio-status-callback` | Vault o env | `get_tenant_twilio_credentials_service` / `TWILIO_AUTH_TOKEN` |
| `process-email-queue` | env | `RESEND_API_KEY` |
| `sign-document-router` | Vault o env | `get_docuseal_key_for_signing` / `DOCUSEAL_API_KEY` |
| `request-upload`, `get-file-url` | Vault | `get_storage_provider_with_secret` |
| `process-webhook-queue` | BD plaintext | `get_webhook_dispatch_context` |
| `resend-webhook` | env | `RESEND_WEBHOOK_SECRET` |

---

## 6. Gaps identificats

| Prioritat | Gap | Acció |
|-----------|-----|-------|
| Alta | `tenant_webhooks.secret` plaintext | Fase 3 → Vault |
| ~~Geocoding ref text~~ | Tancat — `20260725000004_geocoding_secret_vault.sql` |
| Mitjana | Sense inventari/audit centralitzat | Fase 1 |

---

## 7. Alertes de rotació — destinataris

| Tipus | Destinatari |
|-------|-------------|
| Tenant BYO | owners/managers (`tenant_members`, `site_id IS NULL`) |
| Plataforma | Admin-portal UI + `last_rotation_alert_at` |
