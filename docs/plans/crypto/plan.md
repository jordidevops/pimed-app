# Sistema unificat de secrets i encriptació

Pla d'implementació derivat de [`prompt.md`](./prompt.md). Estat: **implementat (V1)**.

| Mecanisme | Secrets | Fitxers clau |
|-----------|---------|--------------|
| Vault (`*_secret_id`) | AI, Twilio, OneSignal, DocuSeal, BYOS, webhooks | migracions `20260725*` |
| Env vars (Edge Functions) | Resend, OneSignal platform, DocuSeal platform, Twilio platform | `supabase/functions/.env.example` |
**Gaps tancats (V1):** webhooks plaintext, geocoding `api_key_secret_ref` → Vault.

**Decisió arquitectònica:**

- **Clau mestra de tenant:** confiar en pgsodium (Supabase Vault). No `TENANT_SECRETS_MASTER_KEY` a V1.
- **No KDF per tenant:** aïllament per `vault.secrets.id`; `tenant_secret_refs` = metadades.
- **Plataforma:** env vars + `platform_secret_registry` (metadades sense valors).

## Fases

| Fase | Entregable | Estat |
|------|------------|-------|
| 0 | `docs/security/encryption-audit.md` | Fet |
| 1 | `20260725000001_secret_management_core.sql` | Fet |
| 2 | `20260725000002_secret_management_rpc_refactor.sql` | Fet |
| 3 | Geocoding + webhooks → Vault | Fet |
| 4 | `kms-provider.ts` | Fet |
| 5 | `docs/security/*` + cursor rule | Fet |
| 6 | Admin `/dashboard/security/*` + tab tenant | Fet |
| 7 | Tenant `/settings/secrets` | Fet |
| 8 | `secret_management_tests.sql` | Fet (bàsic) |
| 9 | Field-level PII (IBAN/NSS + DEK) | Fet — `20261128000001_employee_private_field_encryption.sql` |

## Alertes de rotació (tipus 1 i 2, no clau mestre)

| Tipus | Què es rota | Alertes cron? |
|-------|-------------|---------------|
| Secret individual BYO | Claus API del tenant | Sí → `SECRET_ROTATION_DUE` |
| Secret de plataforma | Env vars (Resend, etc.) | Sí → admin UI + `last_rotation_alert_at` |
| Clau mestre Vault | Vault intern | No — només runbook |
| DEK camp (`tenant_field_dek`) | Envelope PII | Manual platform — `rotate_tenant_field_dek` |

## Backfill storage

Només `secret_key_id` → `tenant_secret_refs` amb `provider = 'storage:' || id`. Mai `access_key`.

## `secret_access_log`

INSERT tolerant (`BEGIN/EXCEPTION`); lectura de secret mai bloquejada per fallada de log.

## Field-level PII

Veure `docs/security/encryption-design.md` (secció envelope) i cursor rule. **Una sola DEK per tenant** — no crear-ne una altra per mòdul.

## Fora d'abast

- Rotació automatitzada clau mestre Vault
- KMS extern / HSM
- DEKs per propòsit (`pii_bank` vs `pii_identity`)
- Implementació MCP server (només `secret_type` preparat)
- Widget cost KMS admin (P2, fora d'abast per decisió actual)

Veure el pla complet amb diagrames a la conversa de planificació o executar les fases en ordre.
