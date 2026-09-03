# Pla d'execució — Reclutament / ATS (REC)

> **Rol:** ordre d'implementació  
> **Creat:** 2026-07-21 · **Revisió:** 2026-07-23 (REC-0…3 P2)  
> **Estat:** MVP captura implementat a codi (flag off per defecte)

## Estat ràpid

| Fase | Estat | Notes |
|------|-------|-------|
| REC-0 Legal | ✅ | Flag + Art.13 + plantilles; CMP diferit; hotfix P0+P1 + **P2** |
| REC-1 Schema | ✅ | Schema + RLS; hotfix P0+P1 + **P2** (flag RLS, HMAC grants, pgcrypto) |
| REC-2 Ofertes | ✅ | UI ofertes/QR; **P2** ≥1 public site abans de `published` |
| REC-3 Captura + purge | ✅ | Apply + CV; hotfix P0+P1 + **P2** (idempotency, purge drain) |
| REC-4 Pipeline | ✅ | Tall 1 + 4b + **hotfix P0** + **P1–P2** (notes RLS, CSV escape, site scope, UI etapes) |
| REC-5 Drets / rebuig | ✅ | Tall 2 + **5b** + **5c** + **hotfix P0** + **P1–P2** |
| REC-12 CSV import | ✅ | Art. 14 + base legal configurable; `import_applications_bulk` |
| REC-6 Hire | ✅ | `hire_application` → employee onboarding + email hired_next_steps; **hotfix P1** + **P2** (locale + gate) |
| REC-11 Analytics | ✅ | `get_recruitment_analytics` + k-anonymity; hotfix flag gate |
| REC-7 Inbound | ✅ MVP | Inbox + assign/discard + ingest stub; Resend Inbound go-live ⬜ ([runbook](./rec7-inbound-activation.md)) |
| REC-8 IA | ✅ MVP | Checklist DPA/transfer + estructurar CV (propose/confirm); matching/redacció/resum ⬜ |
| REC-F1 OCR CV | ⬜ | Post-MVP: Tesseract contenidoritzat, cua i add-on de plans alts |

## Ordre (regla d’or Art. 13)

**No es pot mostrar al candidat “s’esborrarà en X mesos” fins que el cron de purge existeixi i `default_max_retention_months` estigui seedat.**

Per això:

1. **REC-0 + REC-1** junts (settings retenció `NOT NULL DEFAULT 12` + schema + cron job en idle o actiu).
2. **REC-2 → REC-3** amb cron **operatiu** el mateix dia que el formulari públic amb preferències de retenció.
3. **REC-4 → REC-5** (selecció + drets avançats; purge ja corre des de REC-3 per sostre i `delete_after_months`).
4. `delete_on_process_end` complet (depèn de `process_closed_at`) pot madurar a REC-5, però el sostre de 12 mesos **ja s’aplica** des de REC-3.
5. REC-12, REC-6, REC-11, REC-7, REC-8 després. REC-F1 queda després de REC-8 i no bloqueja l'extracció de text de PDFs digitals.

## Dependències

| Dependència | Estat | Impacte |
|-------------|-------|---------|
| ELM onboarding | ✅ | REC-6 |
| Public portal | ✅ | REC-3 |
| enqueue_email | ✅ | Tot |
| EHR-6 checklists | ⬜ | Hire sense checklist rica |
| Resend Inbound | ⬜ | REC-7 go-live; MVP stub OK — [rec7-inbound-activation.md](./rec7-inbound-activation.md) |
| Vault tenant secrets | ✅ | HMAC erasure_log, DPA keys IA |
| Microservei OCR Tesseract | ⬜ | REC-F1; contenidor, autenticació interna, límits de recursos i observabilitat |
| Add-on OCR plans alts | ⬜ | REC-F1; elegibilitat tenant, quota i facturació |

## Criteris d’acceptació globals

