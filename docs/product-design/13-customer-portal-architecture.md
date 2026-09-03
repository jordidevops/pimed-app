# 13. Customer Portal — Arquitectura i model de compartició segura

> **Estat:** alineat amb el pla executable [`docs/plans/custom-portal/README.md`](../plans/custom-portal/README.md) (**CP-C**, 2026-08-05).  
> **Control:** [`STATUS.md`](../plans/custom-portal/STATUS.md) · [`EXECUTION.md`](../plans/custom-portal/EXECUTION.md).  
> **Objectiu:** butlletí immutable + portal persistent centrat en el **compte contacte** (empresa o persona). Publicació ⊥ visibilitat portal ⊥ lliurament.

Aquest document **substitueix** el disseny antic basat en `share_links` UUID a `*.public.{platform-domain}`, models `uuid_only` / password i taula genèrica `customer_shares`. Aquell model no cobreix sessió, rate limit fail-closed, media immutable ni grants multi-persona.

---

## 13.1 Separació de superfícies

| Superfície | Rol | No fa |
|---|---|---|
| `apps/tenant-portal` | Publicar, compartir, revocar, preview fidel, «veure com el client» | Exposar contingut al client directament |
| `apps/customer-portal` | BFF + reader HTML + dashboard Fase B; sessió opaca | JWT Supabase al navegador; queries PostgREST directes |
| Edge resolver dedicada | Única posseïdora de `service_role` per resolució | Operacions internes arbitràries del tenant |
| `apps/public-portal` | Marketing SEO, empleat, recruitment, etc. | Rutes privades de client |

### Diferència amb Public Portal

| Aspecte | Public Portal | Customer Portal |
|---------|---|---|
| Audiència | Visitants, leads | Destinataris d'un tenant (persona + empresa) |
| Indexació | SEO | `Disallow: /`, noindex |
| Auth | Forms públics / PIN empleat | Bearer share → sessió BFF; Fase B magic link → sessió BFF |
| Dades | Contingut marketing / CMS | Projecció allowlist de butlletins (després més mòduls) |
| Host | `*.public.{platform-domain}` + CNAME | `{tenant}.customer.{platform-domain}` + CNAME verificat |

---

## 13.2 Fases de producte

### Fase A — Butlletí immutable + share

1. Staff tanca la visita (close-out ≠ publicació).
2. Cura un draft; publica una **versió immutable** (HTML/JSON allowlist + còpies de media).
3. Crea un `customer_report_share` (secret 256-bit, només hash persistit).
4. Client obre el link al customer-portal; el BFF intercanvia el token per cookie opaca i serveix el reader.
5. Revocació / kill-switch / expiració invaliden sessió i media proxy.

### Fase B / CP-C — Portal persistent centrat en el contacte

1. Accés gestionat a la fitxa/hub de Contactes (no Settings com a CRUD).
2. Grant = `(auth_user_id, tenant_id, client_account_contact_id, principal)` amb principal nominatiu o bústia compartida.
3. Dashboard: totes les versions publicades del **compte**, no filtrades per destinatari de publicació.
4. **No** `tenant_members` ni `app_role='customer'` escalar; sessió BFF opaca.
5. Possessió d'un link puntual **mai** concedeix dashboard.

Detall: pla [`custom-portal/README.md`](../plans/custom-portal/README.md).

---

## 13.3 Domini i host

1. **Defecte:** `{tenant-slug}.customer.{platform-domain}` (wildcard DNS).
2. **Opcional:** CNAME del tenant cap a la plataforma, només si el domini està **verificat** al registre.
3. El host resol el `tenant_id`; share/versió/grant/media han de coincidir amb aquell tenant en una sola consulta autoritzada.
4. Un token **no** és portable entre dominis de tenants.
5. Callback d'auth (Fase B) a domini de sistema allowlisted → handoff single-use → cookie host-only al domini verificat.

---

## 13.4 Model de dades (orientatiu)

Font de veritat detallada: pla custom-portal. Resum:

| Concepte | Taules / artefactes |
|---|---|
| Compte / punts / regles | `contact_relationships`, `contact_delivery_channels`, `contact_delivery_rules` |
| Butlletí | `customer_intervention_reports`, `_drafts`, `_versions` (sense recipient; account scope) |
| Media | Bucket privat `customer-report-media` (còpia immutable, no-overwrite) |
| Share puntual | `customer_report_shares` (hash), `customer_portal_share_sessions`, delivery intents |
| Staff view | `customer_portal_staff_sessions` (versió **o** compte) |
| Estat / kill-switch / BCC | `customer_portal_tenant_state` (+ `bulletin_bcc_emails`) |
| Logs | `customer_report_share_access_logs` particionats mensualment |
| Portal persistent | `customer_access_invitations`, `customer_access_grants` (account + principal) |
| Entitlements | `plans.portal_entitlements.customer_portal` + snapshot tenant |

