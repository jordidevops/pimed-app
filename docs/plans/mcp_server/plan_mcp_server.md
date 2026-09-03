# Guia MCP per a Supabase + Edge Functions (Producció)

**Objectiu del document:** donar instruccions clares a una IA perquè pugui generar un pla d'implementació d'un servidor MCP multi-tenant preparat per producció.

**Context objectiu:**
- Backend: Supabase (PostgreSQL + Auth + RLS)  
- Compute: Supabase Edge Functions  
- Frontend: `tenant-portal` i `admin-portal`  
- MCP: endpoint públic per clients externs (Claude, ChatGPT, LibreChat, etc.)

---

## 1) Principis no negociables

1. **Aïllament multi-tenant absolut**
   - Cap request no pot retornar dades d'un altre tenant.
   - L'aïllament s'ha d'aplicar a **SQL** (no en memòria després del `SELECT`).
2. **Defensa en profunditat**
   - Auth + RLS + validació backend + rate limit + WAF/edge controls.
3. **Fail-closed**
   - Si falta configuració crítica (secret, tenant context, site scope), la request es rebutja.
4. **Producció només amb capa edge**
   - No obrir endpoint MCP públic sense WAF/API Gateway o equivalent.
5. **Observabilitat i resposta operativa**
   - Logs, mètriques, alertes i runbook abans de l'activació global.

---

## 2) Errors típics (apresos) que s'han d'evitar

1. **Rate limit massa tard**  
   Error: aplicar límits després de fer múltiples queries d'autenticació/context.  
   Solució: escut **pre-auth** (IP + fingerprint credencial) abans de tocar BD.

2. **Acceptar tokens “amb prefix” i consultar BD sempre**  
   Error: qualsevol token `mcp_live_...` provocava lookup SQL.  
   Solució: validació estricta de format abans de BD + quota pre-auth.

3. **Body sense límit**  
   Error: llegir body sencer (OOM/DoS).  
   Solució: límit de mida (p.ex. 64 KB), JSON parsing robust, rebuig immediat.

4. **Filtrat de `site_id` en memòria**  
   Error: consultar i després comprovar `site_id`.  
   Solució: incorporar `tenant_id` + `site_id` directament al `WHERE`.

5. **CORS wildcard en endpoint públic**  
   Error: `Access-Control-Allow-Origin: *`.  
   Solució: allowlist estricta o desactivar ús browser si és server-to-server.

6. **Secrets amb fallback insegur**  
   Error: usar secret per defecte o fallback no controlat.  
   Solució: secret obligatori en producció, fail-fast en startup.

---

## 3) Arquitectura recomanada

## 3.1 Components
- **Edge/WAF layer** (Cloudflare, API Gateway, etc.): bloqueig IP/geo/ASN, rate limiting bàsic.
- **Supabase Edge Function** `mcp_server_http`: endpoint MCP (`POST/GET/DELETE/OPTIONS` si cal).
- **PostgreSQL (Supabase)**:
  - taules MCP (api keys, usage logs, rate limits, platform settings),
  - dades de negoci amb `tenant_id`, `site_id`,
  - polítiques RLS.
- **tenant-portal**:
  - activar MCP del tenant,
  - crear/revocar API keys,
  - veure ús.
- **admin-portal**:
  - toggle global MCP,
  - kill switch,
  - observabilitat global.

## 3.2 Flux d'execució (alt nivell)
1. Request arriba a edge layer (primera barrera).
2. Edge Function aplica validacions primerenques:
   - mètode,
   - headers mínims,
   - mida body,
   - format token,
   - rate limit pre-auth.
3. Resol sessió MCP (API key o JWT Supabase/Firebase equivalent).
4. Carrega context segur (`tenant_id`, `site_id`, `member_role`, permisos).
5. Aplica rate limit lògic per tenant/key/user.
6. Executa tool/resource amb SQL scoped (`tenant_id` + `site_id`).
7. Registra ús i retorna resposta.

---

## 4) Model d'autenticació recomanat

## 4.1 Modes suportats
1. **API key MCP (principal per integracions externes)**
   - Format: `mcp_live_` (prod), `mcp_test_` (staging/dev).
   - Només es mostra una vegada al crear-la.
   - A BD només es guarda hash (HMAC-SHA256 amb secret fort).
2. **JWT d'usuari (secundari/dev)**
   - Requereix `X-Tenant-Id` i opcionalment `X-Site-Id`.
   - Validació de membresia activa al tenant.

## 4.2 Regles de validació
- API key:
  - regex estricta abans de SQL,
  - lookup per `key_prefix + key_hash`,
  - excloure a SQL claus revocades/expirades.
- JWT:
  - validar signatura i `exp`,
  - exigir `tenant_id` explícit,
  - comprovar membresia activa + permisos.

---

## 5) Multi-tenant i RLS (Supabase)

## 5.1 Disseny de dades
Totes les taules de negoci han d'incloure:
- `tenant_id` (obligatori)
- `site_id` (si aplica)

