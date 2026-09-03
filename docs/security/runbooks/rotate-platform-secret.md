# Runbook — rotació secret de plataforma

Secrets de plataforma viuen a **Supabase Edge Function secrets** (Dashboard o CLI). `platform_secret_registry` només registra metadades.

## Procediment

1. Obtenir el nou valor del proveïdor (ex: nova API key Resend).
2. Afegir secret provisional: `supabase secrets set RESEND_API_KEY_NEW=re_xxx --project-ref <ref>`
3. Desplegar Edge Function que llegeixi el nom nou (si cal canvi de codi).
4. Smoke test (enviar email de prova).
5. Eliminar variable antiga i renombrar o actualitzar codi a `RESEND_API_KEY`.
6. Registrar rotació a BD:
   ```sql
   SELECT api.log_platform_secret_rotation(
     'RESEND_API_KEY',
     'admin@example.com',
     'Rotació programada Q2'
   );
   ```

## Verificació

- [ ] Email/push/signing funciona en staging
- [ ] `platform_secret_registry.key_version` incrementat
- [ ] Entrada a `secret_rotation_log`
