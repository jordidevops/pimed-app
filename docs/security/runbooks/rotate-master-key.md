# Runbook — rotació clau mestre pgsodium (emergència)

La clau mestre de xifratge de Supabase Vault (pgsodium) **no es rota en operació normal**. Aquest procediment és només per compromís confirmat o requisit de compliance.

## Quan aplicar

- Compromís de la infraestructura Supabase (notificació oficial)
- Canvi de projecte/regió amb re-encriptació obligatòria
- Requisit contractual amb HSM extern

## Procediment (manual, finestra de manteniment)

1. **Comunicació:** avisar equips i tenants amb secrets BYO actius.
2. **Backup:** exportar metadades `tenant_secret_refs` i inventari Vault (IDs, no valors).
3. **Coordinació Supabase:** obrir ticket suport per rotació clau root si aplica al pla.
4. **Verificació post-rotació:**
   - Llegir secret de prova via `api.get_tenant_secret`
   - Enviar SMS/email/AI de smoke test per tenant crític
5. **Rollback:** restaurar backup de projecte si Supabase ho suporta; sinó re-importar secrets des de proveïdors (rotació massiva BYO).

## No automatitzat a V1

No existeix Edge Function `rotate-master-key`. La rotació de secrets individuals BYO és independent (`api.rotate_tenant_secret`).
