# Functions en local

## Test matrix signing (Fase E)

Per executar la matriu minima oficial de sign-document-router (HTML, DOCX i PDF per sign i generate_only):

  supabase functions serve --env-file C:\JordiDevops\app-supabase\supabase\functions\.env.local

En un segon terminal:

  cd supabase/tests
  ./run_edge_signing_matrix_tests.ps1

Variables necessaries (entorn o parametres del script):

- EDGE_TEST_JWT (JWT autenticat d usuari membre del tenant)
- EDGE_TEST_TENANT_ID (opcional, default 10000000-0000-0000-0000-000000000001)
- EDGE_TEST_HTML_TEMPLATE_LOCALE_ID o EDGE_TEST_HTML_DOCUMENT_VERSION_ID
- EDGE_TEST_DOCX_TEMPLATE_LOCALE_ID o EDGE_TEST_DOCX_DOCUMENT_VERSION_ID
- EDGE_TEST_PDF_DOCUMENT_VERSION_ID
- EDGE_TEST_SIGNER_EMAIL (per casos action=sign)

La matriu esta implementada a supabase/tests/edge_signing_matrix_tests.mjs i fa SKIP automatic dels casos sense IDs configurats.

    supabase functions serve --env-file ./supabase/functions/.env.local

En un terminal Linux podem executar la funció

    curl -X POST http://127.0.0.1:54321/functions/v1/process-email-queue \
  -H "Authorization: Bearer eyJhb..." \
  -H "Content-Type: application/json" \
  -d "{}" -i



# Processar la cua de correus en local

Hi ha un doble motor (veure /docs/email.md) que executa la funció process-email-queue: un trigger a Postgres i pg-cron.

El trigger i el `pg_cron` **sí que existeixen i s'executen en local**, però actualment estan "avortant" la missió de forma silenciosa (deixant només un `WARNING` als logs de la base de dades).

Això passa per dos motius tècnics molt concrets del teu entorn local:

### 1. La xarxa interna de Docker (El parany del Localhost)
En local, Supabase s'executa com un conjunt de contenidors Docker. El trigger i el cron viuen dins del contenidor de PostgreSQL. Quan utilitzen `pg_net` per fer la petició HTTP, si els dius que vagin a `http://127.0.0.1:54321`, el contenidor de Postgres busca aquest port **dins d'ell mateix**, no a la teva màquina (on realment està escoltant l'Edge Runtime). 
Perquè `pg_net` trobi l'Edge Function en local, hauria de fer servir adreces internes de Docker com `http://host.docker.internal:54321` o `http://api:54321`.

### 2. Els secrets del Vault no hi són
A l'arxiu de la migració SQL `20260415000002_email_system_core.sql`, la funció `invoke_email_queue_worker()` té una protecció al principi:
```sql
  -- Read credentials from Vault
  SELECT decrypted_secret INTO v_supabase_url FROM vault.decrypted_secrets WHERE name = 'app_supabase_url';
  SELECT decrypted_secret INTO v_service_key FROM vault.decrypted_secrets WHERE name = 'app_service_role_key';

  -- Graceful degradation: no secrets -> no HTTP call (local dev)
  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RAISE WARNING 'invoke_email_queue_worker: vault secrets not configured...';
    RETURN;
  END IF;
```
Com que a la teva base de dades local no has inserit aquests secrets a la taula del Vault, la funció s'atura educadament i no fa la crida `pg_net`. Com que el cron crida exactament aquesta mateixa funció, també s'atura.

### Com s'executarà a Producció / Staging?
Al cloud, l'arquitectura de xarxa és completament plana i resolta per Supabase. L'únic que hauràs de fer quan pugi l'entorn és inserir manualment les teves variables a la taula del Vault (executant una query SQL un sol cop des del Dashboard):

```sql
SELECT vault.create_secret('https://el-teu-projecte.supabase.co', 'app_supabase_url');
SELECT vault.create_secret('eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...', 'app_service_role_key');
```

Un cop executis això a producció, el "Doble Motor" cobrarà vida:
* **El Trigger** dispararà la petició `pg_net` de forma instantània cada vegada que algú encui un missatge, de manera que l'enviament trigarà mil·lisegons.
* **El Cron** anirà escombrant cada 2 minuts, recollint els correus que s'hagin pogut quedar a la cua per culpa d'un *Rate Limit* o un *Visibility Timeout* (retries).

Per tant, en desenvolupament local, llançar el `curl` a mà en una finestra de terminal o utilitzar Postman és la via correcta i més pràctica per simular el comportament del trigger sense haver de barallar-te amb les xarxes internes de Docker.

