# Runbook — compromís de clau (emergència)

## Secret individual de tenant compromès

1. **Revocar** al proveïdor extern (OpenAI, Twilio, etc.) immediatament.
2. **Revocar** a la plataforma: `SELECT api.revoke_tenant_secret(tenant_id, 'ai_api_key', 'openai');`
3. Notificar tenant owner (email + in-app).
4. Revisar `secret_access_log` per accessos anòmals:
   ```sql
   SELECT * FROM data.secret_access_log
   WHERE tenant_id = '<uuid>' AND created_at > now() - interval '7 days'
   ORDER BY created_at DESC;
   ```
5. Tenant genera nova clau i la configura via portal.

## Secret de plataforma compromès

1. Rotar immediatament a Supabase Dashboard (`supabase secrets set`).
2. Redeploy Edge Functions si cal.
3. `api.log_platform_secret_rotation(..., 'emergency', ...)`.
4. Revisar logs d'Edge Functions per ús no autoritzat.

## Clau mestre Vault compromesa

Seguir [rotate-master-key.md](./rotate-master-key.md) + assumir **tots** els secrets BYO cal re-rotar als proveïdors.

## GDPR

Si el compromís afecta dades personals processades amb el secret, valorar notificació a autoritat de control i interessats (**72h** art. 33/34 RGPD).
