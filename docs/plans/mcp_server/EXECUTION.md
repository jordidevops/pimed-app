# MCP Server — Pla mestre d’execució (agent IA)

> **Rol:** única font de veritat de l’ordre d’implementació i del treball pendent  
> **Creat:** 2026-09-15  
> **Pla:** [`README.md`](./README.md) · estat: [`STATUS.md`](./STATUS.md) · acceptació: [`04-acceptance-and-gates.md`](./04-acceptance-and-gates.md)  
> **Fase activa:** **MCP-0** Disseny i threat model  
> **Anterior:** — (pla documental)

---

## Disciplina (obligatòria per a l’agent)

1. Llegir **aquest fitxer** i [`STATUS.md`](./STATUS.md) a l’**inici de cada conversa** d’implementació.
2. Treballar **només** la fase activa, o un ítem de backlog acordat **explícitament** per l’usuari.
3. No reobrir decisions de [`README.md`](./README.md) § «Decisions tancades» sense documentar-ho abans al changelog.
4. Preferir editar la migració font mentre no hi hagi producció (evitar fixups additius innecessaris).
5. En tancar un epic:
   - Marcar ✅ / ⚠️ a [`STATUS.md`](./STATUS.md)
   - Afegir fila al **Registre de treball** (abaix)
   - Avançar la **Fase activa** aquí
   - Verificar criteris de [`04-acceptance-and-gates.md`](./04-acceptance-and-gates.md)
6. Qualsevol canvi de cicle de vida → `data.audit_logs` (veure copilot-instructions).
7. No commit ni push tret que l’usuari ho demani.
8. No exposar tools write ni acceptar JWT de sessió “per comoditat de dev” a l’endpoint públic.

### Prompt mínim de continuació

```
Continua el pla MCP a docs/plans/mcp_server/.
Llegeix EXECUTION.md + STATUS.md. Implementa només la fase activa.
Al acabar: actualitza STATUS, registre d'EXECUTION i criteris d'acceptació.
```

---

## Ordre real

| Ordre | Epic | Estat | Nota |
|------:|------|-------|------|
| 1 | **MCP-0** Disseny / threat model / allowlist tools | ❌ | **Fase activa** |
| 2 | **MCP-1** DDL + RLS + purge | ❌ | |
| 3 | **MCP-2** Feature flags + kill switch + helper efectiu | ❌ | |
| 4 | **MCP-4** Edge skeleton Streamable HTTP + pre-auth | ❌ | Pot anar en paral·lel parcial amb MCP-3 |
| 5 | **MCP-5** Auth API key S2S | ❌ | Tall A |
| — | *Gate Tall A → B* | ❌ | Key + tool dummy + aïllament |
| 6 | **MCP-3** OAuth Server + consent + PRM | ❌ | |
| 7 | **MCP-6** Auth OAuth runtime + grants | ❌ | Tall B |
| — | *Gate Tall B → C* | ❌ | OAuth E2E |
| 8 | **MCP-7** Tools read-only MVP | ❌ | |
| 9 | **MCP-8** tenant-portal UI | ❌ | |
| 10 | **MCP-9** admin-portal UI | ❌ | Tall C |
| — | *Gate Tall C → D* | ❌ | |
| 11 | **MCP-10** audit_logs + runbook + alertes | ❌ | |
| 12 | **MCP-11** WAF + rate limit distribuït + load test | ❌ | |
| 13 | **MCP-12** Canary + Go/No-Go | ❌ | Tall D |

Nota: MCP-3 apareix després de MCP-5 a l’ordre **operatiu** perquè el Tall A valida primer el camí S2S (més simple) abans d’obrir OAuth; el disseny de DDL (MCP-1) ja inclou `mcp_client_grants`.

---

## Fase activa: MCP-0 — Disseny

### Objectiu
Tancar el contracte abans de migracions: riscos, URL, tools públiques, números de load test.

### Tasques concretes (checklist agent)

- [ ] Releer [`01-architecture-and-security.md`](./01-architecture-and-security.md) i [`02-data-model.md`](./02-data-model.md).
- [ ] Escriure threat model curt (secció nova a `01-…` o annex `threat-model.md`).
- [ ] Proposar allowlist MVP (1–3 tools) amb columnes exposades i notes GDPR; demanar OK humà si cal.
- [ ] Fixar shape d’URL del resource (`MCP_PUBLIC_URL` + path per tenant).
- [ ] Fixar llindars preliminars load test (RPS, error rate, p95) per Gate MCP-11.
- [ ] Confirmar: DCR OAuth **desactivat** en prod fins canary (default del pla).

### Criteri de tancament
Gate 0 de [`04-acceptance-and-gates.md`](./04-acceptance-and-gates.md) complet.

### Següent
MCP-1 DDL.

---

## Plantilla per fases posteriors (l’agent omple en avançar)

Quan s’activi una fase, substituir la secció «Fase activa» amb:

### Objectiu
…

### Fitxers / zones típiques
- `supabase/migrations/…`
- `supabase/functions/mcp_…` (o nom final)
- `apps/tenant-portal/…`
- `apps/admin-portal/…`

### Tasques
- [ ] …

### Proves
- [ ] …

### Fora d’abast d’aquesta fase
…

---

## Guia ràpida per fase (referència)

### MCP-1
Crear migracions segons [`02-data-model.md`](./02-data-model.md); RLS grants; índexs; comment headers.

### MCP-2
Seeds flags `mcp_*`; helper d’avaluació efectiva; documentar ordre kill switch → flag → override → tenant settings.

### MCP-4
Edge Function: transport MCP SDK Web Standard, limity body, CORS allowlist, logging estructurat, `verify_jwt=false`.

### MCP-5
Creació segura de keys (secret un cop); verify hash; tests aïllament.

### MCP-3 + MCP-6
Habilitar OAuth server Supabase; consent; PRM; validate `client_id`; grants; tests confused deputy.

### MCP-7
Registrar només tools allowlist; context injectat; tests.

### MCP-8 / MCP-9
UI i18n (`t(key, 'fallback ca')`); feature flag meta a admin; dashboards usage.

### MCP-10
`audit_logs` actions llistades a `02-data-model`; runbook markdown.

### MCP-11 / MCP-12
Proxy + Upstash/WAF; load; canary; Go/No-Go.

---

## Registre de treball

| Data | Epic | Què s’ha fet | Què ha quedat pendent |
|------|------|--------------|------------------------|
| 2026-09-15 | — | Paquet documental pla MCP (README, 01–04, EXECUTION, STATUS); decisions auth híbrida | MCP-0 |
