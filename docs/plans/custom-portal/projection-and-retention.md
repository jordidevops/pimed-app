# Projecció pública allowlist i política de retenció

> **Contracte CP-0.5** — acordat abans de crear schema (2026-08-04).  
> Pla: [`README.md`](./README.md) · Execució: [`EXECUTION.md`](./EXECUTION.md).  
> **Retenció / Legal Center plataforma:** [`../legal-compliance/README.md`](../legal-compliance/README.md) (jobs DSAR i purge a fase LC-2).  
> Versió del contracte: **1.1**

Aquest document fixa què pot sortir al butlletí/reader i quant es conserva. No és l’entitlement comercial ([`entitlements-contract.md`](./entitlements-contract.md)).

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
