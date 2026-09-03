# Sistema d'IA multi-tenant (BYOK) — Guia de referència

**Data:** 2026-06-17  
**Audiència:** desenvolupadors i agents d'IA que implementin un sistema semblant (p. ex. PostgreSQL a Supabase).  
**Codi de referència:** `functions/src/ai/`, `apps/tenant-portal/src/components/settings/`, `apps/tenant-portal/src/pages/ChatPage.tsx`

---

## 1. Principis d'arquitectura

Aquesta app és **SaaS multi-tenant i multi-site** amb PostgreSQL. El patró d'IA segueix aquests principis no negociables:

| Principi | Implementació |
|----------|----------------|
| **BYOK (Bring Your Own Key)** | Cada tenant aporta les seves claus API; l'app no paga el consum del proveïdor |
| **Cap secret al client** | Les claus mai surten de Cloud Functions; el frontend només veu `hasApiKey` |
| **Punt únic d'execució** | Totes les crides IA passen per CF (`generateAIContent`, `generateAIChatTurn`, `applyAIChatProposal`) |
| **Governança abans del proveïdor** | Comprovar permisos, model permès i rate limits **abans** de gastar la clau BYOK |
| **Auditoria append-only** | Cada intent (èxit, error, rebutjat) deixa rastre a `ai_usage_logs` |
| **Context segur al backend** | `tenant_id`, `site_id` i `userId` s'injecten al servidor; el model **no** els rep com a arguments de tools |
| **Lectura vs escriptura** | Threads/missatges i logs: lectura via Data Connect; escriptura via CF |

```
┌─────────────┐     HTTPS onCall      ┌──────────────────┐     API externa    ┌──────────┐
│ tenant-portal│ ───────────────────► │ Cloud Functions  │ ────────────────► │ OpenAI / │
│ (React)      │                      │ prepareAIGovernance│                  │ Anthropic│
└──────┬──────┘                      │ + proveïdor      │                  │ Gemini   │
       │ Data Connect (lectura)      └────────┬─────────┘                  └──────────┘
       ▼                                      │
┌─────────────┐                               ▼
│ PostgreSQL  │ ◄── ai_configs, ai_usage_logs, ai_rate_limits, ai_chat_*
└─────────────┘
```

---

## 2. BYOK — Proveïdor d'IA propi del tenant

### 2.1 On es guarda cada cosa

| Dada | Ubicació | Notes |
|------|----------|-------|
| Claus API xifrades | Taula `ai_configs` | AES-256-GCM: `encrypted_api_key`, `api_key_iv`, `api_key_auth_tag` |
| Flag públic | `ai_configs.has_api_key` | El client només sap si hi ha clau, no la clau |
| Models, prompts, temperature | `tenants.metadata.ai` (JSONB) | Config no sensible |
| Polítiques i límits | `tenants.metadata.ai.policies` | Master switch, límits per defecte, overrides per feature |
| Override per usuari | `tenant_members.settings.ai` | Habilitat, models permesos, límits més restrictius |

### 2.2 Proveïdors suportats

- `openai`
- `anthropic`
- `gemini`

### 2.3 Flux de guardar clau (`saveTenantAPIKey`)

1. Verificar autenticació Firebase (`request.auth.uid`).
2. `assertCanConfigureAI` — només **owner** o **manager** global (`site_id IS NULL`).
3. **Validar la clau** cridant l'API del proveïdor (`listProviderModels`) abans de persistir.
4. Xifrar amb `AI_ENCRYPTION_KEY` (32 bytes base64) i fer UPSERT a `ai_configs`.
5. Retornar la llista de models descoberts (la UI els fusiona amb `discoveredModels`).

**Fitxers:** `functions/src/ai/save-tenant-api-key.ts`, `functions/src/ai/ai.service.ts` (`encryptApiKey`, `saveTenantAIKey`).

### 2.4 Variables d'entorn (Functions)

```bash
AI_ENCRYPTION_KEY=<base64 32 bytes>   # openssl rand -base64 32
# Fallback dev: MAP_ENCRYPTION_KEY o clau determinista a l'emulador
```

Fora de l'emulador, **sense** `AI_ENCRYPTION_KEY` les CF fallen explícitament (no s'ha d'usar clau de dev en producció).

### 2.5 UI de configuració

**Ruta:** `/settings` → pestanya **IA** (`TenantAISettingsTab`).