## 5.2 Política RLS mínima
- Rol service (Edge Function) amb accés controlat.
- Si es consulta amb context d'usuari, RLS ha de garantir:
  - només files del `tenant_id` del context,
  - `site_id` coherent amb l'abast del membre/clau.

## 5.3 Regla pràctica
Encara que hi hagi RLS, **sempre** filtrar també a query:
- `WHERE tenant_id = $tenantId`
- `AND site_id = $siteId` (o regla equivalent explícita)

---

## 6) API keys MCP (disseny)

Taula recomanada `mcp_api_keys`:
- `id` uuid pk
- `tenant_id` uuid not null
- `name` text not null
- `key_prefix` text not null
- `key_hash` text not null
- `site_id` uuid null
- `allowed_tools` text[] null
- `member_id` uuid null
- `expires_at` timestamptz null
- `revoked_at` timestamptz null
- `last_used_at` timestamptz null
- `last_client_name` text null
- `created_by_user_id` uuid/text
- `created_at` timestamptz

Índexs mínims:
- únic per `key_prefix`
- índex per `(tenant_id, revoked_at)`
- índex per claus actives (`revoked_at is null`, `expires_at`)

---

## 7) Rate limiting en 3 capes

1. **Edge/WAF rate limit** (primer tall)
2. **Pre-auth in-memory a Edge Function**
   - per IP (finestra curta),
   - per fingerprint de credencial.
3. **Rate limit de negoci a BD**
   - per tenant + API key o user,
   - finestres hora/dia.

Regla: la capa 2 s'executa **abans** de qualsevol query costosa.

---

## 8) Disseny MCP (tools/resources)

## 8.1 Tools
- Exposar només tools `read`.
- No exposar accions destructives ni `propose_*` sense confirmació humana.
- Validació d'arguments estricta (schema + tipus + enums + UUID).

## 8.2 Resources
- URI templates amb `tenantId/siteId`.
- Validar que URI i sessió coincideixen:
  - `tenantId` URI == `tenantId` sessió
  - si la sessió té `siteId`, la URI no pot demanar un altre site.

## 8.3 Timeouts
- Timeout curt per tool (p.ex. 5s-10s).
- Cancel·lació i retorn d'error controlat.

---

## 9) Operacions i observabilitat

## 9.1 Usage logs (`mcp_usage_logs`)
Guardar com a mínim:
- `tenant_id`, `api_key_id`, `auth_type`
- `client_name`, `user_agent`
- `mcp_method`, `tool_name`, `resource_uri`
- `status` (`success`, `error`, `rejected_*`)
- `latency_ms`, `created_at`

## 9.2 Alertes mínimes
- p95 latència MCP
- % 5xx
- % 429
- connexions actives DB
- CPU DB

## 9.3 Retenció i neteja
- TTL logs (p.ex. 90 dies)
- neteja rate-limit windows antigues
- job programat (cron Edge Function o DB scheduler)

---

## 10) Configuració runtime recomanada

- `timeoutSeconds`: 30s màxim
- `maxInstances`: acotat segons capacitat DB
- `MAX_BODY_BYTES`: 64 KB
- `MCP_API_KEY_SECRET`: obligatori en prod (sense fallback insegur)
- `MCP_SERVER_FORCE_DISABLED`: kill switch global
- `MCP_CORS_ALLOW_ORIGINS`: allowlist explícita
- `MCP_EDGE_MAX_REQUESTS_PER_IP`: límit pre-auth
- `MCP_EDGE_MAX_REQUESTS_PER_TOKEN`: límit pre-auth

---

## 11) Integració portals

## 11.1 tenant-portal
- Toggle “Servidor MCP” per tenant.
- Crear clau segura al servidor (mai input de clau manual).
- Selecció `site_id` obligatòria o resolució automàtica segura.
- Copiar clau una sola vegada.
- Vista d'ús (resum + logs).

## 11.2 admin-portal
- Toggle global plataforma.
- Motiu de desactivació.
- Kill switch d'emergència.
- Observabilitat agregada cross-tenant.

---

## 12) Pla de desplegament (resum per IA)

La IA ha de planificar en fases:

1. **Fase 0 — Disseny i seguretat**
   - threat model,
   - decisions d'auth i edge controls,
   - contracte d'errors.
2. **Fase 1 — DDL + índexs + jobs de neteja**
3. **Fase 2 — Edge Function MCP (skeleton + pre-auth shield)**
4. **Fase 3 — Sessió segura + context tenant/site + rate limits**
5. **Fase 4 — Tools/resources read-only amb SQL scoped**
6. **Fase 5 — tenant-portal/admin-portal**
7. **Fase 6 — Observabilitat + alertes + runbook**
8. **Fase 7 — Canary + prova de càrrega + rollout progressiu**

Cada fase ha d'incloure:
- entregables,
- riscos,
- criteri d'acceptació,
- proves (unitàries + integració + seguretat bàsica).

---

## 13) Criteri Go/No-Go

