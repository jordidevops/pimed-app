# Projecció pública allowlist i política de retenció

> **Contracte CP-0.5** — acordat abans de crear schema (2026-08-04).  
> Pla: [`README.md`](./README.md) · Execució: [`EXECUTION.md`](./EXECUTION.md).  
> **Retenció / Legal Center plataforma:** [`../legal-compliance/README.md`](../legal-compliance/README.md) (jobs DSAR i purge a fase LC-2).  
> Versió del contracte: **1.2** *(CF-28 portal comercial lectura, 2026-10-07)*

Aquest document fixa què pot sortir al butlletí/reader **i** al catàleg comercial del portal nominatiu, i quant es conserva. No és l’entitlement comercial ([`entitlements-contract.md`](./entitlements-contract.md)).

---

## 1. Capes de dada (no confondre)

| Capa | Artefacte | Mutabilitat | Ús |
|---|---|---|---|
| Execució | `checklist_runs` + `public_report_payload` | Mutable fins a publicació formal | Close-out, procedència |
| Draft | `customer_intervention_report_drafts` | Mutable | Curation staff |
| Publicat | `customer_intervention_report_versions` | Append-only immutable | Shares, reader, evidència |
| Agregat | `customer_intervention_reports.current_published_version_id` | Punter mutable | «Versió corrent» |

El reader i les shares **només** resolen una versió publicada (o un draft en preview staff autenticat al tenant-portal). Mai serveixen el payload d’execució com a font pública.

---

## 2. Allowlist de projecció pública (v1)

Inclòs **només** si el draft/publicació el marca explícitament (o forma part del mínim identificatiu):

| Camp / bloc | Notes |
|---|---|
| Identificació tenant | Nom comercial / logo públic acordat; contacte de suport |
| Empresa o persona contractant | Snapshot de nom; no dades internes de facturació |
| Persona destinatària | Snapshot mínim (nom / canal usat al lliurament) |
| Local d’intervenció | Adreça / label de `contact_site` necessari per entendre el servei |
| Intervenció | Data, estat visible, referència d’ordre segura (no IDs interns crus si es pot evitar) |
| Resum de servei | Text redactat per al client; **sanititzat** allowlist HTML al servidor |
| Ítems de checklist | Només els seleccionats al draft (`content_selection.checklist_run_item_ids`); llavor inicial = `include_in_report`. Secció controlada per `show_checklists` (tenant default + override per butlletí). Label + estat snapshot segur |
| Tasques | Només les seleccionades (`content_selection.task_ids`); defecte totes. Camps: title, status, due_date, notes_html. Secció controlada per `show_tasks` |
| Materials | Només els seleccionats (`content_selection.material_ids`); defecte tots. Camps públics: name, quantity, unit (**mai** preus / `unit_price_cents` / `is_billable`). Secció controlada per `show_materials` |
| Media | Fitxers seleccionats (`selected_media`); còpia immutable al bucket del report. Evidence de checklist/tasca inclosos es poden autoafegir quan la secció es mostra |

### Exclòs sempre per defecte

- `work_notes_html`, notes de tècnic, descripcions internes
- Costos, marges, preus interns, imports de material, stock
- Valors / notes / resolucions / motius de bypass de checklist no marcats com a segurs
- Dades d’altres clients, URLs Storage operatives, metadades innecessàries
- Qualsevol adjunt «només perquè està a l’ordre» sense selecció explícita (l’auto-inclusió d’evidence de ítems/tasques marcats és selecció explícita de curació)

Canviar l’allowlist exigeix bump de `schema_version` / `template_version` a la versió publicada i revisió d’aquest contracte.

---

## 2bis. Allowlist comercial al portal nominatiu (CF-28 / CP-Da)

Exposició **opt-in** per toggle a `customer_portal_tenant_state` (`commercial_*_enabled`). Off per defecte. Només mode `portal` (no `share_only`). Kill-switch global del portal mana.