- Pestanyes per proveïdor (OpenAI, Anthropic, Gemini).
- Indicador verd si `hasApiKey`.
- Models actius (badges), model per defecte de contingut, system prompt, temperature, max tokens.
- Panell d'ús i governança (`TenantAIUsagePanel`).
- Polítiques globals (`updateTenantAIPolicies`).

**Hook de lectura:** `useAIConfig(tenantId)` — consulta `getMyAiConfig` via Data Connect.

---

## 3. Provar connexió IA

No hi ha una CF dedicada `testAIConnection`. La prova reutilitza **`generateAIContent`** amb paràmetres explícits del formulari.

### 3.1 Flux (`TenantAISettingsTab.handleTestAI`)

1. L'usuari introdueix un prompt de prova (per defecte: «Hola»).
2. Es crida `generateAIContent` amb:
   - `tenantId`
   - `userPrompt`, `provider`, `model`, `systemPrompt`, `temperature`, `maxTokens`
   - `includeRaw: true` (per mostrar la resposta crua del proveïdor a la UI de debug)
3. Èxit → es mostra el text generat i opcionalment el JSON raw.
4. Error → `formatAIError` tradueix codis comuns (`INVALID_API_KEY`, rate limits, etc.).

### 3.2 Per què aquest patró

- **Un sol camí d'execució:** la prova passa pel mateix pipeline de governança i desxifrat de clau que la producció.
- **Validació real:** si la clau és invàlida, falla igual que en ús real.
- **Side effect acceptable:** la prova consumeix quota i deixa una fila a `ai_usage_logs` (feature `content`).

### 3.3 Guardar clau vs provar

| Acció | CF | Validació prèvia |
|-------|-----|------------------|
| Guardar clau | `saveTenantAPIKey` | `listProviderModels` (sense generar text) |
| Provar connexió | `generateAIContent` | Generació real amb governança completa |

---

## 4. Límits d'ús per defecte i polítiques efectives

### 4.1 Valors per defecte del tenant

Definits a `functions/src/ai/ai-limits.ts`:

| Límit | Valor per defecte | Significat |
|-------|-------------------|------------|
| `requestsPerHour` | 60 | Peticions per usuari i hora (UTC) |
| `requestsPerDay` | 500 | Peticions per usuari i dia (UTC) |
| `tokensPerDay` | 500 000 | Tokens totals (input + output) per dia |
| `requestsPerMinute` | `null` | Només actiu amb `threadId` (xat) |

### 4.2 Overrides per feature

A `tenants.metadata.ai.policies.features` es poden definir límits específics per feature (`content`, `zones`, `checkpoint`, `chat`).

Exemple recomanat per xat:

```json
{
  "ai": {
    "policies": {
      "enabled": true,
      "defaultLimits": {
        "requestsPerHour": 60,
        "requestsPerDay": 500,
        "tokensPerDay": 500000,
        "requestsPerMinute": null
      },
      "features": {
        "chat": {
          "requestsPerHour": 120,
          "requestsPerDay": 1000,
          "tokensPerDay": 1000000,
          "requestsPerMinute": 20
        }
      }
    }
  }
}
```

### 4.3 Resolució de política efectiva

Funció `resolveEffectiveAIPolicy(tenantSettings, memberSettings, feature)`:

```
enabled       = member.enabled ?? tenant.policies.enabled
limits        = mergeRestrictiu(tenantLimitsPerFeature, member.limits)
allowedModels = tenant.availableModels ∩ member.allowedModels (si el membre en té)
```

- **`null` al membre** = hereta el tenant (zero migració de dades per membres existents).
- En conflicte de límits numèrics, **guanya el més restrictiu** (`Math.min`).

### 4.4 Rate limiting (`ai_rate_limits`)

Patró UPSERT atòmic (com `maps_rate_limits`):

- Finestres UTC: `hour` (`2026-06-18T14`), `day` (`2026-06-18`), `thread_min` (`{threadId}:{YYYY-MM-DDTHH:mm}`).
- La reserva de quota es fa **abans** de cridar el proveïdor (`checkAndReserveAIRequest`).
- Els tokens s'incrementen **després** de l'èxit (`recordRateLimitTokenUsage`).

### 4.5 Pipeline de governança (`prepareAIGovernance`)

Ordre d'execució (reutilitzat per `generateAIContent` i `generateAIChatTurn`):