- [x] `default_max_retention_months` NOT NULL; cap `purge_at` infinit.
- [x] Purge per `application`; `applicant` només si no queden apps ni talent pool.
- [x] CV a `applications`.
- [x] Portal open/closed només via `outcome_communicated_at` (BD) — columna generada `candidate_visible_status`.
- [x] Estat `unlisted` ≠ tancament de procés.
- [x] `archived` (i `expired` si flag) dispara tancament + correus pendents. *(REC-5 tall 2; policy `on_posting_close`)*
- [x] Cap PII al portal candidat (open/closed només). Export Art. 15 per correu + `recruitment.rights` = **REC-5b** ✅.
- [x] Analytics: cohorts &lt; 5 ocultes al servidor. *(REC-11)*
- [x] Import CSV: Art. 14 + base legal configurable. *(REC-12)*
- [x] Export CSV: advertència + signed URL TTL + audit post-upload (sense `csv_text` al client) — **REC-4 hotfix P0**. *(import = REC-12)*
- [x] `erasure_log` documentat com a pseudonimització (HMAC), no anonimització.
- [x] Formulari públic no promet retenció abans que el cron estigui desplegat.
- [x] MVP CV: només s'extreu localment la capa de text dels PDFs digitals; PDFs escanejats i imatges resten per revisió humana. *(REC-8)*
- [ ] OCR de PDFs escanejats/imatges és post-MVP, s'executa amb Tesseract en microservei contenidoritzat via cua i requereix l'add-on de plans alts.

## Smoke checklist (REC-0…3)

1. Aplicar migracions `20261106000001` … `20261110000001` (`migration up` / reset).
2. Activar flag: `tenant_feature_overrides` / override `recruitment_enabled = true` per al tenant de prova.
3. Tenant portal → **Reclutament**: crear oferta, vincular public site, estat `published`, desar.
4. Copiar URL / generar QR (`?src=qr`) / WhatsApp (`?src=whatsapp`).
5. Public portal `/{siteSlug}/{locale}/careers` → detall → apply amb CV, checkbox Art.13 i radio retenció.
6. Comprovar fila a `applications` amb `cv_storage_path`, `purge_at` finit (≤ 12 mesos) i `source` correcte.
7. Obrir enllaç de verify del correu (`/recruitment/verify?token=…`) → `email_verified_at` omplert.
8. Confirmar job `pg_cron` `recruitment-purge-expired-applications` (`15 3 * * *`) **en entorns amb `pg_cron`** (staging/prod). En local Docker el projecte no depèn del scheduler: la migració només fa `cron.schedule` si l’extensió existeix; la funció `data.purge_expired_applications()` es pot invocar a mà per smoke.
9. Tests SQL: `supabase/tests/recruitment_ats_rec1_tests.sql` → **PASS** (purge_at, visible_status, dedupe, settings, list_public).

### Smoke local (2026-07-22)

| Check | Resultat |
|-------|----------|
| Migracions 20261106–10 | ✅ aplicades |
| Tests SQL REC-1 | ✅ 5/5 PASS |
| Flag off global + override tenant | ✅ (`Beta Startup`) |
| submit + `source=qr` + `purge_at` ≤12m + CV path | ✅ |
| `verify_applicant_email` | ✅ |
| `purge_expired_applications()` callable | ✅ (0 files caducades) |
| Cron job diari | ➖ no aplica en local Docker (sense scheduler; OK a staging/prod amb `pg_cron`) |
| Enqueue email (vault) | ⚠️ warning local sense vault secrets (no bloqueja captura) |

**URL smoke:** `/beta-startup/ca/careers/smoke-chef-db13adfc?src=qr`

## Smoke checklist (REC-0…3 hotfix P0+P1)

1. Migració `20261124000001_recruitment_rec03_hotfix_p0_p1`.
2. Tests: `supabase/tests/recruitment_rec03_hotfix_p0_p1_tests.sql` → 7/7 PASS.
3. `submit_job_application`: **sense** `EXECUTE` per `anon`/`authenticated`; només `service_role` (+ postgres tests).
4. Apply route usa service role + `NEXT_PUBLIC_SITE_URL` / `PUBLIC_PORTAL_BASE_URL` (no `Origin`).
5. Emails verify/received: `template_variables` amb `verify_url`.
6. Duplicate / error apply → CV orphan esborrat; `DELETE applications` → trigger storage.
7. Site-scoped `recruitment.view` només veu apps/CV del seu `job_postings.site_id`.

