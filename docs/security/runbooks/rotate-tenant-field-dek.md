# Runbook — rotar `tenant_field_dek`

Rotació de la DEK d'envelope (IBAN / NSS) d'un tenant.

## Qui

Només **platform admin** (`service_role` / admin-portal). El owner del tenant **no** pot rotar ni revocar la DEK.

## Què fa

`api.rotate_tenant_field_dek(p_tenant_id)`:

1. Crea DEK nova al Vault
2. Mou l'antiga a `provider = previous` (finestra dual-key)
3. Re-xifra tots els `iban_*` / `ssn_*` del tenant
4. Elimina la DEK `previous` del Vault
5. Escriu `secret_rotation_log`

## UI

Admin-portal → tenant → tab Secrets → fila `tenant_field_dek` → **Rotar DEK**.

O SQL (service_role):

```sql
SELECT api.rotate_tenant_field_dek('<tenant_uuid>');
```

## Després

- Verificar `key_version` a `tenant_secret_refs`
- Provar reveal d'un empleat de prova
- **No** usar `revoke_tenant_secret` sobre `tenant_field_dek` (rebruta dades)

## Emergència

Si la rotació falla a mig camí, la DEK `previous` permet decrypt fins a completar el re-encrypt. No esborrar Vault secrets a mà.
