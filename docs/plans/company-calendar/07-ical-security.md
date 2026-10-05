# 07 — iCal: seguretat (SaaS multi-tenant)

> Pla futur V2.5. **No implementat.**  
> Com funciona: [`06-ical-how-it-works.md`](./06-ical-how-it-works.md) · Arquitectura: [`08-ical-architecture-and-phases.md`](./08-ical-architecture-and-phases.md)

## Amenaça principal

Un feed subscribe és un **GET sense cookie de sessió**. La URL conté un **secret** (token). Qui la posseeix pot llegir el calendari de l’usuari (dins l’abast del token) fins que es revoqui o caduqui.

Això **no** és equivalent a «RLS del JWT del navegador». Un Edge Function públic **no** executa les policies de `api.calendar_events` amb `auth.uid()` de l’usuari final tret que el dissenyem així explícitament — i amb `service_role` **bypass** RLS.

### Autenticació vs autorització (no barrejar)

| Concepte | Mecanisme a l’MVP |
|----------|-------------------|
| **Autenticació del feed** | Token secret a la query (`?token=`). Prova que el caller «té el link». |
| **Autorització de dades** | RPC `SECURITY DEFINER` que, un cop validat el token, **reimplementa** les regles de visibilitat (tenant membership, `calendar.view`, site context del feed, scope `mine`) i retorna files. **No** `SELECT` anon sobre la vista. |

Dir «mateixa autoritat que RLS» vol dir: **mateix resultat observable** que l’usuari veuria a `/calendar` amb la seva sessió, no «activem RLS magicament».

## Decisions de control d’accés (fixes)

### 1. Opt-in del tenant (settings engine)

- Clau registrada: `calendar.ical_enabled` (boolean, defecte `false`) a `data.settings_registry`, scope **tenant**, permís `settings.manage` (o el que usi Config per settings sensibles).
- **No** usar `feature_flags` / plans a l’MVP (evita doble mecanisme; el calendari ja es governa per RBAC `calendar.*`).
- Si `calendar.ical_enabled` és fals:
  - `create_*` → error `ical_disabled`
  - `resolve_*` / Edge → **403** (cos buit o text curt; no filtrar si el tenant existeix)

### 2. Qui pot crear un feed

- Usuari autenticat amb membership al tenant **i** permís efectiu `calendar.view`.
- Màxim **2 feeds actius per usuari i tenant** (p.ex. un `all_visible` + un `mine`). Crear el tercer exigeix revocar abans.
- El plaintext del token es mostra **una sola vegada** a la UI; a BD només `token_hash`.

### 3. Qui pot revocar

| Actor | Acció |
|-------|--------|
| Propietari del feed (`user_id`) | Revocar el seu feed |
| `calendar.manage` al tenant (o owner/manager amb settings) | Revocar qualsevol feed del tenant |
| Tenant disable `calendar.ical_enabled` | Tots els resolves fallen; feeds queden «zombi» fins a purge opcional |

### 4. Caducitat i rotació

- `expires_at` **obligatori** al crear: defecte **now() + 365 days**.
- Rotació = `revoke` + `create` (nou token, nova URL; els clients s’han de reenganxar).
- Token caducat o revocat → 403.

### 5. Emmagatzematge del secret

Patró: [`customer_report_shares`](../../../supabase/migrations/20261159000027_customer_report_shares_cpa2.sql)

- Secret: 32 bytes → hex 64 chars.
- BD: `token_hash bytea` = SHA-256 del secret (helper tipus `data.hash_customer_portal_secret` o equivalent compartit).
- **Mai** guardar el plaintext.
- `list_*` **mai** retorna hash ni secret.
- Logs / audit: prefix del token (p.ex. 8 hex) com a màxim; mai el secret sencer.

### 6. Endpoint públic

- Edge Function `verify_jwt = false`.
- Només mètode GET.
- HTTPS obligatoriu en producció.
- Cap redirect a URLs amb el token a query en clar cap a tercers.
- Resposta: `200` + `Content-Type: text/calendar; charset=utf-8` o `401`/`403`/`404` sense leak d’existència de tenant si es pot unificar a 403.

### 7. Cache i polling

- `Cache-Control: private, no-store` (o `max-age=300` **privat** si cal alleujar; MVP preferible `no-store`).
- `last_accessed_at`: actualitzar **com a màxim un cop cada 15 minuts** per token (evitar write amplification per poll agressiu).

### 8. Rate limiting (concret)

| Capa | Política MVP |
|------|----------------|
| Edge | Per IP: p.ex. 60 req/min; per token: 30 req/min (valors inicials; ajustar). Resposta 429. |
| RPC resolve | Opcional: rebutjar si `last_accessed_at` massa freqüent **després** del throttle Edge (defensa en profunditat). |

Implementació: middleware/observability de l’Edge (patró del repo) o store en memòria/KV; documentar al runbook.

### 9. Contingut i minimització

Veure llista blanca a [`06`](./06-ical-how-it-works.md). No afegir camps «per si de cas». Scope `mine` usa el contracte de [`05-mine-events-contract.md`](./05-mine-events-contract.md) **al servidor** (incloent join a `tasks.assignee_id`), no el hook del client.

## Amenaces i mitigació

| Amenaça | Mitigació |
|---------|-----------|
| URL filtrada (email, Slack, captura) | Revocació 1-click; caducitat 365d; educació UI |
| Token a logs del proxy | No loguejar query string completa; redact |
| Enumeració de tokens | 64 hex d’entropia; rate limit; mateix 403 |
| Privilege escalation (veure altre tenant) | `tenant_id` del feed row; membership check a resolve |
| Privilege escalation (veure més que `/calendar`) | Tests SQL parity; mateixes regles que vista + mine |
| Tenant apaga iCal però URLs velles | resolve comprova setting + revoked/expired |
| XSS al portal que llegeix token | Mostrar secret un cop; no deixar-lo al DOM persistent |

## DoD de seguretat (testeable)

Abans de donar V2.5 per fet, aquests tests han de passar (SQL i/o Edge):

1. Token vàlid + tenant `ical_enabled` → 200 ICS amb només events autoritzats.  
2. Token revocat → 403.  
3. Token caducat → 403.  
4. Tenant `ical_enabled = false` → 403 encara amb token vàlid.  
5. Usuari A no veu events exclusius de B (fixture multi-user).  
6. Scope `mine`: manual aliè exclòs; manual propi inclòs; project exclòs; task només si assignee.  
7. `list_my_calendar_ical_feeds` no conté `token` ni `token_hash`.  
8. Create sense `calendar.view` → forbidden.  
9. Create amb 2 feeds actius → tercer falla.  
10. Audit log en create i revoke.

## Runbook (operacions)

1. **Token filtrat:** usuari o admin revoca el feed; crear-ne un de nou; reenganxar clients.  
2. **Incident tenant:** `calendar.ical_enabled = false`; opcionalment revoke massiu per RPC admin.  
3. **Abús de polling:** baixar límits Edge; revisar `last_accessed_at`.  
4. **Rotació preventiva anual:** UI avisa si `expires_at < 30d`.

## Consentiment / UX

- Text explícit al crear: «Qui tingui aquest enllaç pot veure els events d’aquest feed.»  
- Checkbox o confirmació abans de mostrar el secret.  
- Enllaç a ajuda: diferència vs Agenda FSM; refresh no instantani.