## Smoke checklist (REC-0…3 P2)

1. Migració `20261125000001_recruitment_rec03_p2`.
2. Tests: `supabase/tests/recruitment_rec03_p2_tests.sql` → 6/6 PASS.
3. Flag off → PostgREST no llegeix `job_postings`/apps (RESTRICTIVE RLS).
4. `erasure_hmac_key` sense GRANT SELECT/UPDATE a `authenticated`.
5. Publicar oferta sense web públic → `public_site_required` (UI + trigger).
6. Mateixa `idempotency_key` → `duplicate: true` sense segona fila.
7. `purge_expired_applications` processa lots fins a 10k/invocació.

## Smoke checklist (REC-4 hotfix P0)

1. Migració `20261122000001_recruitment_export_rec4_hotfix_p0`.
2. Edge Function `export-recruitment-applications` desplegada.
3. Tests: `supabase/tests/recruitment_export_rec4_hotfix_p0_tests.sql` → 5/5 PASS.
4. Export UI → invoke Edge → **signed URL** (cap `csv_text` al navegador).
5. Applicants amb Art. 18/21 **exclosos** del CSV (`excluded_count`).
6. Audit `recruitment.export_applications` només després d'upload (finalize).
7. Cron / `purge_expired_recruitment_exports` esborra packages + objectes caducats (1 h).

## Smoke checklist (REC-4 tall 1)

1. Migració `20261112000001_recruitment_pipeline_rec4` aplicada.
2. Tests: `supabase/tests/recruitment_pipeline_rec4_tests.sql` → 5/5 PASS.
3. Tenant → oferta amb candidatures → Kanban: arrossegar card canvia `stage_id`.
4. Moure a Descart/Contractat: `candidate_visible_status` segueix `open`.
5. Fitxa: Obrir CV (signed URL 15 min).
6. Export CSV: sense checkbox → bloquejat; amb ack → download + fila `audit_logs` `recruitment.export_applications`.

## Smoke checklist (REC-4b)

1. Migració `20261113000001_recruitment_interviews_rec4b`.
2. Tests: `supabase/tests/recruitment_interviews_rec4b_tests.sql` → 5/5 PASS.
3. Fitxa candidatura → Entrevistes: crear (phone/online/onsite), notes, cancel·lar estat.
4. Sense `recruitment.interview`/`manage`: secció d’entrevistes **no visible** (RLS tampoc retorna files amb només `view`) — vegeu P1–P2.

## Smoke checklist (REC-4 P1–P2)

1. Migració `20261123000001_recruitment_rec4_p1_p2`.
2. Tests: `supabase/tests/recruitment_rec4_p1_p2_tests.sql` → 6/6 PASS.
3. Notes d’entrevista: només `recruitment.interview` | `manage` (SELECT + UPDATE WITH CHECK).
4. Export/move: `view` → forbidden; manage de site A no mou oferta de site B.
5. CSV: cel·les que comencen per `= + - @` escapades amb `'` prefix.
6. Settings → etapes tenant; detall oferta → clonar override / reset.
7. `jwt_has_permission` sempre retorna boolean (`COALESCE`…`false`) — evita bypass `IF NOT NULL` amb `site_id`.

## Smoke checklist (REC-5 tall 2)

1. Migració `20261114000001_recruitment_outcome_rec5`.
2. Tests: `supabase/tests/recruitment_outcome_rec5_tests.sql` → 6/6 PASS.
3. Fitxa candidatura → **Comunicar resultat** (`recruitment.manage`): `outcome_communicated_at` + portal `closed`; etapa no canvia.
4. Moure a Descart **sense** communicate → `candidate_visible_status` segueix `open`.
5. Email `recruitment.application_rejected` amb `/recruitment/preferences?token=…` (cal `VITE_PUBLIC_PORTAL_BASE_URL`).
6. Preferències públiques: talent pool / erase / keep; exigeix email verificat; token un sol ús.
7. Settings `rejection_notify_policy = on_posting_close` + arxivar oferta → lot communicate pendents.
8. **Fora d’abast aquest tall:** safata Art. 15 / `applicant_data_requests` (= REC-5b).

## Smoke checklist (REC-5b)