**No-Go** si falta qualsevol d'aquests:
- capa edge en enforce,
- secret MCP robust en producció,
- alertes i runbook actius,
- prova de càrrega multi-tenant acceptable,
- validació d'aïllament tenant/site verificada.

**Go controlat**:
- canary 1-3 tenants,
- monitoratge 24-72h,
- escalat progressiu per lots.

---

## 14) Prompt base per a la IA planificadora

Pots donar a la IA aquest encàrrec:

> “Crea un pla d'implementació MCP per Supabase + Edge Functions seguint estrictament `SUPABASE_MCP_IMPLEMENTATION_GUIDE.md`.  
> El pla ha de ser per fases, amb riscos, dependències, schema SQL, polítiques de seguretat multi-tenant, estratègia de rate limiting en 3 capes, observabilitat, runbook i criteri Go/No-Go.  
> Prioritza seguretat i estabilitat de producció per sobre de velocitat d'entrega.”



## Revisió de Claude Sonnet 4.6 (Baix)

El document és molt bo — és evident que l'ha escrit (o revisat) algú amb experiència en incidents de producció reals. Les seccions 2 ("errors apresos") i 13 (Go/No-Go) solen ser les que falten als plans escrits des de zero i aquí estan ben detallades.

## Riscos reals i com els valoro

**El risc principal no és tècnic, és estratègic:** un servidor MCP públic exposa *totes* les tools que implementeu a qualsevol client extern (Claude Desktop, ChatGPT, LibreChat...). Això és potent, però significa que un bug en una tool read-only deixa de ser un problema intern i passa a ser una superfície d'atac pública. El document tracta la seguretat tècnica bé, però no aborda la pregunta prèvia: *quines tools* es volen exposar externament, i si el conjunt de tools internes (del pla de function calling) és el mateix que el conjunt públic MCP, o si han de ser subconjunts diferenciats.

**Altres riscos concrets:**

El rate limiting pre-auth (secció 7, capa 2) descriu "in-memory a Edge Function", però les Edge Functions de Supabase no comparteixen memòria entre instàncies. Amb múltiples instàncies concurrent, el "pre-auth in-memory" no aguanta — necessita Redis/Upstash o equivalent, o fer-ho tot a BD (que és el que la secció diu que vol evitar per cost). Cal decidir explícitament quin mecanisme s'usa per a la capa 2, perquè "in-memory" en serverless és una contradicció.

El document diu "timeout curt per tool (5-10s)" però les Edge Functions de Supabase tenen un límit de ~60s de wall clock total. Amb un bucle de múltiples tool calls (com el `runToolLoop` del pla de function calling), és fàcil superar-lo si es connecten MCPs de tercers lents. Això no és un risc del servidor MCP propi, sinó del client MCP intern que crida servidors externs — i el document no distingeix els dos casos.

La taula `mcp_api_keys` inclou `last_used_at` (actualitzat en cada request). En alta concurrència, aquest `UPDATE` per cada request és un bottleneck clàssic. Millor un esquema de "actualitzar cada N minuts" o via cron, no síncron per request.

## Ho implementaria?

Sí, però no ara i no com a Fase 5 del pla de function calling. Aquí el perquè:

**El servidor MCP públic és un producte diferent del xat intern.** El xat intern (function calling) és per als usuaris del tenant-portal usant la seva pròpia clau BYOK. El servidor MCP públic és per a *clients externs* (Claude Desktop d'un usuari, un script d'automatització d'un partner) que volen accedir a les dades del tenant des de fora de la vostra app. Són casos d'ús, audiències i models de risc molt diferents.

**L'ordre natural hauria de ser:**
1. Implementar function calling intern (Fases 1-4 del pla de xat) — apreneu quines tools funcionen bé, quines causen problemes, quins límits de tokens i latència teniu en producció real.
2. Amb unes quantes tools estables i ben provades, *llavors* exposeu-ne un subconjunt via MCP públic.

Fer-ho al revés (exposar MCP públic amb tools que no heu operat en producció interna) és exactament el patró de risc que la secció 2 del document intenta evitar: superfície d'atac sense experiència operativa prèvia.

**Quan té sentit accelerar-ho:** si teniu un cas d'ús concret imminent (un partner o client enterprise que necessita accés MCP per integrar-se amb Claude Desktop o un agent propi), llavors val la pena avançar-ho. Sense aquest pull extern, el cost operatiu (observabilitat, runbook, gestió d'incidents públics, GDPR d'un endpoint extern) no justifica la prioritat per sobre de completar el xat intern.

**Una cosa que afegiria al document:** una secció explícita sobre *quines tools s'exposen públicament i quines no*. El document assumeix que les tools existiran però no diu qui decideix quines arriben al catàleg públic ni amb quin procés de revisió — en un sistema multi-tenant, una tool que sembla innòcua (query d'empleats read-only) pot tenir implicacions GDPR molt diferents quan l'accés ve d'un agent extern no supervisat vs. d'un usuari autenticat al portal.