Accés només via BFF → edge `resolve-customer-portal-commercial` → RPCs `data.*` service-only amb `tenant_id` + `client_account_contact_id` ja resolts (grant o staff scoped a compte). Cap lectura PostgREST directa des del browser.

| Mòdul | Visible | Exclòs |
|---|---|---|
| Quotes / esmenes | Número, dates, validesa, status no-draft, totals/línies si `show_prices`, decisió resumida, PDF via signed URL curta | `created_by`, notes internes, templates, drafts, paths Storage |
| Acords | Kind, estat versió (`pending_signature`/`signed`/`declined`), vigència, PDF signed/rendered | Versions draft sense enviament, errors de signing |
| Albarans | Número, data, projecte públic, status (`rejected` → disputat), línies/imports si `show_prices`, factura vinculada, PDF | Costos, notes internes |
| Factures | Número, status, línies, totals, pagat/pendent agregat, pagaments amb referència emmascarada, albarans origen | `payments`/`payment_allocations` crus, metadades bancàries, exports gestoria, drafts |

Retenció comercial:

- El portal **no** crea còpies mutables; serveix versions/snapshots del domini comercial.
- Cache BFF `private, no-store`; signed URL PDF TTL curt (minuts).
- Revocar grant / staff session / kill-switch talla accés immediat; el document comercial persisteix segons retenció del domini CF.

Staff «veure com el client»: mateix allowlist; banner de suport; sessió scoped a un `client_account_contact_id`; audit amb `session_id` staff.

### 2ter. Retenció domini decisió comercial (CF-28 F9 §9.7)

| Artefacte | Retenció | Notes |
|-----------|----------|-------|
| `commercial_decision_requests` + snapshot/evidència | Mateixa que el document comercial / obligació legal del tenant | No escurçar per downgrade de pla |
| Token raw | **Mai** persistit (només hash; raw només `token_once` curt) | CS-D58 |
| Token hashes expirats/revocats | Purga operativa després del període acordat (`purge_expired_commercial_decision_token_once` + job) | No reutilitzar hash com a secret |
| Deliveries / email_log ids | Segons política email de plataforma + DSAR | Sense URL DocuSeal a logs tenant |
| IP / UA a evidence | Mínim necessari per traçabilitat; termini curt operatiu | No analytics de tercers |
| Signatures / justificants PDF | Política DMS / legal del document | Mateix document DMS V1/V2 |
| `commercial_ops_metric_events` | Operatiu 90 dies (orientatiu; purge LC-2) | Sense PII de signants |

---

## 3. Política de retenció (operativa v1)

Valors per defecte de plataforma; un tenant pot ser més estricte via DPA, no més lax si la llei ho impedeix. Un downgrade de pla **no** escurça ni destrueix evidència sota obligació de conservació.

| Artefacte | Retenció orientativa | Acció al venciment |
|---|---|---|
| Versions publicades + media immutable | ≥ 365 dies; més si obligació sectorial/contractual | Purga privilegiada per job; accés bloquejat abans si cal |
| Shares (metadades, hash) | Mentre hi hagi evidència d’accés o obligació; secret mai en clar | Revocar; no DELETE destructiu temprà |
| Sessions (share / staff / portal) | Curta (hores–dies); després purge | Invalidació per TTL / `security_version` |
| Access logs particionats | Particions mensuals; retenció típica 12–24 mesos | Drop de partició completa |
| Ledger d’abús (token desconegut) | Curta (dies–setmanes); IP minimitzada | Purge agresiva |
| Drafts no publicats | Política tenant (p. ex. 90 dies inactius) | Soft-delete / purge |

### RGPD operatiu

- Baixa / oposició / supressió de la persona: revocar shares, grants i sessions **immediatament**; registrar l’acció.
- No destruir versions sota obligació legal: bloquejar accés o pseudonimitzar segons política.
- La revocació no pot retirar còpies ja descarregades o impreses pel destinatari.

Detall de rols responsable/encarregat: [`legal-and-dpa.md`](./legal-and-dpa.md).