1. Migracions `20261115000001_recruitment_rights_rec5b` + `20261116000001` (hmac search_path).
2. Tests: `supabase/tests/recruitment_rights_rec5b_tests.sql` → 6/6 PASS.
3. Public `/{slug}/{locale}/careers/rights`: petició access/erasure (email verificat).
4. Tenant → **Drets RGPD** (`recruitment.rights`): Aprovar access → correu amb `/api/recruitment/rights-export?token=` (un sol ús).
5. Aprovar erasure → apps/applicant purged + `applicant_erasure_log` `user_request`.
6. Sense `recruitment.rights`: safata inaccessible / RPC forbidden.
7. **Fora d’abast:** Art. 16–21 (rectificació, limitació, oposició, portabilitat).

## Smoke checklist (REC-5c)

1. Migració `20261117000001_recruitment_rights_rec5c`.
2. Tests: `supabase/tests/recruitment_rights_rec5c_tests.sql` → 5/5 PASS.
3. Formulari careers/rights: 6 tipus (15–18, 20–21).
4. Aprovar restriction → `processing_restricted_at`; objection → `objection_at` + talent pool null.
5. Portability → mateix export token que Art. 15.
6. Rectification / objection: notes obligatòries; rectification no muta PII via RPC.
7. **Fora d’abast:** Art. 19 (notificació a destinataris).

## Smoke checklist (REC-5 P1–P2)

1. Migració `20261120000001_recruitment_rec5_p1_p2`.
2. Tests: `supabase/tests/recruitment_rec5_p1_p2_tests.sql` → 7/7 PASS.
3. Settings UI: `rejection_notify_policy`, `rights_sla_days`, `candidate_portal_base_url`, `rights_sla_notify_emails`.
4. Safata: només email masked; botó revelar → audit `recruitment.reveal_rights_requester_email`.
5. Art. 18/21: hire / communicate / move stage → `processing_restricted` / `objection_recorded`.
6. Rectificació: camps nom/telèfon a l'approve + notes.
7. Export: fins a 5 descàrregues dins TTL; `HEAD` no consumeix token.

## Smoke checklist (REC-5 hotfix P0)

1. Migració `20261119000001_recruitment_rec5_hotfix_p0`.
2. Tests: `supabase/tests/recruitment_rec5_hotfix_p0_tests.sql` → 5/5 PASS.
3. `recruitment_settings.candidate_portal_base_url` (o `employee_portal.dev_base_url`) → arxiu `on_posting_close` envia prefs URL; sense base → communicate **sense** token mort.
4. Art.17 / `purge_expired_applications` esborra objectes a `recruitment-cvs`.
5. `remind_rights_sla` → owners/managers (o `rights_sla_notify_emails`), **no** al sol·licitant.

## Smoke checklist (REC-6)

1. Migració `20261118000001_recruitment_hire_rec6`.
2. Tests: `supabase/tests/recruitment_hire_rec6_tests.sql` → 5/5 PASS.
3. Fitxa candidatura → **Contractar**: cal `recruitment.manage` + `employees.manage`.
4. Crea `employees` + event `hire_from_ats` → `lifecycle_state=onboarding`.
5. `hired_employee_id` / portal `closed` / `outcome_kind=hired_next_steps` + email dedicat (no via communicate reject).
6. Bloquejat si ja s'havia comunicat rebuig; idempotent si ja hired.
7. **Fora d’abast:** CV→DMS, EC/Automation, dedupe email, rehire.

## Smoke checklist (REC-6 hotfix P1)

1. Migració `20261130000001_recruitment_hire_rec6_hotfix_p1`.
2. Tests: `supabase/tests/recruitment_hire_rec6_hotfix_p1_tests.sql` → 6/6 PASS.
3. `communicate_application_outcome(..., 'hired_next_steps')` → `use_hire_application` (sense empleat ni email).
4. Hire amb `starts_on` futur → `employees.starts_on` futur + `lifecycle_state=onboarding` (`effective_on=CURRENT_DATE`).
5. `purge_expired_applications` no esborra files amb `hired_employee_id IS NOT NULL`.
6. Hire amb perms només a un altre site → forbidden; amb perms al `posting.site_id` → OK.
7. `p_site_id` / dept / job_position d’un altre tenant → `invalid_*`.

