# Reclutament / ATS — pla de producte

> **Estat:** pla de producte / arquitectura — **sense implementació** (2026-07-21; **revisió 2026-07-21b** després de feedback de compliment).  
> **Objectiu:** mòdul ATS multi-tenant/site per captar candidatures (portal, QR, WhatsApp), gestionar selecció (Kanban, entrevistes), complir RGPD/LOPDGDD, i fer handoff a onboarding ELM — sense APIs de job boards (només CSV).

| Document | Contingut |
|----------|-----------|
| [01-domain-and-gdpr.md](./01-domain-and-gdpr.md) | Model, RLS, retenció/purge, REC-9/10, permisos |
| [02-flows-and-surfaces.md](./02-flows-and-surfaces.md) | Portal, tenant UI, pipeline, hire→ELM |
| [03-email-inbound-and-ai.md](./03-email-inbound-and-ai.md) | Email, inbound inbox, IA + DPA |
| [04-analytics-and-csv.md](./04-analytics-and-csv.md) | Analytics k-anonymity, CSV + Art. 14 |
| [rec7-inbound-activation.md](./rec7-inbound-activation.md) | Runbook activació Resend Inbound (REC-7) |
| [EXECUTION.md](./EXECUTION.md) | Fases (purge lligat a captura) |

---

## Posicionament

**Què resol PiMed**

- «Treballa amb nosaltres» al portal (tenant o site).
- Ofertes amb URL, QR, WhatsApp; formulari amb CV **per candidatura**.
- Pipeline (Kanban, entrevistes, plantilles).
- Post-rebuig amable; talent pool amb opt-in; drets RGPD per correu.
- Handoff a `employees` + `onboarding`.
- Analítiques agregades amb **k-anonymity**; CSV import/export (sense APIs boards).

**Fora d’abast**

- APIs InfoJobs / LinkedIn / Indeed.
- `lifecycle_state='candidate'` a l’ELM.

---

## Decisions tancades (REC-*)

| ID | Decisió |
|----|---------|
| **REC-1** | ATS separat d’`employees`; hire → `onboarding`. |
| **REC-2** | `site_id` nullable; M:N `job_posting_public_sites`; scope dept opcional. |
| **REC-3** | Carreres + `?src=` per QR/WhatsApp/web. |
| **REC-4** | Consentiment + Art. 13; bases legals **configurables** pel tenant/DPO. |
| **REC-5** | Inbound = inbox + assignació; tag opcional; BYO SMTP només outbound. |
| **REC-6** | Kanban etapes configurables. |
| **REC-7** | Hire → employee + onboarding. |
| **REC-9** | Sense PII al navegador; export Art. 15 per correu; SLA 30 dies; permís `recruitment.rights`. |
| **REC-10** | Portal open/closed **derivat** de `outcome_communicated_at` (trigger/generated); estat oferta `unlisted` (no `closed_unlisted`). |
| **REC-11** | Analytics agregats + **k-anonymity ≥5 al MVP**. |
| **REC-12** | Només CSV; Art. 14 post-import; advertència + TTL a export PII. |
| **REC-13** | CV a **`applications`**, no a `applicants`. |
| **REC-14** | `default_max_retention_months NOT NULL` (default 12); purge per **application** després **applicant**; `purge_at` sempre finit. |
| **REC-15** | `applicant_erasure_log` = **pseudonimització** (HMAC + secret tenant), no “sense PII”. |
| **REC-16** | CV: PDF digital amb capa de text = extracció local; PDF escanejat o imatge = OCR Tesseract en microservei futur, només amb add-on de plans alts. |

---

## Correccions 2026-07-21b (feedback revisió)

| # | Problema | Resolució al pla |
|---|----------|------------------|
| 1 | Purge podia ser infinit | Sostre obligatori + radio retenció obligatori + `purge_at` persistit |
| 1b | Granularitat applicant vs application | Purge per application; applicant només si no queden apps ni talent pool |
| 2 | CV ambigu | CV a `applications` |
| 3 | “Sense PII” al hash | Admetre pseudonimització + HMAC amb secret |
| 4 | Promesa retenció abans del cron | REC-3 inclou cron mínim; formulari no promet el que no s’executa |
| 5 | `closed_unlisted` | Renombrat `unlisted`; `archived`/`expired` tanquen procés |
| 6 | `candidate_visible_status` desync | Derivat / trigger BD |
| 7 | k-anonymity diferit | MVP ≥5 |
| 8 | Permisos / dept | `recruitment.rights` + scope dept opcional |
| 9 | Inbound ambigu | Inbox unassigned = cas majoritari |
| 10 | IA sense DPA | Checklist DPA/transfer/redacció |
| 11 | CSV Art. 14 / base legal | Art. 14 + base configurable |
| 12 | Export CSV fora de purge | Advertència + URL TTL + audit |

---

## Roadmap (resum)

| Fase | Entregable |
|------|------------|
| **REC-0** | CMP, clàusules leads/carreres, plantilles legals, settings retenció seed |
| **REC-1** | Schema + RLS + permisos (`rights`) + `purge_at` + cron skeleton |
| **REC-2** | Ofertes (`unlisted`), plantilles, QR, M:N public sites |
| **REC-3** | Captura pública + email verify + **cron purge operatiu** + preferències retenció |
| **REC-4** | Pipeline + export CSV (amb advertència TTL) |
| **REC-5** | Rebuig, safata drets, talent pool |
| **REC-12** | Import CSV + Art. 14 |
| **REC-6** | Hire → onboarding |
| **REC-11** | Analytics + k-anonymity |
| **REC-7** | Inbound email inbox |
| **REC-8** | IA + DPA checklist (MVP: estructurar CV) |
| **REC-F1** | OCR Tesseract per PDFs escanejats/imatges: microservei contenidoritzat i add-on de plans alts |

Detall: [EXECUTION.md](./EXECUTION.md).

---

## Relacionat

| Document | Relació |
|----------|---------|
| [../employees/plan-employees-hr-core-v2.md](../employees/plan-employees-hr-core-v2.md) | HR Core exclou ATS |
| [../employees/plan-elm-architecture.md](../employees/plan-elm-architecture.md) | `candidate` no seedat |
| [../employees/EXECUTION.md](../employees/EXECUTION.md) | Cua diferida enllaçada |
| [../employee-import/plan.md](../employee-import/plan.md) | Patró CSV |
| [../../email.md](../../email.md) | Resend |
| [../../product-design/02-domain-model.md](../../product-design/02-domain-model.md) | Tenant → Site |
