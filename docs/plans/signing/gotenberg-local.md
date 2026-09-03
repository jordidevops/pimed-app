# Gotenberg — desenvolupament local

## Dues URLs (normal)

| Qui crida | On corre | URL |
|-----------|----------|-----|
| Admin portal (test connexió) | Host | `http://localhost:3007` |
| Edge Functions | Contenidor Docker | `GOTENBERG_URL` a `supabase/functions/.env.local` |

```env
# supabase/functions/.env.local
GOTENBERG_URL=http://host.docker.internal:3007
```

Reinicia després de canvis: `supabase functions serve --env-file supabase/functions/.env.local`

**No posis `host.docker.internal` a l'admin** — el test de connexió corre al host i fallarà.

## Arrencar Gotenberg en local (recomanat)

Des de l'arrel del repo:

```bash
docker compose -f docker/gotenberg/docker-compose.local.yml up -d
curl http://localhost:3007/health
```

Aquest compose usa configuració **permissiva** per dev (`CHROMIUM_ALLOW_LIST=.*`).

## Error: CONNECT blocked + HTTP 403 Forbidden

Logs típics:

```
CONNECT blocked for 'www.google.com:443' ... does not match any expression from the allowed list
htmlToPdf HTTP 403: Forbidden
```

**Causa:** Gotenberg 8.32+ filtra connexions sortints de Chromium. Si tens `CHROMIUM_DENY_PUBLIC_IPS=true` o una `CHROMIUM_ALLOW_LIST` restrictiva (config de producció), Chromium no pot connectar a dominis de Google (telemetry interna) i la conversió falla amb **403**.

Això **no ve** de les plantilles HTML del seed (no tenen Google Fonts). És la configuració del contenidor Gotenberg.

### Solució ràpida (dev)

1. Atura el Gotenberg actual: `docker ps` → atura el contenidor del port 3007
2. Arrenca el del repo:

```bash
docker compose -f docker/gotenberg/docker-compose.local.yml up -d
```

3. Reinicia `supabase functions serve`
4. Reintenta la generació PDF

### Si uses el repo `gotenberg-pdf-generator`

Assegura't que el `docker-compose.local.yml` **no** reutilitzi la config estricta de producció. Per dev local:

```yaml
environment:
  CHROMIUM_DENY_PRIVATE_IPS: "false"
  CHROMIUM_DENY_PUBLIC_IPS: "false"
  CHROMIUM_ALLOW_LIST: ".*"
```

En **producció** sí que cal allow-list estricte; en **local** no.

## Comprovar

```bash
curl http://localhost:3007/health
# → {"status":"up",...}
```
