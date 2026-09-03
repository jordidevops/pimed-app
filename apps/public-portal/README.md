# Public Portal

Aquest és el portal públic orientat a usuaris externs i captació de *leads*. Està dissenyat per ser ràpid, segur i delegar l'esforç de processament a la infraestructura asíncrona (PGMQ).

## Arquitectura

El projecte utilitza:
- **Next.js 16** (App Router) amb Turbopack i React 19.
- **Tailwind CSS** per a l'estilització.
- **Zod** per validar dades tant al client com al servidor.
- **Supabase-js** (amb la clau anònima específica per a dades públiques) per connectar amb la Base de Dades.

### Flux de Captació de Leads (Async)

Per garantir temps de resposta ràpids sota càrregues elevades i evitar bloquejos per processos pesats:
1. L'usuari envia el formulari cap a `POST /api/leads`.
2. L'API avalua seguretat, valida dades i fa un *push* a la cua PostgreSQL (`pgmq.send('leads_queue')`).
3. L'API retorna un codi HTTP `2xx` d'èxit gairebé immediatament.
4. El treballador de fons (Edge Function `process-leads-queue` orquestrat per `pg_cron`) recull el *lead*, neteja XSS, fa *upserts* amb bloquejos transaccionals (`pg_advisory_xact_lock`) evitant duplicats ("race conditions") i envia notificacions in-app als *owners* del *tenant-portal*.

## Seguretat i Anti-Abús

Aquest portal fa front a un entorn de xarxa obert. Incorpora múltiples capes de seguretat:

*   **Honeypot Validation**: El codi Zod captura camps falsos per descartar automàticament "dumb bots".
*   **Upstash Redis Rate Limiting**: Limita les peticions de forma distribuïda independentment de quantes instàncies Serverless (Vercel) s'engeguin. Inclou un sistema dual: si Upstash falla o no està configurat, recau en un *fallback* de memòria en instància curta.
*   **Cloudflare Turnstile**: Una alternativa a CAPTCHA. A producció, qualsevol fallada de xarxa amb els servidors de Cloudflare denega la petició per defecte (fail-closed), protegint l'origen.
*   **Anti-XSS**: El tractament sanitari HTML (escapament) s'aplica estrictament en el processament de cues.

## Configuració de Producció (Variables d'Entorn)

Per desplegar a producció de forma segura a Vercel, cal configurar les següents variables d'entorn (tant al `.env.local` durant desenvolupament, com al *Dashboard* del Vercel per Producció):

### Supabase
```env
NEXT_PUBLIC_SUPABASE_URL="https://<reference-id>.supabase.co"
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY="eyJh... (Anon key global o dedicada)"
```

### Cloudflare Turnstile
Assegura els formularis contra l'spam.
```env
NEXT_PUBLIC_TURNSTILE_SITE_KEY="0x4AAAAAA..."
TURNSTILE_SECRET_KEY="0x4AAAAAA..."
# TURNSTILE_FAIL_OPEN=true # (Només útil en entorns dev, no ho posis en Producció).
```

### Upstash Redis (Rate-Limiter Distribuït)
Clau i token pel control de *Rate Limit*.
```env
UPSTASH_REDIS_REST_URL="https://<region-db>.upstash.io"
UPSTASH_REDIS_REST_TOKEN="AWcxA..."
```

## Desenvolupament Local

```bash
# Instal.lar dependències
npm install

# Engegar en mode dev
npm run dev

# Construir per comprovar possibles errors abans de pujar
npm run build
```