1. `assertCanUseAI` — membre actiu del tenant.
2. Carregar política efectiva per `feature`.
3. `assertAIAllowed` — IA habilitada i model dins `allowedModels`.
4. Si hi ha `threadId` → rate limit per thread (anti-spam xat).
5. Rate limits globals (hora / dia / tokens estimats).
6. Si es rebutja → INSERT a `ai_usage_logs` amb `status = rejected_*` i `HttpsError`.
7. Si passa → retorna `usageBase` per registrar després.

**Fitxer:** `functions/src/ai/ai-governance.service.ts`.

### 4.6 Models per defecte (`defaultModels`)

```typescript
// Valors de sistema (ai.service.ts)
defaultModels: {
  content: "gpt-4o-mini",
  chat: "gpt-4o-mini",
}
```

`normalizeDefaultModels()` sincronitza `chat` amb `content` si la UI no ha configurat `chat` explícitament.

`resolveAIModel(provider, settings, feature, override)` per al xat prioritza:
1. Override explícit del client.
2. `defaultModels.content`, després `defaultModels.chat`.
3. Primer model disponible a `availableModels[provider]`.

---

## 5. Ús d'IA — Auditoria i dashboard

### 5.1 Taula `ai_usage_logs`

Una fila per intent de crida IA:

| Camp | Exemple |
|------|---------|
| `feature` | `content`, `chat`, `zones` |
| `status` | `success`, `provider_error`, `rejected_disabled`, `rejected_model`, `rejected_rate_limit` |
| `prompt_tokens`, `completion_tokens`, `total_tokens` | Del proveïdor o estimació `ceil(chars/4)` |
| `payload` | JSON no sensible: `{ promptChars, threadId, turnSequence, ... }` |

**Privacitat:** per defecte **no** es guarden prompts complets (poden contenir dades de client).

### 5.2 UI d'ús (`TenantAIUsagePanel`)

A `/settings` → IA, secció **Ús i estadístiques**:

- Selector de període (7 / 30 / 90 dies).
- KPIs: peticions totals, tokens totals.
- Gràfics diaris i per proveïdor (`AIUsageCharts`).
- Taula resum per usuari (peticions, tokens, darrera activitat).
- Detall paginat amb filtres (usuari, feature, model, estat, proveïdor).
- Export CSV.

**Query Data Connect:** `ListTenantAIUsageLogs`.

### 5.3 Extracció de tokens per proveïdor

| Proveïdor | Camps |
|-----------|-------|
| OpenAI | `usage.prompt_tokens`, `usage.completion_tokens` |
| Anthropic | `usage.input_tokens`, `usage.output_tokens` |
| Gemini | `usageMetadata.promptTokenCount`, `candidatesTokenCount` |

---

## 6. Activitat de governança IA

Complementa els logs d'ús: registra **canvis de política i claus**, no consum.

### 6.1 Taula `audit_logs`

Accions rellevants (filtre a `ListTenantAIPolicyAuditLogs`):

| Acció | Quan |
|-------|------|
| `AI_POLICY_TENANT_UPDATED` | Canvi de límits globals o master switch (`updateTenantAIPolicies`) |
| `AI_POLICY_MEMBER_UPDATED` | Canvi de política d'un membre (`updateMemberAISettings`) |
| `AI_KEY_SAVED` | Clau API guardada |
| `AI_KEY_DELETED` | Clau API eliminada |

Cada entrada inclou `tenant_id`, `user_id`, `payload` amb el diff o resum del canvi.

### 6.2 UI

A `TenantAIUsagePanel`, secció **Activitat de governança IA**: taula amb acció traduïda (`formatAuditActionLabel`), usuari i data.

### 6.3 Permisos per editar polítiques

- **Polítiques tenant:** owner + manager global.
- **Polítiques membre:** owner + manager global.
- **Ús i estadístiques:** mateix rol (no accessible a tècnics viewers).

---

## 7. Xat IA i tool calling

### 7.1 Esquema de dades

| Taula | Propòsit |
|-------|----------|
| `ai_chat_threads` | Conversa per usuari; `site_id` opcional; `provider`, `model`, `metadata` |
| `ai_chat_messages` | Missatges ordenats per `sequence`; rols: `user`, `assistant`, `tool` |

**Escriptura:** només CF. **Lectura:** Data Connect (`ListMyChatThreads`, `ListChatMessages`).

### 7.2 Flux d'un missatge

