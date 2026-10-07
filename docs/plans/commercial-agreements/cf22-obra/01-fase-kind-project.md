# Fase 1 — Desbloquejar `kind=project`

> **Ordre:** 1 · **Depèn de:** nucli CT · **Bloqueja:** 2 (fites assumeixen acord project)  
> **Índex:** [`README.md`](./README.md) · decisions: [`00-decisions.md`](./00-decisions.md) O-D1, O-D14, O-D16, O-D17, O-D18

## Objectiu

Permetre crear i firmar un acord `kind='project'` pel mateix camí que `specific`. **Aquesta fase sola no entrega valor de producte** (sense fites). Existeix perquè el trigger i el prepare avui rebutgen `project`.

## Context

- CHECK ja admet `project` (`20261187000001`).
- Trigger `data.trg_commercial_agreements_v1_kind` només deixa passar `specific|recurring|framework` (`20261194000001`).
- `api.prepare_agreement_from_quote` valida `p_kind` (cal afegir `project` a la whitelist del cos RPC, no només al trigger).
- UI: `PrepareAgreementDialog` — opcions specific/recurring/framework; label specific = «Obra puntual» (**conflicte** O-D18).

## Checklist

### 1.1 SQL

- [ ] Actualitzar `trg_commercial_agreements_v1_kind` per acceptar `project` en camí normal (com `framework`).
- [ ] Actualitzar `prepare_agreement_from_quote`: `p_kind` ∈ `specific|recurring|framework|project`.
- [ ] `project` **exigeix** `source_quote_id` (com specific/recurring; no com framework).
- [ ] Sense billing_cadence forçat (default `none`). SLA fields opcionals/ignorats a UI per project (no mostrar bloc manteniment).
- [ ] Tests SQL: prepare `project` OK; `framework`/`recurring` intactes; kind reservat eliminat per `project`.

### 1.2 Plantilla (mínim)

- [ ] Seed HTML `category=commercial_agreement` «Acord d’obra» (ca; es opcional) **o** reutilitzar plantilla specific amb copy diferent.
- [ ] Respectar O-D16 (text no legal-reviewed).
- [ ] Tokens existents de context d’acord; **no** inventar tokens de fites encara (fites fase 2–3).

### 1.3 UI

- [ ] Opció `project` al selector de kind (O-D18 labels).
- [ ] Reetiquetar `specific` perquè deixi de dir només «Obra».
- [ ] Amagar camps SLA/billing de manteniment quan kind=`project` (com specific).
- [ ] Llista/filtres d’acords: badge `project`.
- [ ] `agreementIdentity` / context: text per kind project.

### 1.4 Docs runtime

- [ ] Comentari SQL HINT actualitzat (ja no «queda per CF-22»).

## DoD

- [ ] Es pot prepare + render + enviar a firma un acord `project` en local.
- [ ] Tests SQL del kind gate verds.
- [ ] Copy specific vs project no confon.
- [ ] **No** es marca CF-22 ✅ (falten fites).

## Fora d’aquesta fase

Fites, seguiment, canvis d’annex, plantilla advocat.
