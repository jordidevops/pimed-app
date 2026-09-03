# REC-7 — Activació Inbound email (runbook)

> **Estat MVP (2026-07-24):** operable **sense** Resend Inbound real (ingest stub + UI + RPCs).  
> Aquest document descriu **què ja funciona**, **què falta** i **com activar** Inbound a staging/prod.

Pla de producte: [`03-email-inbound-and-ai.md`](./03-email-inbound-and-ai.md) · Execució: [`EXECUTION.md`](./EXECUTION.md)

---

## Què està fet (MVP)

| Peça | Detall |
|------|--------|
| Taula `data.recruitment_email_inbox` | Estats `unassigned` / `assigned` / `discarded` |
| Settings | `inbound_enabled` (default false), `inbound_address_hint` |
| `api.ingest_recruitment_inbound_email` | **service_role** (+ postgres tests). Desa missatge; auto-assign si subject `[posting:<uuid>]` o `posting_id` al payload |
| `api.assign_recruitment_inbox_item` | RRHH assigna a oferta → `applications.source=email` + Art. 14 |
| `api.discard_recruitment_inbox_item` | Descarta |
| `api.list_recruitment_email_inbox` | Llista per estat |
| UI | `/recruitment/inbox` — safata assignar / descartar |
| Edge | `supabase/functions/receive-recruitment-email` — Svix + ingest (llesta, **no** cal desplegar encara) |
| Tests | `supabase/tests/recruitment_inbound_rec7_tests.sql` |

Proves locals: cridar ingest via SQL/service_role amb `tenant_id` al payload (sense Resend).

---

## Què falta (go-live)

1. **Compte / producte Resend Inbound** (receiving) habilitat al projecte Resend.
2. **MX / forward** del domini del tenant (o adreça compartida PiMed) cap a Resend Inbound.
3. **Webhook** Resend → URL de l’Edge Function desplegada.
4. **Secret Svix** `RESEND_INBOUND_WEBHOOK_SECRET` als Secrets de Supabase.
5. **Mapa mailbox → tenant** robust (avui: stub `tenant_id` al payload, header `X-Tenant-Id`, o best-effort `inbound_address_hint`).
6. **Plus-alias** `feina+{slug}@…` (parser no implementat; només tag subject).
7. **Descarrega d’adjunts** Resend → upload a `recruitment-cvs` (path `inbound/...`) dins l’Edge.
8. Desplegar EF + smoke amb correu real.

La dependència a `EXECUTION.md` (**Resend Inbound**) segueix ⬜ fins a completar 1–4 + smoke.

---

## Com activar (checklist)

### A. Plataforma (un cop)

1. Resend Dashboard → Inbound: crear receiving domain / address.
2. Configurar DNS MX (i SPF/DKIM segons Resend).
3. Crear webhook d’events inbound apuntant a:
   ```
   https://<project-ref>.supabase.co/functions/v1/receive-recruitment-email
   ```
4. Copiar signing secret (`whsec_…`) →
   ```bash
   supabase secrets set RESEND_INBOUND_WEBHOOK_SECRET=whsec_xxx --project-ref <ref>
   ```
5. Desplegar la funció:
   ```bash
   supabase functions deploy receive-recruitment-email --project-ref <ref>
   ```
6. Confirmar a `supabase/config.toml` (o Dashboard):
   ```toml
   [functions.receive-recruitment-email]
   verify_jwt = false
   ```
   (Resend no envia Bearer JWT; sense això el webhook falla amb 401.)
7. Verificar que `SUPABASE_SERVICE_ROLE_KEY` està disponible a l’entorn de functions (estàndard del projecte).

### B. Per tenant

1. Feature flag `recruitment_enabled` = on.
2. Settings reclutament:
   - `inbound_enabled` = on
   - `inbound_address_hint` = adreça publicada (ex. `feina@empresa.com`) — matching best-effort fins al mapa formal
3. Base legal import (`import_legal_basis`) configurada (Art. 14 reutilitza la mateixa).
4. Opcional: comunicar als candidats el subject tag  
   `Apply [posting:<job_posting_uuid>]` per auto-assign.

### C. Smoke

1. Enviar correu de prova **sense** tag → fila `unassigned` a `/recruitment/inbox`.
2. Assignar a una oferta → `applications.source=email` + Art. 14 encuat.
3. Enviar correu **amb** `[posting:<uuid>]` vàlid → `assigned` automàtic.
4. Reenviar el mateix `resend_email_id` → `duplicate: true` (no dobles files).

---

## Resolució de tenant (disseny previst)

| Fase | Mecanisme |
|------|-----------|
| **MVP stub** | `p_payload.tenant_id` (tests / ingest manual) |
| **Edge avui** | `data.tenant_id` \| header `X-Tenant-Id` \| match `to` ≈ `inbound_address_hint` (tenants amb `inbound_enabled`) |
| **Post-MVP** | Taula `recruitment_inbound_mailboxes (address, tenant_id)` o columna dedicada; plus-alias `local+slug@domain` → `job_postings.public_slug` |

Sense resolució → Edge respon `200` amb `processed: false` / `tenant_unresolved` (no reintenta eternament amb error 5xx).

---

## Plus-alias (no implementat)

Disseny previst (mateix resultat que el tag subject):

- Adreça `feina+{public_slug}@inbound.example.com`
- Parser a l’Edge / RPC: extreu `public_slug`, cerca `job_postings` del tenant, auto-assign

Documentat aquí perquè no es confongui amb una arquitectura alternativa: és només un accelerador del mateix inbox.

---

## Seguretat

- Ingest RPC: **només** `service_role` (no `authenticated` / browser).
- Edge: verificació Svix obligatòria; sense secret → `503`.
- Flag `recruitment_enabled` + (a l’Edge) `inbound_enabled` per tenant.
- Vista API de l’inbox **sense** `raw_payload`.