Compatibilitat: `projects.client_report_published_at/_by` es projecta des de l'agregat; escriptura directa prohibida després del dual-read.

---

## 13.5 Seguretat (contracte mínim)

| Control | Requisit |
|---|---|
| Token | 256-bit aleatori; SHA-256 només a BD; revelat una vegada |
| Sessió | Cookie host-only, HttpOnly, Secure, SameSite=Lax; revalidació live |
| Resolució | Edge privilegiada; RPCs privades sense EXECUTE per `anon`/`authenticated` |
| Rate limit | Distribuït fail-closed (no fallback local per instància) |
| Media | Proxy BFF amb revalidació; sense signed URLs que sobrevisquin a revocació |
| Kill-switch | Tenant + plataforma; increment O(1) de `security_version` |
| Staff | Preview fidel al tenant-portal o sessió scoped; mai viewer de tots els clients |
| Contingut | Sanitizer allowlist al servidor; mai HTML ric intern sense filtrar |

Amenaces clàssiques (enumeració, scraping, post-revocació) es cobreixen amb hash no enumerable fàcilment, rate limit, auditoria i revalidació a cada request — no amb UUID v4 “només” com a secret.

---

## 13.6 Identitat i permisos

### Staff (tenant)

Permisos granulars (entre altres):

- `field_service.reports.publish`
- `field_service.reports.regenerate`
- `field_service.reports.share`
- `field_service.reports.revoke`
- `field_service.reports.preview_as_customer`

Operacions sensibles usen `data.require_fresh_tenant_permission` (membresia live + claims no obsolets).

### Client

- Fase A: share + sessió opaca (anònima respecte a `auth.users`).
- Fase B: `auth.users` + grant; gate al tenant-portal exigeix `tenant_members` interna activa.
- Clients **no** consumeixen `max_members`.

Vegeu també [`04-roles-and-permissions.md`](./04-roles-and-permissions.md) §4.9.

---

## 13.7 Entitlements i fair use

Canal `customer_portal` a `portal_entitlements` (contracte versionat: [`entitlements-contract.md`](../plans/custom-portal/entitlements-contract.md)):

- `included`, `mode` (`share_only` \| `portal` = superconjunt),
- `customer_users_limit: null` (il·limitat contractualment),
- guardrails de shares / MAU soft / emails.

Restriccions operatives (`new_access_policy`, kill-switch, etc.) viuen a `customer_portal_tenant_state`, no al JSON comercial.

---

## 13.8 Projecció pública i legal

- Allowlist i retenció: [`projection-and-retention.md`](../plans/custom-portal/projection-and-retention.md).
- DPA / Art. 13 / destinataris: [`legal-and-dpa.md`](../plans/custom-portal/legal-and-dpa.md).

---

## 13.9 Roadmap d'implementació

Ordre i gates: [`EXECUTION.md`](../plans/custom-portal/EXECUTION.md).

```text
CP-0 … CP-B (MVP històric)
→ CP-C rewrite: compte client + Contactes UI + publicació ⊥ lliurament + portal per compte
```

### Fora d'abast inicial

PDF adjunt, signatura client E2E, facturació/overage automàtics, dashboard multi-recurs complet, comptes email/password, migrar links antics a grants, login staff com a viewer universal.

---

## 13.10 Decisions tancades (resum)

1. App germana `apps/customer-portal`; no rutes privades a public-portal.
2. Artefacte = versió immutable; no servir `checklist_runs.public_report_payload` com a font pública.
3. Grants live, no `app_role='customer'` exclusiu.
4. BFF sense `service_role`; Edge dedicada.
5. `mode=portal` inclou shares; elecció per destinatari.
6. Vista staff scoped; no impersonació global.

7. Compte = empresa o persona; publicació sense destinatari; portal per compte.
8. Principals nominatius i bústies compartides explícites; rols de relació no són ACL.
9. Accés a Contactes; Settings = toggle/entitlements/BCC.
10. Schema: rewrite migracions + reset local mentre no hi hagi producció.