```
1. UI → createAIChatThread (si cal nou thread)
2. UI → generateAIChatTurn
      ├── inserta missatge user
      ├── prepareAIGovernance(feature: 'chat', threadId)
      ├── bucle model ↔ tools (màx. 8 rondes, timeout 5s/eina)
      ├── inserta missatges assistant/tool
      └── retorna content + uiBlocks + pendingActions
3. UI → ListChatMessages (refetch via React Query)
4. (Opcional) UI → applyAIChatProposal (només després de confirmació humana)
```

### 7.3 Tool registry

- Registre central: `functions/src/ai/tools/`.
- Cada tool defineix: `name`, `description`, `parameters` (JSON Schema), `risk` (`read` | `write`), `requiresSite`, `allowedRoles`, `requiredPermission`.
- `listForContext(ctx)` filtra tools segons rol, permisos i `siteId`.
- **`tenant_id` / `site_id` mai als schemas** — s'injecten a `ToolExecutionContext` al backend.

### 7.4 Escriptures amb confirmació humana (P2)

Patró **`propose_*` + `apply_*`** (no exposar `apply_*` com a tool del model):

1. Tool `propose_create_incident` — dry-run; retorna `proposal` amb token HMAC signat (TTL 15 min, `jti` únic).
2. La UI mostra `ChatPendingActionCard` amb preview.
3. L'usuari confirma → CF `applyAIChatProposal` verifica token, comprova `jti` no consumit, executa `runCreateIncident`, marca proposta consumida.

**Important:** les escriptures reals **no** són tools directes del model; sempre passen per confirmació explícita.

### 7.5 UI del xat

- Ruta: `/chat` (`ChatPage`).
- Components: sidebar de threads, `ChatThread`, `ChatComposer`, `ChatMessageBubble`, `ChatUiBlockRenderer` (gràfics), `ChatPendingActionCard`.
- Hooks: `useChatThreads`, `useChatMessages`, `useSendChatMessage`, `useApplyChatProposal`.

### 7.6 Features del payload del missatge assistant

```typescript
payload: {
  uiBlocks?: ChartBlock[];      // resultat de render_chart
  pendingActions?: Proposal[];    // propostes d'escriptura pendents
  toolCallsExecuted?: string[];
}
```

---

## 8. Problemes detectats i solucions

Aquesta secció recull bugs reals trobats durant la implementació. **Una altra IA hauria de tenir-los en compte abans de replicar el disseny.**

### 8.1 `model must be a string` al xat

**Símptoma:** `generateAIChatTurn` falla amb `invalid-argument: model must be a string`.

**Causa:** El client enviava `model: undefined`. En serialitzar a JSON via Firebase Callable, `undefined` es converteix en **`null`**, i el backend rebutjava `model != null && typeof model !== "string"`.

**Solució:**
- Frontend (`useSendChatMessage`): només incloure `model` al payload si és `string` no buida.
- Backend (`generate-ai-chat-turn.ts`): tractar `null` com «sense override» (`modelOverride: typeof model === "string" ? model : undefined`).

**Lliçó:** En APIs Firebase Callable, **mai enviar camps opcionals com `undefined`**; o bé ometre la clau o enviar només strings vàlides.

---

### 8.2 Gemini rebutja schemas amb `additionalProperties`

**Símptoma:** Error del proveïdor Gemini en function calling.

**Causa:** Les tools usen JSON Schema estricte amb `additionalProperties: false` (correcte per OpenAI/Anthropic). L'API de Gemini **no accepta** aquest camp als `function_declarations`.

**Solució:** `sanitizeSchemaForGemini()` a `ai-provider-tools.ts` — elimina recursivament `additionalProperties` abans d'enviar schemas a Gemini. Mantenir el schema complet per als altres proveïdors.

**Lliçó:** Cal una capa d'adaptació per proveïdor; no assumir paritat de JSON Schema entre OpenAI, Anthropic i Gemini.

---

### 8.3 Model per defecte del xat no s'aplicava

**Símptoma:** El xat usava un model antic o buit tot i haver canviat el model a Settings.

**Causes múltiples:**
1. `defaultModels.chat` no existia al metadata (només `content`); threads creats abans quedaven amb model vell.
2. La UI de settings no sincronitzava `chat` amb `content` en guardar.
3. `resolveAIModel` no prioritzava bé `content` per a la feature `chat`.

**Solució:**
- `normalizeDefaultModels()`: si no hi ha `chat` explícit, `chat = content`.
- `resolveAIModel` per `feature === "chat"`: provar `[defaultModels.content, defaultModels.chat]`.
- `chat-turn.service`: re-resol el model **cada torn** des de settings DB i actualitza `ai_chat_threads.model` si canvia.
- `TenantAISettingsTab`: en guardar metadata, escriure `defaultModels.chat = defaultModels.content`.