## Smoke checklist (REC-6 P2)

1. Migració `20261131000001_recruitment_hire_rec6_p2`.
2. Tests: `supabase/tests/recruitment_hire_rec6_p2_tests.sql` → 4/4 PASS.
3. Apply amb locale `es`/`en` → `applicants.preferred_locale`; hire/communicate retornen `email_locale` i l’usen a `enqueue_email`.
4. `global_role=manager` **sense** `employees.manage` al JWT → hire forbidden (sense bypass de rol).
5. UI: botó Contractar usa `employees.manage` al `posting.site_id` (mateix criteri que la RPC).

## Smoke checklist (REC-12)

1. Migració `20261132000001_recruitment_csv_import_rec12`.
2. Tests: `supabase/tests/recruitment_csv_import_rec12_tests.sql` → 6/6 PASS.
3. Settings: base legal import (`legitimate_interest` \| `consent` \| `other`+nota).
4. Fitxa oferta → **Importar CSV** (plantilla `full_name;email;phone;locale;cover_message`) + etiqueta origen.
5. Crea apps `source=csv_import` + `import_source_label`; portal `open`; Art. 14 encuat (`art14_notice_sent_at`).
6. Reimport mateix CSV → skipped_duplicate; sense files duplicades.
7. `other` sense nota → import bloquejat (RPC + UI).

## Smoke checklist (REC-11)

1. Migracions `20261133000001_recruitment_analytics_rec11` + `20261134000001_recruitment_analytics_rec11_hotfix`.
2. Tests: `supabase/tests/recruitment_analytics_rec11_tests.sql` → 8/8 PASS.
3. Settings: `analytics_min_cohort` (3–20, defecte 5).
4. Nav → **Analytics reclutament** (`/recruitment/analytics`) amb `recruitment.view` + flag.
5. Amb &lt;5 candidatures al filtre → KPIs / funnel mostren "—"; sense PII a la resposta RPC.
6. Amb ≥5 → recomptes visibles; `by_source` omet cohorts &lt; k.
7. Filtres període / site / oferta.
8. Flag `recruitment_enabled` off → RPC `forbidden` (no bypass SECURITY DEFINER).

## Smoke checklist (REC-7 MVP)

1. Migracions `20261135000001_recruitment_inbound_rec7` + `20261136000001_recruitment_inbound_rec7_hotfix`.
2. Tests: `supabase/tests/recruitment_inbound_rec7_tests.sql` → 8/8 PASS.
3. Settings: `inbound_enabled` + `inbound_address_hint`.
4. Nav → **Correu rebut** (`/recruitment/inbox`).
5. Ingest stub (service_role) sense tag → `unassigned`; amb `[posting:uuid]` → `assigned` + `source=email`.
6. Assign manual → Art. 14; discard només `unassigned`; dedupe `resend_email_id`.
7. Edge: `verify_jwt = false` a config per `receive-recruitment-email`.
8. Go-live Resend: seguir [rec7-inbound-activation.md](./rec7-inbound-activation.md) (dependència Inbound segueix ⬜).

## Smoke checklist (REC-8 MVP)

1. Migracions `20261137000001_recruitment_ai_rec8` + `20261138000001_recruitment_ai_rec8_gate` + `20261139000001_recruitment_ai_rec8_hotfix`.
2. Tests: `supabase/tests/recruitment_ai_rec8_tests.sql` → 10/10 PASS.
3. Settings reclutament → checklist DPA + transfer → activar IA (requereix BYOK verificat a `/settings/ai`).
4. Fitxa candidatura amb CV PDF digital → **Estructurar CV** → proposta editable → confirmar → `cv_structured` desat.
5. PDF sense text / no-PDF → `needs_human_review` (sense crida LLM útil / missatge OCR futur).
6. Sense checklist o IA off → CTA oculta / Edge 403.
7. Art. 13 públic (`legal_notice_version` v2) menciona processament IA assistiu opcional.
8. Fora d’abast MVP: matching, esborranys correu, resum entrevistador, OCR (REC-F1).