**Lliçó:** Els models per feature han de tenir **fallback explícit** i re-resolució a cada petició, no confiar només en el valor guardat al crear el thread.

---

### 8.4 Claus API i emulador

**Símptoma:** Error «AI_ENCRYPTION_KEY requerida» o claus no desxifrables entre reinicis.

**Causa:** Clau de xifrat diferent o absent entre sessions de l'emulador.

**Solució:** Definir `AI_ENCRYPTION_KEY` estable a `.env` local de functions; a l'emulador hi ha fallback determinista (`devaikey...`) només si `FUNCTIONS_EMULATOR=true`.

**Lliçó:** Documentar que canviar la clau de xifrat **invalida** totes les claus BYOK guardades.

---

### 8.5 Rate limits i falsos positius

**Símptoma:** Usuaris bloquejats per `rejected_rate_limit` sense abús real.

**Causa:** Estimació de tokens abans de la crida (`estimateRequestTokens`) pot ser conservadora amb historial llarg de xat.

**Mitigació actual:** Límits configurables per feature; rate limit per thread separat del global; missatges d'error amb `resetAt` per a UX.

**Lliçó:** Separar `requestsPerMinute` (només amb `threadId`) dels límits horaris/diaris; exposar `resetAt` al client.

---

### 8.6 Permisos de tools d'escriptura sense `role_permissions`

**Símptoma:** Tools `propose_*` no disponibles per a usuaris sense `role_permissions` configurats.

**Causa:** Lògica inicial exigia permís granular per qualsevol tool amb `risk: "write"`.

**Solució:** A `isToolAllowed`, si `ctx.permissions.length === 0` i `risk === "write"`, permetre **owner** i **manager**; lectures sempre permeses.

**Lliçó:** Definir comportament per defecte quan el tenant no ha configurat RBAC granular.

---

### 8.7 Propostes d'escriptura — seguretat

**Riscos evitats:**

| Risc | Mitigació |
|------|-----------|
| Replay de proposta | `jti` únic; `usedProposalJtis` a `ai_chat_threads.metadata` |
| Token manipulat | HMAC amb `AI_ENCRYPTION_KEY`; verificació de `tenantId`, `threadId`, `userId` |
| Expiració | TTL 15 min al token |
| Bypass del model | `apply_*` no és tool del model; només CF callable després de clic UI |

---

### 8.8 Checklist ràpid per depurar

| Símptoma | Comprovar |
|----------|-----------|
| «Authentication required» | Sessió Firebase al client |
| «Only tenant owners and managers…» | Rol i `site_id` del membre |
| «No API key configured» | `ai_configs.has_api_key` per al proveïdor actiu |
| «AI disabled» | `policies.enabled` i `member.settings.ai.enabled` |
| «Model not allowed» | Intersecció `availableModels` ∩ `allowedModels` |
| Rate limit | `ai_rate_limits` + missatge `AI_RATE_LIMIT:...|resetAt=...` |
| Tools no es criden | `siteId` al thread (algunes tools requereixen site) |
| Gemini function calling | `sanitizeSchemaForGemini` aplicat |

---

## 9. Adaptació a Supabase (PostgreSQL)

Aquesta app usa **Firebase Auth + Cloud Functions + Data Connect** sobre PostgreSQL. Per una app similar a **Supabase**:

### 9.1 Mapatge de components

| Aquest projecte | Equivalent Supabase |
|-----------------|---------------------|
| Firebase Auth `uid` | `auth.users.id` (UUID) |
| Cloud Functions onCall | **Supabase Edge Functions** o API server (Deno/Node) |
| Data Connect (lectura) | Client Supabase amb **RLS** o RPC `SECURITY DEFINER` |
| `tenants.metadata` JSONB | Columna `metadata jsonb` a `tenants` (mateix patró) |
| `ai_configs` xifrat | Mateixa taula; xifrat **sempre** al servidor, mai a PostgREST directe |
| `saveTenantAPIKey` | Edge Function; **no** exposar `encrypted_api_key` via API pública |

### 9.2 Row Level Security (RLS)

Exemple de polítiques recomanades:

```sql
-- ai_usage_logs: només managers del tenant
CREATE POLICY ai_usage_logs_select ON ai_usage_logs
  FOR SELECT USING (
    tenant_id IN (
      SELECT tenant_id FROM tenant_members
      WHERE user_id = auth.uid() AND role IN ('owner', 'manager') AND site_id IS NULL
    )
  );

-- ai_configs: cap SELECT de claus xifrades des del client
-- Només has_api_key via vista o RPC filtrada
```

**Regla:** les claus xifrades i les CF d'escriptura IA **no** han de ser accessibles via PostgREST directe.

### 9.3 Edge Functions equivalents

| CF actual | Edge Function |
|-----------|---------------|
| `saveTenantAPIKey` | `POST /ai/keys` |
| `generateAIContent` | `POST /ai/generate` |
| `generateAIChatTurn` | `POST /ai/chat/turn` |
| `applyAIChatProposal` | `POST /ai/chat/apply-proposal` |
| `updateTenantAIPolicies` | `POST /ai/policies` |

Compartir la mateixa llibreria de governança (`prepareAIGovernance`, `ai-rate-limiter`) entre functions.

### 9.4 Rate limits a Supabase

El patró UPSERT a PostgreSQL funciona igual amb `pg` o el client server-side de Supabase. No cal Redis inicialment.

Alternativa futura: **Upstash Redis** per comptadors si el volum ho exigeix.

### 9.5 Secrets

| Secret | On |
|--------|-----|
| `AI_ENCRYPTION_KEY` | Supabase Vault / secrets de Edge Functions |
| Claus BYOK del tenant | PostgreSQL xifrades (no Vault) |

### 9.6 Realtime (opcional)

Supabase Realtime sobre `ai_chat_messages` pot substituir el polling de `useChatMessages`. Mantenir l'escriptura només via Edge Function.

---

## 10. Ordre d'implementació recomanat (greenfield)

Per replicar el sistema en una altra app:

1. **Fase BYOK:** taula `ai_configs`, xifrat, `saveTenantAPIKey`, UI settings bàsica.
2. **Fase generació:** `generateAIContent` + prova de connexió reutilitzant la mateixa CF.
3. **Fase observabilitat:** `ai_usage_logs` sense enforcement (veure ús real).
4. **Fase permisos:** polítiques tenant/membre, `prepareAIGovernance` (disabled, model).
5. **Fase rate limits:** `ai_rate_limits`, errors estructurats.
6. **Fase dashboard:** agregacions, CSV, `audit_logs` de governança.
7. **Fase xat:** threads/missatges, `generateAIChatTurn`, tools de lectura.
8. **Fase escriptures:** `propose_*` + confirmació UI + `apply_*`.

No saltar directament al xat sense governança: és molt més difícil afegir límits a posteriori sense forats de seguretat.

---

## 11. Fitxers clau al repositori

| Àrea | Fitxers |
|------|---------|
| Xifrat i settings | `functions/src/ai/ai.service.ts` |
| Límits | `functions/src/ai/ai-limits.ts`, `ai-rate-limiter.ts` |
| Governança | `functions/src/ai/ai-governance.service.ts` |
| Generació contingut | `functions/src/ai/generate-ai-content.ts` |
| Proveïdors | `functions/src/ai/ai-providers.ts`, `ai-provider-tools.ts` |
| Xat | `functions/src/ai/chat/chat-turn.service.ts`, `generate-ai-chat-turn.ts` |
| Propostes | `functions/src/ai/chat/proposal-token.ts`, `apply-ai-chat-proposal.ts` |
| Tools | `functions/src/ai/tools/` |
| Schema DB | `dataconnect/schema/schema.gql` (AIConfig, AIUsageLog, AIRateLimit, AIChat*) |
| UI settings | `apps/tenant-portal/src/components/settings/TenantAISettingsTab.tsx` |
| UI ús | `apps/tenant-portal/src/components/settings/TenantAIUsagePanel.tsx` |
| UI xat | `apps/tenant-portal/src/pages/ChatPage.tsx` |
| Tipus frontend | `apps/tenant-portal/src/types/ai.ts`, `types/chat.ts` |

---

## 12. Comandes operatives

```powershell
# Migracions SQL (si cal)
firebase dataconnect:sql:migrate

# Tests de governança i tools
cd functions && npm run test

# Build frontend
cd apps/tenant-portal && npm run build

# Reiniciar emulador Functions després de nous exports (applyAIChatProposal, etc.)
```

---

*Document viu: actualitzar aquest README quan s'afegeixin features (P3–P5 xat, MCP, multimodal).*
